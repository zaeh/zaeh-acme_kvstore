# frozen_string_literal: true

require 'puppet_x'
require 'openssl'
require 'puppet_x/acme_kvstore/crypto'
require 'puppet_x/acme_kvstore/kv_document'

module PuppetX::AcmeKvstore
  # Read-only certificate lookup for acme_kvstore_cert_data and
  # acme_kvstore::lookup_cert. Certificate, key and chain are only read
  # (and returned) while the status is "active". Chain certificates are
  # entries of their own (see docs/cci-ui.md).
  class CertLookup
    # Like CCI-UI's reader: bounds signature checks on odd inventories.
    MAX_CHAIN_ISSUERS = 12

    # @param kv_client [#read_multi, #read_prefix] a ConsulClient or RedisClient
    # @param area_secret [String, nil] needed with decrypt_key
    # @return [Hash{Symbol=>Object}] :status, :active_version, :latest_version,
    #   :updated_at, :pem (certificate only), :has_key, :private_key, and with
    #   include_chain :chain (issuers without self-signed roots), :fullchain
    #   (pem + chain), :chain_missing (true if not even the certificate's
    #   issuer was found), :chain_error (why the search failed, if it did),
    #   :root (the self-signed root of the chain, if stored) - all from :pem
    #   on nil unless active
    # @param include_chain [Boolean] build the chain at all (it can cost a read
    #   of all certificates of the area)
    # @param include_root [Boolean] also search the area for the root when the
    #   recorded chain does not end in one (CAs rarely deliver it)
    def self.lookup(kv_client:, prefix:, area:, certid:, decrypt_key: false, area_secret: nil, include_chain: false,
                    include_root: false)
      new(kv_client, prefix, area).lookup(certid, decrypt_key, area_secret, include_chain:, include_root:)
    end

    def initialize(kv_client, prefix, area)
      @kv_client = kv_client
      @prefix = prefix
      @area = area
    end

    def lookup(certid, decrypt_key, area_secret, include_chain: false, include_root: false)
      result = {
        status: nil, active_version: nil, latest_version: nil, updated_at: nil,
        pem: nil, chain: nil, fullchain: nil, chain_missing: nil, chain_error: nil, root: nil, has_key: nil, private_key: nil,
      }

      meta = read([path(doc.meta_path(@area, certid))]).values.first
      return result if meta.nil?

      result.merge!(status: meta['status'], active_version: meta['active_version'],
                    latest_version: meta['latest_version'], updated_at: meta['updated_at'])
      return result unless meta['status'] == 'active'

      version = meta['active_version']
      cert_key = path(doc.cert_path(@area, certid, version))
      key_key = path(doc.key_path(@area, certid, version))
      issuers = include_chain ? known_issuers(meta, version) : nil
      issuer_keys = issuers.to_a.map { |issuer| path(doc.meta_path(@area, issuer)) }

      docs = read([cert_key] + (decrypt_key ? [key_key] : []) + issuer_keys)
      cert = docs[cert_key]
      return result if cert.nil?

      result.merge!(pem: cert['pem'], has_key: cert['has_key'])
      result.merge!(chain_fields(cert['pem'], issuers, issuer_keys, docs, include_root)) if include_chain

      if decrypt_key && cert['has_key'] && docs[key_key]
        secret = PuppetX::AcmeKvstore::Crypto.decode_area_secret(area_secret)
        result[:private_key] = PuppetX::AcmeKvstore::Crypto.decrypt(
          docs[key_key], secret, aad: PuppetX::AcmeKvstore::Crypto.aad(@area, certid, version)
        )
      end

      result
    end

    private

    def chain_fields(pem, issuers, issuer_keys, docs, include_root)
      leaf = OpenSSL::X509::Certificate.new(pem)
      chain = issuer_certs(issuers, issuer_keys, docs) || discover_chain(leaf)
      missing = chain.empty? && !self_signed?(leaf)
      chain += discover_chain(chain.last) if include_root && !chain.empty? && !self_signed?(chain.last)

      fields = { chain_missing: missing, chain_error: @chain_error, root: chain.find { |ca| self_signed?(ca) }&.to_pem }
      unless missing
        fields[:chain] = chain.reject { |ca| self_signed?(ca) }.map(&:to_pem).join
        fields[:fullchain] = pem + fields[:chain]
      end
      fields
    end

    # The chain this module recorded for the active version, if any.
    def known_issuers(meta, version)
      renewal = meta['acme_renewal']
      return nil unless renewal.is_a?(Hash) && renewal['version'] == version && renewal['issuers'].is_a?(Array)

      renewal['issuers']
    end

    # @return [Array<OpenSSL::X509::Certificate>, nil] nil if an entry is missing
    def issuer_certs(issuers, issuer_keys, docs)
      return nil if issuer_keys.empty?

      metas = issuer_keys.map { |key| docs[key] }
      return nil if metas.any?(&:nil?)

      cert_keys = issuers.zip(metas).map { |issuer, issuer_meta| path(doc.cert_path(@area, issuer, issuer_meta['active_version'])) }
      certs = read(cert_keys).values
      return nil if certs.any?(&:nil?)

      certs.map { |issuer| OpenSSL::X509::Certificate.new(issuer['pem']) }
    end

    # CCI-UI's chain building above start: all public certificates of the
    # area (read once), issuer by name, CA:TRUE and signature.
    def discover_chain(start)
      return [] if self_signed?(start)

      candidates = (@candidates ||= search_candidates)
      chain = []
      seen = { doc.fingerprint(start) => true }
      current = start
      MAX_CHAIN_ISSUERS.times do
        break if self_signed?(current)

        parent = candidates.find { |candidate| !seen[doc.fingerprint(candidate)] && issuer?(candidate, current) }
        break unless parent

        chain << parent
        seen[doc.fingerprint(parent)] = true
        current = parent
      end
      chain
    end

    # A failed search (e.g. Redis without +scan) only means "no chain".
    def search_candidates
      @kv_client.read_prefix(path("#{@area}/certs/")).values.filter_map do |value|
        OpenSSL::X509::Certificate.new(value['pem']) if value.is_a?(Hash) && value['pem']
      end
    rescue StandardError => e
      @chain_error = "#{e.class}: #{e.message}"
      []
    end

    def issuer?(candidate, cert)
      candidate.subject == cert.issuer &&
        candidate.extensions.any? { |ext| ext.oid == 'basicConstraints' && ext.value.include?('CA:TRUE') } &&
        cert.verify(candidate.public_key)
    end

    def self_signed?(cert)
      cert.subject == cert.issuer && cert.verify(cert.public_key)
    end

    def read(keys)
      @kv_client.read_multi(keys)
    end

    def path(suffix)
      "#{@prefix}/#{suffix}"
    end

    def doc
      PuppetX::AcmeKvstore::KvDocument
    end
  end
end
