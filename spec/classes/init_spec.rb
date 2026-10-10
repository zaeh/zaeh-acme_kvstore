# frozen_string_literal: true

require 'spec_helper'

describe 'acme_kvstore' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with a complete Consul configuration' do
        let(:params) do
          {
            'backend' => 'consul',
            'consul'  => { 'url' => 'https://consul.example.com:8501' },
            'areas'   => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_schedule('daily') }
      end

      context 'with per-area consul_token and redis_password' do
        let(:params) do
          {
            'backend' => 'consul',
            'consul'  => { 'url' => 'https://consul.example.com:8501' },
            'areas'   => {
              'web'      => { 'secret' => 'S' * 32, 'consul_token' => 'T' * 10 },
              'internal' => { 'secret' => 'I' * 32, 'consul_token' => 'internal-token', 'redis_password' => 'P' * 10 },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
      end

      context 'without any areas configured' do
        let(:params) do
          { 'backend' => 'consul', 'consul' => { 'url' => 'https://consul.example.com:8501' } }
        end

        it { is_expected.to compile.and_raise_error(%r{at least one area}) }
      end

      context 'with backend consul but without $consul' do
        let(:params) { { 'backend' => 'consul', 'areas' => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } } } }

        it { is_expected.to compile.and_raise_error(%r{has not been configured}) }
      end

      context 'with a default_area that is not a key in areas' do
        let(:params) do
          {
            'consul' => { 'url' => 'https://consul.example.com:8501' },
            'areas' => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'default_area' => 'does_not_exist',
          }
        end

        it { is_expected.to compile.and_raise_error(%r{default_area 'does_not_exist' is not a key in \$areas}) }
      end

      context 'with default_ca_profile not in ca_whitelist' do
        let(:params) do
          {
            'consul'             => { 'url' => 'https://consul.example.com:8501' },
            'areas'              => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'default_ca_profile' => 'zerossl',
            'ca_whitelist'       => ['letsencrypt'],
          }
        end

        it { is_expected.to compile.and_raise_error(%r{not in \$ca_whitelist}) }
      end

      context 'with default_ca_profile not present in ca_profiles' do
        let(:params) do
          {
            'consul'             => { 'url' => 'https://consul.example.com:8501' },
            'areas'              => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'default_ca_profile' => 'zerossl',
            'ca_whitelist'       => %w[letsencrypt zerossl],
          }
        end

        it { is_expected.to compile.and_raise_error(%r{not a key in \$ca_profiles}) }
      end

      context 'with a CA profile that sets both ca_certificates and ca_bundle' do
        let(:params) do
          {
            'consul'      => { 'url' => 'https://consul.example.com:8501' },
            'areas'       => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'ca_profiles' => {
              'letsencrypt' => {},
              'letsencrypt_test' => {},
              'stepca' => { 'directory_url' => 'https://ca.example.com/acme/acme/directory',
                            'ca_certificates' => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
                            'ca_bundle' => '/etc/pki/internal-ca.pem', },
            },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{CA profile\(s\) stepca set both 'ca_certificates' and 'ca_bundle'}) }
      end

      context 'with a DNS profile that sets both ca_certificates and ca_bundle' do
        let(:params) do
          {
            'consul'       => { 'url' => 'https://consul.example.com:8501' },
            'areas'        => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'dns_profiles' => {
              'infoblox' => { 'hook' => 'dns_infoblox', 'ca_bundle' => '/etc/pki/infoblox-ca.pem',
                              'ca_certificates' => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", },
            },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{DNS profile\(s\) infoblox set both 'ca_certificates' and 'ca_bundle'}) }
      end

      context 'with a ca_whitelist entry that has no matching ca_profiles entry' do
        let(:params) do
          {
            'consul'       => { 'url' => 'https://consul.example.com:8501' },
            'areas'        => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'ca_whitelist' => %w[letsencrypt letsencrypt_test privateca],
          }
        end

        it { is_expected.to compile.and_raise_error(%r{no matching \$ca_profiles entry: privateca}) }
      end

      context 'with a custom CA profile added to both ca_profiles and ca_whitelist' do
        let(:params) do
          {
            'consul'       => { 'url' => 'https://consul.example.com:8501' },
            'areas'        => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'ca_profiles'  => {
              'letsencrypt'      => {},
              'letsencrypt_test' => {},
              'privateca'        => { 'directory_url' => 'https://ca.example.com/acme/directory' },
            },
            'ca_whitelist' => %w[letsencrypt letsencrypt_test privateca],
          }
        end

        it { is_expected.to compile.with_all_deps }
      end

      context 'with a default_dns_profile that is not a key in dns_profiles' do
        let(:params) do
          {
            'consul'              => { 'url' => 'https://consul.example.com:8501' },
            'areas'               => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'default_dns_profile' => 'route53',
          }
        end

        it { is_expected.to compile.and_raise_error(%r{default_dns_profile 'route53' is not a key in \$dns_profiles}) }
      end

      context 'with a valid dns_profiles entry set as default' do
        let(:params) do
          {
            'consul'              => { 'url' => 'https://consul.example.com:8501' },
            'areas'               => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'dns_profiles'        => {
              'route53' => { 'hook' => 'dns_aws', 'env' => { 'AWS_ACCESS_KEY_ID' => 'x' } },
            },
            'default_dns_profile' => 'route53',
          }
        end

        it { is_expected.to compile.with_all_deps }
      end

      context 'with an area name CCI-UI does not accept' do
        let(:params) do
          {
            'consul' => { 'url' => 'https://consul.example.com:8501' },
            'areas'  => { 'web-public' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{parameter 'areas'}) }
      end

      ['acme-kvstore', 'ACME', 'puppet.acme'].each do |client|
        context "with kv_client '#{client}' (rejected by CCI-UI)" do
          let(:params) do
            {
              'consul'    => { 'url' => 'https://consul.example.com:8501' },
              'areas'     => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
              'kv_client' => client,
            }
          end

          it { is_expected.to compile.and_raise_error(%r{is not accepted by CCI-UI}) }
        end
      end

      context "with kv_client 'puppet-prod'" do
        let(:params) do
          {
            'consul'    => { 'url' => 'https://consul.example.com:8501' },
            'areas'     => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'kv_client' => 'puppet-prod',
          }
        end

        it { is_expected.to compile.with_all_deps }
      end

      context 'with a dnsapi_scripts name that is not a full acme.sh hook name' do
        let(:params) do
          {
            'consul'         => { 'url' => 'https://consul.example.com:8501' },
            'areas'          => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'dnsapi_scripts' => { 'rockenstein' => { 'content' => 'x' } },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{parameter 'dnsapi_scripts'}) }
      end

      context 'with a dnssleep that is not lower than exec_timeout' do
        let(:params) do
          {
            'consul'       => { 'url' => 'https://consul.example.com:8501' },
            'areas'        => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'dnssleep'     => 300,
            'exec_timeout' => 300,
          }
        end

        it { is_expected.to compile.and_raise_error(%r{\$dnssleep \(300\) must be lower than \$exec_timeout \(300\)}) }
      end

      context 'with hash parameters spread across two Hiera levels' do
        let(:hiera_config) { File.expand_path('../fixtures/hiera/hiera.yaml', __dir__) }

        it { is_expected.to compile.with_all_deps }

        it 'deep-merges them (module lookup_options), keeping the module default CA profiles' do
          is_expected.to contain_class('acme_kvstore').with(
            'consul'       => { 'url' => 'https://consul.example.com:8501', 'datacenter' => 'dc2' },
            'areas'        => {
              'web'        => { 'secret' => 'S' * 32, 'consul_token' => 'web-area-token', 'consul_read_token' => 'web-read-token' },
              'internal'   => {
                'secret' => 'I' * 32, 'consul_token' => 'internal-area-token',
                'redis_username' => 'acme-internal', 'redis_password' => 'internal-password',
                'consul_read_token' => 'internal-read-token',
                'redis_read_username' => 'acme-internal-read', 'redis_read_password' => 'internal-read-password',
              },
              'workeronly' => {
                'secret' => 'W' * 32, 'consul_token' => 'workeronly-area-token',
                'redis_username' => 'acme-workeronly', 'redis_password' => 'workeronly-password',
              },
            },
            'dns_profiles' => { 'cloudflare' => { 'hook' => 'dns_cf' }, 'route53' => { 'hook' => 'dns_aws' } },
            'ca_profiles'  => {
              'letsencrypt'      => {},
              'letsencrypt_test' => {},
              'zerossl'          => { 'account_email' => 'ssl@example.com' },
            },
          )
        end

        it 'declares the certificates from both levels (not realised here, since this is not the worker)' do
          is_expected.to contain_acme_kvstore__certificate('shop-example-com').with_domain('shop.example.com')
          is_expected.to contain_acme_kvstore__certificate('wildcard-example-com').with(
            'domain' => '*.example.com', 'subject_alt_names' => ['example.com'], 'use_dns_profile' => 'route53',
          )
          is_expected.not_to contain_acme_kvstore_certificate('shop-example-com')
        end
      end

      context 'with certificates given as a hash, on the worker' do
        let(:facts) do
          networking = os_facts['networking'] || os_facts[:networking] || {}
          os_facts.merge('networking' => networking.merge('fqdn' => 'worker1.example.com'))
        end
        let(:params) do
          {
            'consul'         => { 'url' => 'https://consul.example.com:8501' },
            'areas'          => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'default_worker' => 'worker1.example.com',
            'default_area'   => 'web',
            'certificates'   => {
              'shop-example-com' => { 'domain' => 'shop.example.com', 'renew_before_days' => 20 },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'realises each certificate with its parameters' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'area'              => 'web',
            'domains'           => ['shop.example.com'],
            'renew_before_days' => 20,
          )
        end
      end

      context 'with an invalid certificate parameter in the hash' do
        let(:params) do
          {
            'consul'         => { 'url' => 'https://consul.example.com:8501' },
            'areas'          => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'default_worker' => 'worker1.example.com',
            'certificates'   => { 'shop-example-com' => { 'domain' => 'shop.example.com', 'no_such_param' => true } },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{no_such_param}) }
      end

      context 'with the Consul backend and an area without its own consul_token' do
        let(:params) do
          {
            'consul' => { 'url' => 'https://consul.example.com:8501' },
            'areas'  => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' }, 'internal' => { 'secret' => 'I' * 32 } },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{every area needs its own 'consul_token'; missing for: internal}) }
      end

      context 'with a global Consul token' do
        let(:params) do
          {
            'consul' => { 'url' => 'https://consul.example.com:8501', 'token' => 'all-areas-token' },
            'areas'  => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
          }
        end

        # Acme_kvstore::Consul_config has no 'token' key at all.
        it { is_expected.to compile.and_raise_error(%r{parameter 'consul' unrecognized key 'token'}) }
      end

      context 'with the Redis backend, areas need their own Redis ACL user but no consul_token' do
        let(:params) do
          {
            'backend' => 'redis',
            'redis'   => { 'host' => 'redis.example.com' },
            'areas'   => { 'web' => { 'secret' => 'S' * 32, 'redis_username' => 'acme-web', 'redis_password' => 'pw' } },
          }
        end

        it { is_expected.to compile.with_all_deps }
      end

      context 'with the Redis backend and an area without its own Redis ACL user' do
        let(:params) do
          {
            'backend' => 'redis',
            'redis'   => { 'host' => 'redis.example.com' },
            'areas'   => {
              'web'      => { 'secret' => 'S' * 32, 'redis_username' => 'acme-web', 'redis_password' => 'pw' },
              'internal' => { 'secret' => 'I' * 32, 'redis_password' => 'pw' },
            },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{every area needs its own 'redis_username' and 'redis_password'; missing for: internal}) }
      end

      context 'with a global Redis password' do
        let(:params) do
          {
            'backend' => 'redis',
            'redis'   => { 'host' => 'redis.example.com', 'password' => 'all-areas-password' },
            'areas'   => { 'web' => { 'secret' => 'S' * 32, 'redis_username' => 'acme-web', 'redis_password' => 'pw' } },
          }
        end

        # Acme_kvstore::Redis_config has no 'username'/'password' keys at all.
        it { is_expected.to compile.and_raise_error(%r{parameter 'redis' unrecognized key 'password'}) }
      end

      context 'with an unsupported dh_param_size' do
        let(:params) do
          {
            'consul'        => { 'url' => 'https://consul.example.com:8501' },
            'areas'         => { 'web' => { 'secret' => 'S' * 32, 'consul_token' => 'web-token' } },
            'dh_param_size' => 1024,
          }
        end

        it { is_expected.to compile.and_raise_error(%r{dh_param_size}) }
      end
    end
  end
end
