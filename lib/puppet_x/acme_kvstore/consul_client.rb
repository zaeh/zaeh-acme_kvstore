# frozen_string_literal: true

require 'puppet_x'
require 'net/http'
require 'uri'
require 'json'
require 'base64'
require 'openssl'

module PuppetX::AcmeKvstore
  # Consul KV client using only the transaction API (/v1/txn): any number
  # of keys (up to 64) per request, read or written atomically, with
  # compare-and-set on the ModifyIndex (see #transactional_update).
  class ConsulClient
    class Error < StandardError; end
    class CasConflictError < Error; end

    def initialize(config)
      config = stringify_keys(config || {})
      @uri = URI.parse(config['url'] || 'https://127.0.0.1:8501')
      @token = config['token']
      @datacenter = config['datacenter']
      @tls = config
    end

    # @param keys [Array<String>] full KV paths
    # @return [Hash{String=>Hash,nil}] key => parsed JSON value (nil if absent)
    def read_multi(keys)
      read_multi_with_index(keys).transform_values { |entry| entry[:value] }
    end

    def read_json(key)
      read_multi([key])[key]
    end

    # Also returns each key's ModifyIndex (0 if missing). Uses
    # "get-or-empty": "get" rolls back the whole transaction (HTTP 409) as
    # soon as one key is missing.
    #
    # @return [Hash{String=>{value: Hash|nil, index: Integer}}]
    def read_multi_with_index(keys)
      return {} if keys.empty?

      ops = keys.map { |k| { 'KV' => { 'Verb' => 'get-or-empty', 'Key' => k } } }
      response = txn(ops)

      result = {}
      keys.each { |k| result[k] = { value: nil, index: 0 } }
      Array(response['Results']).each do |entry|
        kv = entry['KV']
        next unless kv && kv['Key']

        result[kv['Key']] = { value: decode_value(kv['Value']), index: kv['ModifyIndex'].to_i }
      end
      result
    end

    # Writes all pairs in one atomic transaction.
    #
    # @param writes [Hash{String=>Hash}] suffix (relative to prefix) => value
    # @param cas [Hash{String=>Integer}] suffixes written with "cas" on this
    #   ModifyIndex instead of "set" (0: key must not exist yet)
    # @param checks [Hash{String=>Integer}] suffixes not written but required
    #   unchanged ("check-index", or "check-not-exists" for 0)
    # @raise [CasConflictError] if a cas/check fails (HTTP 409)
    def write_atomic(prefix, writes, cas: {}, checks: {})
      return true if writes.empty?

      ops = checks.map do |suffix, index|
        if index.to_i.zero?
          { 'KV' => { 'Verb' => 'check-not-exists', 'Key' => "#{prefix}/#{suffix}" } }
        else
          { 'KV' => { 'Verb' => 'check-index', 'Key' => "#{prefix}/#{suffix}", 'Index' => index.to_i } }
        end
      end

      ops += writes.map do |suffix, value|
        verb = cas.key?(suffix) ? 'cas' : 'set'
        op = {
          'Verb'  => verb,
          'Key'   => "#{prefix}/#{suffix}",
          'Value' => Base64.strict_encode64(value.to_json),
        }
        op['Index'] = cas[suffix] if verb == 'cas'
        { 'KV' => op }
      end

      txn(ops)
      true
    end

    # Compare-and-set read-modify-write on watch_suffix (the meta document):
    # yields its value, writes what the block returns (nothing for nil or
    # {}) only if the key still has the ModifyIndex it was read with. Every
    # other written key is an immutable version and only created ("cas"
    # with index 0), as CCI-UI does.
    #
    # @param expected [Hash, nil] { value:, index: } from an earlier read in
    #   this run; saves reading the key again
    # @yieldreturn [Hash, nil] suffix => value writes
    # @raise [CasConflictError] if the key changed concurrently
    def transactional_update(prefix, watch_suffix, expected: nil)
      watch_key = "#{prefix}/#{watch_suffix}"
      current = expected || read_multi_with_index([watch_key])[watch_key]

      writes = yield(current[:value])
      return true if writes.nil? || writes.empty?

      create_only = (writes.keys - [watch_suffix]).to_h { |suffix| [suffix, 0] }
      # The watched key is always the CAS condition, also when not written.
      if writes.key?(watch_suffix)
        write_atomic(prefix, writes, cas: create_only.merge(watch_suffix => current[:index]))
      else
        write_atomic(prefix, writes, cas: create_only, checks: { watch_suffix => current[:index] })
      end
    end

    # All keys below prefix (recursive GET on /v1/kv).
    #
    # @return [Hash{String=>Hash}] key => parsed JSON value
    def read_prefix(prefix)
      path = "/v1/kv/#{prefix}?recurse=true"
      path += "&dc=#{@datacenter}" if @datacenter
      Array(request(path, nil, method: :get)).to_h { |kv| [kv['Key'], decode_value(kv['Value'])] }
    end

    private

    def decode_value(base64_value)
      return nil if base64_value.nil?

      JSON.parse(Base64.decode64(base64_value))
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON in Consul KV value: #{e.message}"
    end

    def txn(ops)
      path = @datacenter ? "/v1/txn?dc=#{@datacenter}" : '/v1/txn'
      request(path, ops.to_json)
    end

    def request(path, body, method: :put)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = (@uri.scheme == 'https')
      configure_tls(http)
      http.read_timeout = (@tls['read_timeout'] || 10).to_i

      req = (method == :get) ? Net::HTTP::Get.new(path) : Net::HTTP::Put.new(path)
      req['Content-Type'] = 'application/json'
      req['X-Consul-Token'] = @token if @token
      req.body = body if body

      res = http.request(req)
      case res.code.to_i
      when 200..299
        (res.body.nil? || res.body.empty?) ? {} : JSON.parse(res.body)
      when 404
        raise Error, "Consul HTTP 404 at #{path}: #{res.body}" unless method == :get

        []
      when 409
        raise CasConflictError, "Consul CAS conflict at #{path}: #{res.body}"
      else
        raise Error, "Consul HTTP #{res.code} at #{path}: #{res.body}"
      end
    end

    def configure_tls(http)
      return unless http.use_ssl?

      http.ca_file = @tls['ca_file'] if @tls['ca_file']
      http.cert = OpenSSL::X509::Certificate.new(File.read(@tls['cert_file'])) if @tls['cert_file']
      http.key = OpenSSL::PKey.read(File.read(@tls['key_file'])) if @tls['key_file']
      http.verify_mode = @tls['insecure'] ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
    end

    def stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end
  end
end
