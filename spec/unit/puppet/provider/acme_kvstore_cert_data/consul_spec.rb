# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/crypto'

describe Puppet::Type.type(:acme_kvstore_cert_data).provider(:consul) do
  let(:resource) do
    Puppet::Type.type(:acme_kvstore_cert_data).new(
      name:           'shop-example-com',
      area:           'web',
      backend_config: { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' },
      decrypt_key:    true,
      include_chain:  true,
      area_secret:    'S' * 32,
      provider:       :consul,
    )
  end
  let(:provider) { resource.provider }
  let(:kv_client) { instance_double(PuppetX::AcmeKvstore::ConsulClient) }

  before do
    allow(provider).to receive(:kv_client).and_return(kv_client)
  end

  it 'is the default provider, so Puppet picks it without a warning' do
    type = Puppet::Type.type(:acme_kvstore_cert_data)
    type.defaultprovider = nil
    expect(Puppet).not_to receive(:warning)
    expect(type.defaultprovider).to eq(described_class)
  end

  it 'reads meta and certificate data in one combined call and caches the result' do
    allow(kv_client).to receive(:read_multi).with(['acme/web/certids/shop-example-com']).and_return(
      'acme/web/certids/shop-example-com' => {
        'active_version' => 2, 'latest_version' => 2, 'status' => 'active', 'updated_at' => 'x',
      },
    )
    plaintext_key = "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n"
    enc = PuppetX::AcmeKvstore::Crypto.encrypt(plaintext_key, 'S' * 32, aad: 'cci:web:shop-example-com/2')
    pki = AcmeKvstoreSpecPki.chain
    allow(kv_client).to receive(:read_prefix).with('acme/web/certs/').and_return(
      'acme/web/certs/issuer/1' => { 'pem' => pki[:intermediate].to_pem },
    )

    expect(kv_client).to receive(:read_multi)
      .with(['acme/web/certs/shop-example-com/2', 'acme/web/keys/shop-example-com/2'])
      .once
      .and_return(
        'acme/web/certs/shop-example-com/2' => { 'pem' => pki[:leaf].to_pem, 'tags' => [], 'has_key' => true },
        'acme/web/keys/shop-example-com/2'  => enc,
      )

    expect(provider.pem).to eq(pki[:leaf].to_pem)
    expect(provider.chain).to eq(pki[:intermediate].to_pem)
    expect(provider.fullchain).to eq(pki[:leaf].to_pem + pki[:intermediate].to_pem)
    expect(provider.chain_missing).to be(false)
    expect(provider.has_key).to be(true)
    expect(provider.private_key).to eq(plaintext_key)
    expect(provider.status).to eq('active')
    expect(provider.active_version).to eq(2)
  end

  it 'builds no chain unless include_chain is set (no search)' do
    plain = Puppet::Type.type(:acme_kvstore_cert_data).new(
      name: 'shop-example-com', area: 'web', provider: :consul,
      backend_config: { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' }
    ).provider
    allow(plain).to receive(:kv_client).and_return(kv_client)
    allow(kv_client).to receive(:read_multi).with(['acme/web/certids/shop-example-com']).and_return(
      'acme/web/certids/shop-example-com' => { 'active_version' => 2, 'latest_version' => 2, 'status' => 'active' },
    )
    expect(kv_client).to receive(:read_multi).with(['acme/web/certs/shop-example-com/2']).and_return(
      'acme/web/certs/shop-example-com/2' => { 'pem' => AcmeKvstoreSpecPki.chain[:leaf].to_pem, 'has_key' => false },
    )
    expect(kv_client).not_to receive(:read_prefix)

    expect(plain.chain).to be_nil
    expect(plain.chain_missing).to be_nil
  end

  it 'returns exists? false when there is no meta entry' do
    allow(kv_client).to receive(:read_multi).with(['acme/web/certids/shop-example-com']).and_return(
      'acme/web/certids/shop-example-com' => nil,
    )
    expect(provider.exists?).to be(false)
  end
end
