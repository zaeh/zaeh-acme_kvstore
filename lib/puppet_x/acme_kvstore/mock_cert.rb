# frozen_string_literal: true

require 'puppet_x'
require 'openssl'
require 'digest'

module PuppetX::AcmeKvstore
  # Fake certificates for acme_kvstore::deploy in mock mode: no KV store, a
  # leaf per certid, signed by the fixed, publicly known mock PKI in
  # files/mock. Deterministic (fixed dates and key, serial from the certid,
  # RSA PKCS#1 v1.5 signatures), so each call returns the same PEM; one
  # signature per certid, cached. Never for production.
  class MockCert
    MOCK_DIR = File.expand_path('../../../files/mock', __dir__)
    NOT_BEFORE = Time.utc(2026, 1, 1)
    NOT_AFTER = Time.utc(2099, 12, 29, 23, 59, 59)
    UPDATED_AT = '2026-01-01T00:00:00Z'

    @cache = {}
    @mutex = Mutex.new

    class << self
      # Same keys as CertLookup.lookup.
      # @return [Hash{Symbol=>Object}]
      def lookup(certid:, decrypt_key: false, include_chain: false, include_root: false)
        pem = leaf_pem(certid)
        pki = self.pki
        result = {
          status: 'active', active_version: 1, latest_version: 1, updated_at: UPDATED_AT,
          pem:, chain: nil, fullchain: nil, chain_missing: nil, chain_error: nil, root: nil, has_key: true, private_key: nil,
        }
        result.merge!(chain: pki[:intermediate_pem], fullchain: pem + pki[:intermediate_pem], chain_missing: false) if include_chain
        result[:root] = pki[:root_pem] if include_chain && include_root
        result[:private_key] = pki[:leaf_key_pem] if decrypt_key
        result
      end

      def leaf_pem(certid)
        @mutex.synchronize { @cache[certid] ||= build_leaf(certid).to_pem }
      end

      def pki
        @pki ||= begin
          read = ->(name) { File.read(File.join(MOCK_DIR, name)) }
          intermediate_pem = read.call('intermediate.pem')
          {
            root_pem: read.call('root.pem'),
            intermediate_pem:,
            intermediate: OpenSSL::X509::Certificate.new(intermediate_pem),
            intermediate_key: OpenSSL::PKey.read(read.call('intermediate.key')),
            leaf_key_pem: read.call('leaf.key'),
            leaf_key: OpenSSL::PKey.read(read.call('leaf.key')),
          }
        end
      end

      private

      def build_leaf(certid)
        issuer = pki[:intermediate]
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = OpenSSL::BN.new(Digest::SHA256.hexdigest(certid.to_s)[0, 30], 16)
        cert.subject = OpenSSL::X509::Name.new([['CN', certid.to_s[0, 64]], ['O', 'acme_kvstore MOCK - NOT FOR PRODUCTION']])
        cert.issuer = issuer.subject
        cert.public_key = pki[:leaf_key]
        cert.not_before = NOT_BEFORE
        cert.not_after = NOT_AFTER

        ef = OpenSSL::X509::ExtensionFactory.new(issuer, cert)
        # CA:FALSE is the default, so DER encodes an empty SEQUENCE; jruby-openssl's
        # ExtensionFactory would add an explicit FALSE (and another certificate).
        cert.add_extension(OpenSSL::X509::Extension.new('basicConstraints', OpenSSL::ASN1::Sequence.new([]).to_der, true))
        cert.add_extension(ef.create_extension('keyUsage', 'digitalSignature,keyEncipherment', true))
        cert.add_extension(ef.create_extension('extendedKeyUsage', 'serverAuth'))
        cert.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash'))
        cert.add_extension(ef.create_extension('authorityKeyIdentifier', 'keyid:always'))
        cert.add_extension(ef.create_extension('subjectAltName', "DNS:#{certid}")) if hostname?(certid)
        cert.sign(pki[:intermediate_key], OpenSSL::Digest.new('SHA256'))
        cert
      end

      def hostname?(name)
        name.to_s.match?(%r{\A(?=.{1,253}\z)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z})
      end
    end
  end
end
