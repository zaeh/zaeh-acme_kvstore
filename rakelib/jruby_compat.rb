# frozen_string_literal: true

# Checks the lookup-side code (CertLookup, Crypto, KvDocument) under the Ruby
# that runs it: MRI on agents/workers, JRuby on the Puppet/OpenVox server,
# where acme_kvstore::lookup_cert and acme_kvstore::deploy compile. Run via
# `bundle exec rake jruby:compat` (see jruby.rake next to this file):
#   jruby_compat.rb fixture DIR     (MRI)   test PKI and an AAD-bound key envelope
#   jruby_compat.rb check DIR       (JRuby) every check, and an envelope of its own
#   jruby_compat.rb check-back DIR  (MRI)   decrypt the JRuby envelope
require 'openssl'
require 'json'
require 'tmpdir'

mode, dir = ARGV
abort 'usage: jruby_compat.rb fixture|check|check-back DIR' unless %w[fixture check check-back].include?(mode) && dir

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
begin
  require 'puppet_x'
rescue LoadError
  # No Puppet here (plain JRuby): an empty PuppetX namespace is all lib/ needs.
  stub = Dir.mktmpdir('puppet_x_stub')
  File.write(File.join(stub, 'puppet_x.rb'), "module PuppetX; end\n")
  $LOAD_PATH.unshift(stub)
end
require 'puppet_x/acme_kvstore/crypto'
require 'puppet_x/acme_kvstore/kv_document'
require 'puppet_x/acme_kvstore/cert_lookup'

CRYPTO = PuppetX::AcmeKvstore::Crypto
DOC = PuppetX::AcmeKvstore::KvDocument
AAD = CRYPTO.aad('web', 'shop-example-com', 2)

def make_cert(subject, key, issuer = nil, issuer_key = nil, ca_flag: false, serial: 1)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = serial
  cert.subject = OpenSSL::X509::Name.parse(subject)
  cert.issuer = issuer ? issuer.subject : cert.subject
  cert.public_key = key.is_a?(OpenSSL::PKey::EC) ? key : key.public_key
  cert.not_before = Time.now - 3600
  cert.not_after = Time.now + (90 * 86_400)
  ef = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
  cert.add_extension(ef.create_extension('basicConstraints', ca_flag ? 'CA:TRUE' : 'CA:FALSE', true))
  cert.add_extension(ef.create_extension('subjectAltName', 'DNS:shop.example.com,DNS:www.shop.example.com')) unless ca_flag
  cert.sign(issuer_key || key, OpenSSL::Digest.new('SHA256'))
  cert
end

def write_fixture(dir)
  root_key = OpenSSL::PKey::RSA.new(2048)
  int_key = OpenSSL::PKey::RSA.new(2048)
  leaf_key = OpenSSL::PKey::RSA.new(2048)
  root = make_cert('/O=Test/CN=Test Root', root_key, ca_flag: true)
  int = make_cert('/O=Test/CN=Test R1', int_key, root, root_key, ca_flag: true, serial: 2)
  leaf = make_cert('/CN=shop.example.com', leaf_key, int, int_key, serial: 3)
  ec = make_cert('/CN=ec.example.com', OpenSSL::PKey::EC.generate('secp384r1'), int, int_key, serial: 4)
  bmp_name = OpenSSL::X509::Name.new
  bmp_name.add_entry('CN', 'Legacy Root CA'.encode('UTF-16BE').b, OpenSSL::ASN1::BMPSTRING)
  bmp = make_cert('/CN=placeholder', root_key, ca_flag: true, serial: 5)
  bmp.subject = bmp.issuer = bmp_name
  bmp.sign(root_key, OpenSSL::Digest.new('SHA256'))
  secret = OpenSSL::Random.random_bytes(32)
  File.write(File.join(dir, 'fixture.json'), JSON.generate(
                                               'root' => root.to_pem, 'int' => int.to_pem, 'leaf' => leaf.to_pem, 'ec' => ec.to_pem,
                                               'leaf_key' => leaf_key.private_to_pem, 'secret_hex' => secret.unpack1('H*'),
                                               'envelope' => CRYPTO.encrypt(leaf_key.private_to_pem, secret, aad: AAD),
                                               'fp' => [root, int, leaf].zip(%w[root int leaf]).to_h { |c, n| [n, OpenSSL::Digest::SHA256.hexdigest(c.to_der)] },
                                               'certid' => [root, int, bmp].zip(%w[root int bmp]).to_h { |c, n| [n, DOC.issuer_certid(c)] },
                                               'bmp' => bmp.to_pem
                                             ))
end

# An in-memory KV store holding what the worker would have written.
class FakeKv
  def initialize(data)
    @data = data
  end

  def read_multi(keys)
    keys.to_h { |key| [key, @data[key]] }
  end

  def read_prefix(prefix)
    @data.select { |key, _| key.start_with?(prefix) }
  end
end

