# frozen_string_literal: true

require 'puppet_x'
require 'openssl'

module PuppetX::AcmeKvstore
  # The KV key layout and the meta/certificate documents (the key document
  # comes from Crypto.encrypt). Every key lives below <prefix>/<area>/ so
  # area ACL tokens can be limited to their area; *_path returns keys
  # relative to <prefix>.
  class KvDocument
    PEM_CERT = %r{-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?}m
    def self.meta_path(area, certid)
      "#{area}/certids/#{certid}"
    end

    def self.cert_path(area, certid, version)
      "#{area}/certs/#{certid}/#{version}"
    end

    def self.key_path(area, certid, version)
      "#{area}/keys/#{certid}/#{version}"
    end

    def self.now_iso8601
      Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')
    end

    # acme_renewal (see #renewal_summary) marks a certificate this module
    # issued and renews, and lets the worker decide from this one document
    # whether anything is to be done.
    #
    # @return [Hash] meta document (<prefix>/<area>/certids/<certid>)
    def self.meta(active_version:, latest_version:, status:, updated_at:, client:, updated_by:, acme_renewal: nil)
      doc = {
        'active_version' => active_version,
        'latest_version' => latest_version,
        'status'         => status,
        'updated_at'     => updated_at,
        'client'         => client,
        'updated_by'     => updated_by,
      }
      doc['acme_renewal'] = acme_renewal if acme_renewal
      doc
    end

    # @param version [Integer] the version the summary describes
    # @param issuers [Array<String>] certids (fingerprints) of its chain, issuer first
    # @return [Hash] the 'acme_renewal' summary stored in the meta document
    def self.renewal_summary(not_after:, domains:, key_type:, key_size:, version: nil, issuers: nil)
      summary = {
        'not_after' => not_after.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'domains'   => domains,
        'key_type'  => key_type.to_s,
        'key_size'  => key_size.to_i,
      }
      summary['version'] = version if version
      summary['issuers'] = issuers if issuers
      summary
    end

    # The same summary, derived from a certificate itself (e.g. one activated
    # in CCI-UI): the CN first, then the other DNS names.
    def self.summary_of(cert, version:)
      cn = cert.subject.to_a.find { |entry| entry[0] == 'CN' }&.at(1)
      san = cert.extensions.find { |ext| ext.oid == 'subjectAltName' }
      names = san ? san.value.split(%r{,\s*}).filter_map { |entry| entry.delete_prefix('DNS:') if entry.start_with?('DNS:') } : []
      key = cert.public_key
      key_type, key_size = if key.is_a?(OpenSSL::PKey::EC)
                             ['ec', key.group.degree]
                           else
                             ['rsa', key.n.num_bits]
                           end
      renewal_summary(not_after: cert.not_after, domains: ([cn] + names).compact.uniq,
                      key_type:, key_size:, version:)
    end

    # @return [Array<OpenSSL::X509::Certificate>] every certificate in a PEM bundle
    def self.split_pem(pem)
      pem.to_s.scan(PEM_CERT).map { |block| OpenSSL::X509::Certificate.new(block) }
    end

    def self.fingerprint(cert)
      OpenSSL::Digest::SHA256.hexdigest(cert.to_der)
    end

    # The certid of a CA certificate: its CN (or O) and expiry date, e.g.
    # isrg-root-x1_2035-06-04 - readable (e.g. in Hiera trust store lists),
    # derived from the certificate alone and never changing.
    def self.issuer_certid(cert)
      fields = cert.subject.to_a.each_with_object({}) { |(key, value, type), acc| acc[key] ||= name_text(value, type) }
      label = (fields['CN'] || fields['O'] || '').downcase.gsub(%r{[^a-z0-9]+}, '-').gsub(%r{\A-+|-+\z}, '')[0, 100]
      label = 'ca' if label.empty?
      "#{label}_#{cert.not_after.utc.strftime('%Y-%m-%d')}"
    end

    # A name entry as text, decoded by its ASN.1 type exactly as CCI-UI's
    # Certificates::Codec.common_name does, so both derive the same certid.
    # MRI returns the raw bytes; JRuby (the Puppet server) already decoded text.
    def self.name_text(value, type)
      return value.scrub if value.encoding == Encoding::UTF_8

      encoding = case type
                 when OpenSSL::ASN1::BMPSTRING then Encoding::UTF_16BE
                 when OpenSSL::ASN1::UNIVERSALSTRING then Encoding::UTF_32BE
                 when OpenSSL::ASN1::T61STRING then Encoding::ISO_8859_1
                 else Encoding::UTF_8
                 end
      value.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
    private_class_method :name_text

    # For the rare other certificate with the same name: plus 8 fingerprint characters.
    def self.issuer_certid_alternative(cert)
      "#{issuer_certid(cert)}_#{fingerprint(cert)[0, 8]}"
    end

    # @return [Hash] certificate document (<prefix>/<area>/certs/<certid>/<version>):
    #   exactly one certificate; tags is always present (CCI-UI requires it).
    def self.certificate(pem:, has_key:, created_at:, client:, tags: nil, created_by: nil)
      doc = {
        'pem'        => pem,
        'tags'       => Array(tags),
        'has_key'    => has_key,
        'created_at' => created_at,
        'client'     => client,
      }
      doc['created_by'] = created_by if created_by && !created_by.to_s.empty?
      doc
    end
  end
end
