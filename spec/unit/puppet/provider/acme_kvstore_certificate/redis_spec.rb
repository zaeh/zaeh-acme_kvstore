# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/acmesh'

describe Puppet::Type.type(:acme_kvstore_certificate).provider(:redis) do
  let(:resource) do
    Puppet::Type.type(:acme_kvstore_certificate).new(
      name:           'shop-example-com',
      area:           'web',
      domains:        ['shop.example.com'],
      backend_config: { 'host' => 'redis.example.com', 'tls' => true, 'prefix' => 'acme' },
      area_secret:    'S' * 32,
      provider:       :redis,
    )
  end
  let(:provider) { resource.provider }
  let(:kv_client) { instance_double(PuppetX::AcmeKvstore::RedisClient) }

  before do
    allow(provider).to receive(:kv_client).and_return(kv_client)
  end

  it 'uses the shared ProviderCommon logic (exists? returns false without a meta entry)' do
    allow(kv_client).to receive(:read_multi_with_index).with(['acme/web/certids/shop-example-com']).and_return(
      'acme/web/certids/shop-example-com' => { value: nil, index: nil },
    )
    expect(provider.exists?).to be(false)
  end

  it 'writes atomically via exactly one transactional_update call on create' do
    key = OpenSSL::PKey::RSA.new(1024)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=shop.example.com')
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + (90 * 86_400)
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(
      cert: cert.to_pem, chain: nil, fullchain: nil, key: nil,
    )
    expect(kv_client).to receive(:transactional_update).once do |_prefix, _watch_suffix, &block|
      block.call(nil)
      true
    end
    provider.create
  end
end
