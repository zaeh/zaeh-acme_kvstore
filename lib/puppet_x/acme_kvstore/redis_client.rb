# frozen_string_literal: true

require 'puppet_x'
begin
  require 'redis'
rescue LoadError
  # Only needed where Redis is actually used; see .load_gem.
end
require 'json'
require 'openssl'

module PuppetX::AcmeKvstore
  # Redis KV client: MGET for reads, MULTI/EXEC for atomic writes and
  # WATCH for compare-and-set (see #transactional_update).
  class RedisClient
    class Error < StandardError; end
    class CasConflictError < Error; end

    # acme_kvstore::worker may install the gem in the same Puppet run, after
    # this file was loaded; RubyGems only sees it after clearing its paths.
    def self.load_gem
      return if defined?(::Redis)

      Gem.clear_paths
      require 'redis'
    rescue LoadError
      raise Error, "the 'redis' gem is not installed on this host"
    end

    def initialize(config)
      self.class.load_gem

      config = stringify_keys(config || {})
      opts = {
        host: config['host'] || 'localhost',
        port: (config['port'] || 6379).to_i,
        username: config['username'],
        password: config['password'],
        db: (config['db'] || 0).to_i,
        ssl: config['tls'] ? true : false,
      }
      opts[:ssl_params] = build_ssl_params(config) if config['tls']

      # A plain Hash works with both styles of redis gem initializers.
      @redis = ::Redis.new(opts.compact)
    end

    # @param keys [Array<String>] full KV paths
    # @return [Hash{String=>Hash,nil}]
    def read_multi(keys)
      return {} if keys.empty?

      values = @redis.mget(*keys)
      keys.zip(values).each_with_object({}) do |(k, v), acc|
        acc[k] = v.nil? ? nil : JSON.parse(v)
      end
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON in Redis value: #{e.message}"
    end

    def read_json(key)
      read_multi([key])[key]
    end

    # Same interface as ConsulClient's; index is always nil (Redis uses WATCH).
    #
    # @return [Hash{String=>{value: Hash|nil, index: nil}}]
    def read_multi_with_index(keys)
      read_multi(keys).transform_values { |value| { value:, index: nil } }
    end

    # Writes all pairs atomically (MULTI/EXEC).
    #
    # @param writes [Hash{String=>Hash}] suffix (relative to prefix) => value
    def write_atomic(prefix, writes)
      return true if writes.empty?

      @redis.multi do |tx|
        writes.each { |suffix, value| tx.set("#{prefix}/#{suffix}", value.to_json) }
      end
      true
    end

    # Compare-and-set read-modify-write on watch_suffix (the meta document)
    # with WATCH/MULTI/EXEC: yields its value, writes what the block
    # returns (nothing for nil or {}); EXEC fails if the key changed. Every
    # other written key is an immutable version: watched too, and it must
    # not exist yet.
    #
    # @param expected [Hash, nil] { value: } from an earlier read in this
    #   run. WATCH only sees later changes, so the value is compared too.
    # @yieldreturn [Hash, nil] suffix => value writes
    # @raise [CasConflictError] if the key changed concurrently
    def transactional_update(prefix, watch_suffix, expected: nil)
      watch_key = "#{prefix}/#{watch_suffix}"
      writes = nil

      result = @redis.watch(watch_key) do
        raw = @redis.get(watch_key)
        current = raw.nil? ? nil : JSON.parse(raw)
        if expected && current != expected[:value]
          @redis.unwatch
          raise CasConflictError, "Redis CAS conflict at #{watch_key} (changed since it was read)"
        end
        writes = yield(current)

        if writes.nil? || writes.empty?
          @redis.unwatch
          :no_write_required
        else
          create_only = (writes.keys - [watch_suffix]).map { |suffix| "#{prefix}/#{suffix}" }
          unless create_only.empty?
            @redis.watch(*create_only)
            existing = create_only.select { |key| @redis.exists?(key) }
            unless existing.empty?
              @redis.unwatch
              raise CasConflictError, "Redis CAS conflict: #{existing.join(', ')} already exist(s)"
            end
          end
          @redis.multi do |tx|
            writes.each { |suffix, value| tx.set("#{prefix}/#{suffix}", value.to_json) }
          end
        end
      end

      return true if result == :no_write_required
      raise CasConflictError, "Redis CAS conflict at #{watch_key} (concurrent write detected)" if result.nil?

      true
    end

    # All keys below prefix (SCAN, then MGET in batches); the user needs
    # the +scan permission.
    #
    # @return [Hash{String=>Hash}] key => parsed JSON value
    def read_prefix(prefix)
      keys = @redis.scan_each(match: "#{prefix}*", count: 500).to_a.uniq
      keys.each_slice(500).with_object({}) { |slice, acc| acc.merge!(read_multi(slice)) }
    end

    private

    def build_ssl_params(config)
      params = {}
      params[:ca_file] = config['ca_file'] if config['ca_file']
      params[:cert] = OpenSSL::X509::Certificate.new(File.read(config['cert_file'])) if config['cert_file']
      params[:key] = OpenSSL::PKey.read(File.read(config['key_file'])) if config['key_file']
      params[:verify_mode] = config['insecure'] ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
      params
    end

    def stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end
  end
end