def run_checks(dir)
  f = JSON.parse(File.read(File.join(dir, 'fixture.json')))
  secret = [f['secret_hex']].pack('H*')
  fp = f['fp']
  ids = f['certid']
  results = {}
  check = lambda do |name, &block|
    results[name] = begin
      block.call
    rescue StandardError => e
      "#{e.class}: #{e.message}"
    end
  end

  check.call('decrypt MRI envelope (AES-256-GCM + AAD)') { CRYPTO.decrypt(f['envelope'], secret, aad: AAD) == f['leaf_key'] }
  check.call('reject envelope under another version') do
    CRYPTO.decrypt(f['envelope'], secret, aad: CRYPTO.aad('web', 'shop-example-com', 3))
    false
  rescue OpenSSL::Cipher::CipherError
    true
  end
  own = CRYPTO.encrypt(f['leaf_key'], secret, aad: AAD)
  File.write(File.join(dir, 'envelope.json'), JSON.generate(own))
  check.call('own round trip') { CRYPTO.decrypt(own, secret, aad: AAD) == f['leaf_key'] }
  check.call('SHA-256 fingerprints') { %w[root int leaf].all? { |n| DOC.fingerprint(OpenSSL::X509::Certificate.new(f[n])) == fp[n] } }
  check.call('issuer certids (<cn>_<expiry date>)') { %w[root int].all? { |n| DOC.issuer_certid(OpenSSL::X509::Certificate.new(f[n])) == ids[n] } }
  check.call('issuer certid of a BMPString CN') do
    ids['bmp'].start_with?('legacy-root-ca_') && DOC.issuer_certid(OpenSSL::X509::Certificate.new(f['bmp'])) == ids['bmp']
  end
  check.call('split_pem') { DOC.split_pem(f['int'] + f['root']).map(&:to_pem) == [f['int'], f['root']] }
  check.call('summary_of RSA') do
    s = DOC.summary_of(OpenSSL::X509::Certificate.new(f['leaf']), version: 2)
    s['domains'] == ['shop.example.com', 'www.shop.example.com'] && s.values_at('key_type', 'key_size') == ['rsa', 2048]
  end
  check.call('summary_of EC') { DOC.summary_of(OpenSSL::X509::Certificate.new(f['ec']), version: 1).values_at('key_type', 'key_size') == ['ec', 384] }

  doc = ->(pem, has_key = false) { { 'pem' => pem, 'tags' => [], 'has_key' => has_key, 'created_at' => 'x', 'client' => 'puppet' } }
  meta = ->(extra = {}) { { 'status' => 'active', 'active_version' => 2, 'latest_version' => 2, 'updated_at' => 'x' }.merge(extra) }
  base = {
    'acme/web/certs/shop-example-com/2' => doc.call(f['leaf'], true),
    'acme/web/keys/shop-example-com/2' => f['envelope'],
    "acme/web/certids/#{ids['int']}" => { 'active_version' => 1 },
    "acme/web/certs/#{ids['int']}/1" => doc.call(f['int']),
  }
  root_doc = { "acme/web/certs/#{ids['root']}/1" => doc.call(f['root']) }
  lookup = lambda do |store, **opts|
    PuppetX::AcmeKvstore::CertLookup.lookup(kv_client: FakeKv.new(store), prefix: 'acme', area: 'web', certid: 'shop-example-com',
                                            decrypt_key: true, area_secret: secret, include_chain: true, **opts)
  end
  recorded = base.merge('acme/web/certids/shop-example-com' => meta.call('acme_renewal' => { 'version' => 2, 'issuers' => [ids['int']] }))

  r = lookup.call(recorded)
  check.call('lookup: private key') { r[:private_key] == f['leaf_key'] }
  check.call('lookup: recorded chain') { r[:chain] == f['int'] && r[:fullchain] == f['leaf'] + f['int'] && r[:chain_missing] == false }
  r = lookup.call(base.merge(root_doc, 'acme/web/certids/shop-example-com' => meta.call))
  check.call('lookup: chain by search') { r[:chain] == f['int'] && r[:root] == f['root'] }
  r = lookup.call(recorded.merge(root_doc), include_root: true)
  check.call('lookup: include_root') { r[:chain] == f['int'] && r[:root] == f['root'] }
  r = lookup.call(base.merge('acme/web/certids/shop-example-com' => meta.call).reject { |key, _| key.include?(ids['int']) })
  check.call('lookup: missing issuer') { r[:chain].nil? && r[:chain_missing] == true }
  failing = FakeKv.new(base.merge('acme/web/certids/shop-example-com' => meta.call))
  def failing.read_prefix(_prefix) = raise('NOPERM no scan')
  r = PuppetX::AcmeKvstore::CertLookup.lookup(kv_client: failing, prefix: 'acme', area: 'web', certid: 'shop-example-com',
                                              include_chain: true)
  check.call('lookup: failed search degrades to chain_missing') { r[:chain_missing] == true && r[:chain_error].to_s.include?('NOPERM') }
  results
end

case mode
when 'fixture'
  write_fixture(dir)
when 'check'
  engine = defined?(JRUBY_VERSION) ? "JRuby #{JRUBY_VERSION}, jruby-openssl #{JOpenSSL::VERSION}" : "MRI #{RUBY_VERSION}"
  puts "#{engine}, Java #{ENV_JAVA['java.version'] if defined?(ENV_JAVA)}".delete_suffix(', Java ')
  results = run_checks(dir)
  results.each do |name, outcome|
    detail = [true, false].include?(outcome) ? '' : ": #{outcome}"
    puts "#{(outcome == true) ? 'ok  ' : 'FAIL'} #{name}#{detail}"
  end
  exit(results.values.all?(true) ? 0 : 1)
when 'check-back'
  f = JSON.parse(File.read(File.join(dir, 'fixture.json')))
  ok = CRYPTO.decrypt(JSON.parse(File.read(File.join(dir, 'envelope.json'))), [f['secret_hex']].pack('H*'), aad: AAD) == f['leaf_key']
  puts "#{ok ? 'ok  ' : 'FAIL'} MRI decrypts the JRuby envelope"
  exit(ok ? 0 : 1)
end
