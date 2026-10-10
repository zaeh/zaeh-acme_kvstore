# frozen_string_literal: true

# The fixed mock PKI acme_kvstore::deploy uses in mock mode (files/mock):
# a root and an intermediate valid until the end of 2099, the intermediate's
# key and one leaf key. The root key is not kept. Regenerating changes every
# mock certificate, so do it only on purpose. Test material only.
namespace :mock do
  desc 'Regenerate the mock PKI in files/mock (test material, never for production)'
  task :pki do
    require 'openssl'
    require 'fileutils'

    dir = File.expand_path('../files/mock', __dir__)
    FileUtils.mkdir_p(dir)
    name = ->(cn) { OpenSSL::X509::Name.new([['CN', cn], ['O', 'acme_kvstore MOCK - NOT FOR PRODUCTION']]) }

    make_ca = lambda do |subject, key, issuer, issuer_key, serial, not_after|
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = serial
      cert.subject = subject
      cert.issuer = issuer ? issuer.subject : subject
      cert.public_key = key
      cert.not_before = Time.utc(2026, 1, 1)
      cert.not_after = not_after
      ef = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
      cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
      cert.add_extension(ef.create_extension('keyUsage', 'keyCertSign,cRLSign', true))
      cert.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash'))
      cert.add_extension(ef.create_extension('authorityKeyIdentifier', 'keyid:always')) if issuer
      cert.sign(issuer_key || key, OpenSSL::Digest.new('SHA256'))
      cert
    end

    root_key = OpenSSL::PKey::RSA.new(2048)
    root = make_ca.call(name.call('acme_kvstore MOCK Root'), root_key, nil, nil, 1, Time.utc(2099, 12, 31, 23, 59, 59))
    intermediate_key = OpenSSL::PKey::RSA.new(2048)
    intermediate = make_ca.call(name.call('acme_kvstore MOCK Intermediate'), intermediate_key, root, root_key, 2,
                                Time.utc(2099, 12, 30, 23, 59, 59))

    File.write(File.join(dir, 'root.pem'), root.to_pem)
    File.write(File.join(dir, 'intermediate.pem'), intermediate.to_pem)
    File.write(File.join(dir, 'intermediate.key'), intermediate_key.to_pem)
    File.write(File.join(dir, 'leaf.key'), OpenSSL::PKey::RSA.new(2048).to_pem)
    puts "mock PKI written to #{dir}"
  end
end
