# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:acme_kvstore_certificate) do
  let(:base_params) do
    {
      name:           'shop-example-com',
      area:           'web',
      domains:        ['shop.example.com'],
      backend_config: { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' },
      area_secret:    'S' * 32,
    }
  end

  it 'is created successfully with the required parameters' do
    expect { described_class.new(base_params) }.not_to raise_error
  end

  it 'defaults to ensure => present' do
    resource = described_class.new(base_params)
    expect(resource[:ensure]).to eq(:present)
  end

  it 'uses certid as the namevar' do
    resource = described_class.new(base_params)
    expect(resource[:certid]).to eq('shop-example-com')
  end

  it 'rejects invalid characters in certid' do
    expect do
      described_class.new(base_params.merge(name: 'shop/example.com'))
    end.to raise_error(Puppet::Error, %r{certid})
  end

  it 'rejects an empty domains list' do
    expect do
      described_class.new(base_params.merge(domains: []))
    end.to raise_error(Puppet::Error, %r{domains})
  end

  it 'rejects invalid domain names' do
    expect do
      described_class.new(base_params.merge(domains: ['not a domain!']))
    end.to raise_error(Puppet::Error)
  end

  it 'accepts wildcard domains with DNS-01 validation' do
    resource = described_class.new(base_params.merge(domains: ['*.example.com', 'example.com'], dns_provider: 'dns_cf'))
    expect(resource[:domains]).to eq(['*.example.com', 'example.com'])
  end

  it 'rejects wildcard domains without a DNS hook (HTTP-01 cannot validate them)' do
    expect do
      described_class.new(base_params.merge(domains: ['*.example.com']))
    end.to raise_error(Puppet::Error, %r{wildcard domains require DNS-01})
  end

  it 'defaults dnssleep to 60, purge_key_on_mismatch to true and log_level to 1' do
    resource = described_class.new(base_params)
    expect(resource[:dnssleep]).to eq(60)
    expect(resource[:purge_key_on_mismatch]).to be(true)
    expect(resource[:log_level]).to eq(1)
  end

  it 'munges purge_key_on_mismatch to a real boolean' do
    expect(described_class.new(base_params.merge(purge_key_on_mismatch: false))[:purge_key_on_mismatch]).to be(false)
  end

  it 'rejects a non-positive dnssleep and an unsupported log_level' do
    expect { described_class.new(base_params.merge(dnssleep: 0)) }.to raise_error(Puppet::Error, %r{dnssleep})
    expect { described_class.new(base_params.merge(log_level: 3)) }.to raise_error(Puppet::Error)
  end

  it 'defaults renew_before_days to 30' do
    resource = described_class.new(base_params)
    expect(resource[:renew_before_days]).to eq(30)
  end

  it 'accepts key_type rsa and ec' do
    expect(described_class.new(base_params.merge(key_type: 'rsa'))[:key_type]).to eq(:rsa)
    expect(described_class.new(base_params.merge(key_type: 'ec'))[:key_type]).to eq(:ec)
  end

  it 'rejects unknown key_type values' do
    expect do
      described_class.new(base_params.merge(key_type: 'dsa'))
    end.to raise_error(Puppet::Error)
  end

  it 'stores issuer entries by default' do
    expect(described_class.new(base_params)[:store_issuers]).to be(true)
    expect(described_class.new(base_params.merge(store_issuers: false))[:store_issuers]).to be(false)
  end

  it 'accepts renew_schedule and leaves it unset by default' do
    expect(described_class.new(base_params)[:renew_schedule]).to be_nil
    resource = described_class.new(base_params.merge(renew_schedule: 'nightly'))
    expect(resource[:renew_schedule]).to eq('nightly')
  end

  it 'defaults dns_env and dns_options to empty Hashes' do
    resource = described_class.new(base_params)
    expect(resource[:dns_env]).to eq({})
    expect(resource[:dns_options]).to eq({})
  end

  it 'rejects a non-Hash dns_env' do
    expect { described_class.new(base_params.merge(dns_env: ['FOO=bar'])) }.to raise_error(Puppet::Error)
  end

  it 'rejects a non-Hash dns_options' do
    expect { described_class.new(base_params.merge(dns_options: ['dnssleep=15'])) }.to raise_error(Puppet::Error)
  end

  it 'accepts challenge_alias, domain_alias, account_email, eab_kid and eab_hmac_key' do
    resource = described_class.new(base_params.merge(
                                     challenge_alias: 'alias.example.com',
                                     domain_alias: 'domain-alias.example.com',
                                     account_email: 'ssl@example.com',
                                     eab_kid: 'KID123',
                                     eab_hmac_key: 'HMAC456',
                                   ))
    expect(resource[:challenge_alias]).to eq('alias.example.com')
    expect(resource[:domain_alias]).to eq('domain-alias.example.com')
    expect(resource[:account_email]).to eq('ssl@example.com')
    expect(resource[:eab_kid]).to eq('KID123')
    expect(resource[:eab_hmac_key]).to eq('HMAC456')
  end

  it "defaults client_id to 'puppet' and updated_by to the node's certname" do
    resource = described_class.new(base_params)
    expect(resource[:client_id]).to eq('puppet')
    expect(resource[:updated_by]).to eq(Puppet[:certname])
  end

  it 'defaults exec_timeout to 300' do
    resource = described_class.new(base_params)
    expect(resource[:exec_timeout]).to eq(300)
  end

  it 'accepts posthook_cmd, proxy and exec_timeout' do
    resource = described_class.new(base_params.merge(
                                     posthook_cmd: '/usr/bin/notify-deploy',
                                     proxy: 'proxy.example.com:3128',
                                     exec_timeout: 120,
                                   ))
    expect(resource[:posthook_cmd]).to eq('/usr/bin/notify-deploy')
    expect(resource[:proxy]).to eq('proxy.example.com:3128')
    expect(resource[:exec_timeout]).to eq(120)
  end

  it 'rejects a non-numeric or non-positive exec_timeout' do
    expect { described_class.new(base_params.merge(exec_timeout: 0)) }.to raise_error(Puppet::Error)
    expect { described_class.new(base_params.merge(exec_timeout: 'soon')) }.to raise_error(Puppet::Error)
  end

  it 'accepts run_as_user, run_as_group and run_as_home' do
    resource = described_class.new(base_params.merge(
                                     run_as_user: 'acme',
                                     run_as_group: 'acme',
                                     run_as_home: '/home/acme/.acme.sh',
                                   ))
    expect(resource[:run_as_user]).to eq('acme')
    expect(resource[:run_as_group]).to eq('acme')
    expect(resource[:run_as_home]).to eq('/home/acme/.acme.sh')
  end
end
