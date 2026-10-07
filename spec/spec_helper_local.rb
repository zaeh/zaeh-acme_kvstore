# frozen_string_literal: true

# Module-specific setup (spec_helper.rb is template-managed).
# lib/ on the load path, so specs can require puppet_x/acme_kvstore/*.
lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)

# Silences Puppet's "Could not retrieve fact networking.ip" warning; the
# dotted key keeps the rest of the networking fact (e.g. fqdn) intact.
RspecPuppetFacts.add_custom_fact('networking.ip', '192.0.2.1') if defined?(RspecPuppetFacts)

require 'openssl'

# A small X.509 hierarchy for chain specs: root -> intermediate -> leaf.
module AcmeKvstoreSpecPki
  # @return [OpenSSL::X509::Certificate]
  def self.cert(subject:, key:, issuer: nil, issuer_key: nil, ca_flag: false, not_after: Time.now + (90 * 86_400), serial: 1)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = not_after
    ef = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
    cert.add_extension(ef.create_extension('basicConstraints', ca_flag ? 'CA:TRUE' : 'CA:FALSE', true))
    cert.sign(issuer_key || key, OpenSSL::Digest.new('SHA256'))
    cert
  end

  # @return [Hash{Symbol=>OpenSSL::X509::Certificate}] :root, :intermediate, :leaf
  def self.chain(leaf_not_after: Time.now + (90 * 86_400))
    root_key = OpenSSL::PKey::RSA.new(1024)
    int_key = OpenSSL::PKey::RSA.new(1024)
    root = cert(subject: '/O=Test/CN=Test Root', key: root_key, ca_flag: true)
    intermediate = cert(subject: '/O=Test/CN=Test R1', key: int_key, issuer: root, issuer_key: root_key, ca_flag: true, serial: 2)
    leaf = cert(subject: '/CN=shop.example.com', key: OpenSSL::PKey::RSA.new(1024), issuer: intermediate, issuer_key: int_key,
                not_after: leaf_not_after, serial: 3)
    { root:, intermediate:, leaf: }
  end
end
