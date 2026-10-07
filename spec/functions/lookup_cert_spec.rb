# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/cert_lookup'
require 'puppet_x/acme_kvstore/consul_client'
require 'puppet_x/acme_kvstore/redis_client'

describe 'acme_kvstore::lookup_cert' do
  let(:backend_config) { { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' } }
  let(:lookup_result) do
    {
      status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
      pem: 'PEMDATA', has_key: false, private_key: nil,
    }
  end

  it 'queries via the Consul client and returns a string-keyed Hash' do
    consul_client = instance_double(PuppetX::AcmeKvstore::ConsulClient)
    allow(PuppetX::AcmeKvstore::ConsulClient).to receive(:new).with(backend_config).and_return(consul_client)
    allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(
      kv_client: consul_client, prefix: 'acme', area: 'web', certid: 'shop-example-com',
      decrypt_key: false, area_secret: nil, include_chain: false, include_root: false
    ).and_return(lookup_result)

    is_expected.to run.with_params('shop-example-com', 'web', 'consul', backend_config).and_return(
      'status' => 'active', 'active_version' => 1, 'latest_version' => 1, 'updated_at' => 'x',
      'pem' => 'PEMDATA', 'has_key' => false, 'private_key' => nil
    )
  end

  it 'queries via the Redis client when backend is redis' do
    redis_config = { 'host' => 'redis.example.com', 'prefix' => 'acme' }
    redis_client = instance_double(PuppetX::AcmeKvstore::RedisClient)
    allow(PuppetX::AcmeKvstore::RedisClient).to receive(:new).with(redis_config).and_return(redis_client)
    allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(
      hash_including(kv_client: redis_client),
    ).and_return(lookup_result)

    is_expected.to run.with_params('shop-example-com', 'web', 'redis', redis_config)
  end

  it 'passes decrypt_key and area_secret through to CertLookup' do
    consul_client = instance_double(PuppetX::AcmeKvstore::ConsulClient)
    allow(PuppetX::AcmeKvstore::ConsulClient).to receive(:new).and_return(consul_client)
    expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(
      kv_client: consul_client, prefix: 'acme', area: 'web', certid: 'shop-example-com',
      decrypt_key: true, area_secret: 'S' * 32, include_chain: false, include_root: false
    ).and_return(lookup_result)

    is_expected.to run.with_params('shop-example-com', 'web', 'consul', backend_config, 'S' * 32, true)
  end

  it 'passes include_chain and include_root through to CertLookup' do
    consul_client = instance_double(PuppetX::AcmeKvstore::ConsulClient)
    allow(PuppetX::AcmeKvstore::ConsulClient).to receive(:new).and_return(consul_client)
    expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(
      kv_client: consul_client, prefix: 'acme', area: 'web', certid: 'shop-example-com',
      decrypt_key: false, area_secret: nil, include_chain: true, include_root: true
    ).and_return(lookup_result)

    is_expected.to run.with_params('shop-example-com', 'web', 'consul', backend_config, nil, false, true, true)
  end

  it 'raises when backend_config has no prefix' do
    is_expected.to run.with_params('shop-example-com', 'web', 'consul', {}).and_raise_error(%r{must include a 'prefix'})
  end

  it 'raises when decrypt_key is true but no area_secret is given' do
    is_expected.to run.with_params('shop-example-com', 'web', 'consul', backend_config, nil, true)
                      .and_raise_error(%r{area_secret is required})
  end

  it 'returns no certificate data for a norollout/deleted certificate' do
    consul_client = instance_double(PuppetX::AcmeKvstore::ConsulClient)
    allow(PuppetX::AcmeKvstore::ConsulClient).to receive(:new).and_return(consul_client)
    allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
      status: 'norollout', active_version: 3, latest_version: 4, updated_at: 'x',
      pem: nil, has_key: nil, private_key: nil
    )

    is_expected.to run.with_params('shop-example-com', 'web', 'consul', backend_config).and_return(
      'status' => 'norollout', 'active_version' => 3, 'latest_version' => 4, 'updated_at' => 'x',
      'pem' => nil, 'has_key' => nil, 'private_key' => nil
    )
  end
end
