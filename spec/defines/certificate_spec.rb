# frozen_string_literal: true

require 'spec_helper'

describe 'acme_kvstore::certificate' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:worker_facts) do
        # Merge into the existing networking fact rather than replacing it
        # wholesale, so facterdb's/add_custom_fact's other networking.*
        # values (notably networking.ip - see spec/spec_helper_local.rb)
        # survive alongside the fqdn override below. os_facts may key
        # 'networking' as a string or a symbol depending on rspec-puppet
        # version/config, so check both rather than assume one.
        existing_networking = os_facts['networking'] || os_facts[:networking] || {}
        os_facts.merge('fqdn' => 'worker1.example.com', 'networking' => existing_networking.merge('fqdn' => 'worker1.example.com'))
      end
      let(:facts) do
        existing_networking = os_facts['networking'] || os_facts[:networking] || {}
        os_facts.merge('fqdn' => 'agent.example.com', 'networking' => existing_networking.merge('fqdn' => 'agent.example.com'))
      end
      let(:title) { 'shop-example-com' }
      let(:params) do
        {
          'area' => 'web',
          'domain' => 'shop.example.com',
          'worker' => 'worker1.example.com',
        }
      end
      let(:pre_condition) do
        <<~PUPPET
          class { 'acme_kvstore':
            backend => 'consul',
            consul  => { 'url' => 'https://consul.example.com:8501' },
            areas   => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
            default_worker => 'worker1.example.com',
          }
        PUPPET
      end

      context 'on a host that is not the responsible worker' do
        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_acme_kvstore_certificate('shop-example-com') }
        it { is_expected.not_to contain_class('acme_kvstore::worker') }
      end

      context 'on the responsible worker host' do
        let(:facts) { worker_facts }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_class('acme_kvstore::worker') }

        it 'realises the acme_kvstore_certificate resource with the correct provider and resolved defaults' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'ensure'   => 'present',
            'provider' => 'consul',
            'area'     => 'web',
            'domains'  => ['shop.example.com'],
            'server'   => 'letsencrypt',
          )
        end

        it 'stores issuer entries by default' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with('store_issuers' => true)
        end

        context 'with store_issuers => false for this certificate' do
          let(:params) { super().merge('store_issuers' => false) }

          it { is_expected.to contain_acme_kvstore_certificate('shop-example-com').with('store_issuers' => false) }
        end

        it 'passes no renew_schedule by default and sets no schedule metaparameter' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with('renew_schedule' => nil, 'schedule' => nil)
        end

        context 'with renew_schedule' do
          let(:params) { super().merge('renew_schedule' => 'nightly') }

          it 'passes it as a parameter, not as the schedule metaparameter' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with('renew_schedule' => 'nightly', 'schedule' => nil)
          end
        end

        it "writes 'puppet' as client and the worker's FQDN as updated_by" do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'client_id' => 'puppet', 'updated_by' => 'worker1.example.com',
          )
        end
      end

      context 'with kv_client and kv_updated_by set globally' do
        let(:facts) { worker_facts }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend        => 'consul',
              consul         => { 'url' => 'https://consul.example.com:8501' },
              areas          => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              default_worker => 'worker1.example.com',
              kv_client      => 'puppet-prod',
              kv_updated_by  => 'acme-service',
              store_issuers  => false,
            }
          PUPPET
        end

        it 'uses the global store_issuers default' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with('store_issuers' => false)
        end

        it 'passes both values to the resource' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'client_id' => 'puppet-prod', 'updated_by' => 'acme-service',
          )
        end
      end

      context 'with subject_alt_names' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('subject_alt_names' => ['www.shop.example.com', 'shop.example.com', 'www.shop.example.com']) }

        it 'passes the primary domain first and every other name once' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'domains' => ['shop.example.com', 'www.shop.example.com'],
          )
        end
      end

      context 'with an invalid domain' do
        let(:params) { super().merge('domain' => 'not a domain') }

        it { is_expected.to compile.and_raise_error(%r{domain}) }
      end

      context 'with an unknown area' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('area' => 'does_not_exist') }

        it { is_expected.to compile.and_raise_error(%r{unknown area}) }
      end

      context 'without an area and without a default_area' do
        let(:facts) { worker_facts }
        let(:params) { super().except('area') }

        it { is_expected.to compile.and_raise_error(%r{no 'area' given and no \$default_area configured}) }
      end

      context 'without an area but with a default_area configured' do
        let(:facts) { worker_facts }
        let(:params) { super().except('area') }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend        => 'consul',
              consul         => { 'url' => 'https://consul.example.com:8501' },
              areas          => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              default_worker => 'worker1.example.com',
              default_area   => 'web',
            }
          PUPPET
        end

        it 'falls back to the default area' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with('area' => 'web')
        end
      end

      context 'without a worker and without a default_worker' do
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend => 'consul',
              consul  => { 'url' => 'https://consul.example.com:8501' },
              areas   => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
            }
          PUPPET
        end
        let(:params) { { 'area' => 'web', 'domain' => 'shop.example.com' } }

        it { is_expected.to compile.and_raise_error(%r{no 'worker' given}) }
      end

      context 'per-area Consul token' do
        let(:facts) { worker_facts }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend        => 'consul',
              consul         => { 'url' => 'https://consul.example.com:8501' },
              areas          => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'area-token' } },
              default_worker => 'worker1.example.com',
            }
          PUPPET
        end

        it "uses the area's own Consul token in backend_config" do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'backend_config' => { 'url' => 'https://consul.example.com:8501', 'token' => 'area-token', 'prefix' => 'acme' },
          )
        end
      end

      context 'per-area Redis password' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('backend' => 'redis') }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend        => 'redis',
              redis          => { 'host' => 'redis.example.com' },
              areas          => { 'web' => { 'secret' => '#{'S' * 32}', 'redis_username' => 'acme-web', 'redis_password' => 'area-password' } },
              default_worker => 'worker1.example.com',
            }
          PUPPET
        end

        it "uses the area's own Redis ACL user in backend_config" do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'backend_config' => { 'host' => 'redis.example.com', 'username' => 'acme-web', 'password' => 'area-password', 'prefix' => 'acme' },
          )
        end

        context 'when this certificate switches to Consul but its area has no consul_token' do
          let(:params) { super().merge('backend' => 'consul') }
          let(:pre_condition) { super().sub('redis          =>', "consul         => { 'url' => 'https://consul.example.com:8501' },\n              redis          =>") }

          it { is_expected.to compile.and_raise_error(%r{area 'web' has no 'consul_token' - with Consul, every area needs its own token}) }
        end
      end

      context 'with an explicit CA profile' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('use_ca_profile' => 'privateca') }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend        => 'consul',
              consul         => { 'url' => 'https://consul.example.com:8501' },
              areas          => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              default_worker => 'worker1.example.com',
              ca_profiles    => {
                'letsencrypt'      => {},
                'letsencrypt_test' => {},
                'privateca'        => {
                  'directory_url' => 'https://ca.example.com/acme/directory',
                  'account_email' => 'ssl@example.com',
                },
              },
              ca_whitelist   => ['letsencrypt', 'letsencrypt_test', 'privateca'],
            }
          PUPPET
        end

        it 'resolves server to the profile directory_url and forwards its account email' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'server'        => 'https://ca.example.com/acme/directory',
            'account_email' => 'ssl@example.com',
          )
        end

        it { is_expected.to contain_acme_kvstore_certificate('shop-example-com').with_ca_bundles([]) }
      end

      context 'with CA certificates from the CA and the DNS profile' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('use_ca_profile' => 'stepca', 'use_dns_profile' => 'infoblox') }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend                  => 'consul',
              consul                   => { 'url' => 'https://consul.example.com:8501' },
              areas                    => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              default_worker           => 'worker1.example.com',
              ca_profiles              => { 'stepca' => { 'directory_url' => 'https://ca.example.com/acme/acme/directory' } + #{ca_profile.inspect.gsub('=>', ' => ')} },
              ca_whitelist             => ['stepca'],
              default_ca_profile       => 'stepca',
              dns_profiles             => { 'infoblox' => { 'hook' => 'dns_infoblox' } + #{dns_profile.inspect.gsub('=>', ' => ')} },
              ca_bundle_include_system => #{include_system},
            }
          PUPPET
        end

        # Variants override these methods.
        def pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
        def include_system = false
        def ca_profile = { 'ca_certificates' => pem }
        def dns_profile = { 'ca_bundle' => '/etc/pki/infoblox-ca.pem' }

        def system_bundle
          family = facts.dig(:os, 'family') || facts.dig('os', 'family')
          (family == 'RedHat') ? '/etc/pki/tls/certs/ca-bundle.crt' : '/etc/ssl/certs/ca-certificates.crt'
        end

        it 'passes both, the CA profile first' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com')
            .with_ca_bundles(['/etc/acme_kvstore/ca/ca-stepca.pem', '/etc/pki/infoblox-ca.pem'])
        end

        context 'with only the DNS profile bringing them, as PEM' do
          def ca_profile = {}
          def dns_profile = { 'ca_certificates' => pem }

          it { is_expected.to contain_acme_kvstore_certificate('shop-example-com').with_ca_bundles(['/etc/acme_kvstore/ca/dns-infoblox.pem']) }
        end

        context 'with ca_bundle_include_system' do
          def include_system = true

          it 'adds the system trust store of the OS first' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com')
              .with_ca_bundles([system_bundle, '/etc/acme_kvstore/ca/ca-stepca.pem', '/etc/pki/infoblox-ca.pem'])
          end
        end

        context 'with ca_bundle_include_system but no profile CA certificates' do
          def include_system = true
          def ca_profile = {}
          def dns_profile = {}

          it 'keeps acme.sh on the system store as it is' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with_ca_bundles([])
          end
        end

        context 'with a manual dns_provider instead of the DNS profile' do
          let(:params) { super().merge('dns_provider' => 'dns_cf') }

          it { is_expected.to contain_acme_kvstore_certificate('shop-example-com').with_ca_bundles(['/etc/acme_kvstore/ca/ca-stepca.pem']) }
        end
      end

      context 'with a CA profile that is not in the whitelist' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('use_ca_profile' => 'zerossl') }

        it { is_expected.to compile.and_raise_error(%r{CA profile 'zerossl' is not in \$acme_kvstore::ca_whitelist}) }
      end

      context 'with a DNS profile' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('use_dns_profile' => 'route53') }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend        => 'consul',
              consul         => { 'url' => 'https://consul.example.com:8501' },
              areas          => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              default_worker => 'worker1.example.com',
              dns_profiles   => {
                'route53' => {
                  'hook'            => 'dns_aws',
                  'env'             => { 'AWS_ACCESS_KEY_ID' => 'x', 'AWS_SECRET_ACCESS_KEY' => 'y' },
                  'challenge_alias' => 'alias.example.com',
                },
              },
            }
          PUPPET
        end

        it 'resolves the hook, env and challenge_alias from the profile' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'dns_provider'    => 'dns_aws',
            'dns_env'         => { 'AWS_ACCESS_KEY_ID' => 'x', 'AWS_SECRET_ACCESS_KEY' => 'y' },
            'challenge_alias' => 'alias.example.com',
          )
        end
      end

      context 'with an unknown DNS profile' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('use_dns_profile' => 'route53') }

        it { is_expected.to compile.and_raise_error(%r{unknown DNS profile 'route53'}) }
      end

      context 'with a manual dns_provider overriding a configured default_dns_profile' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('dns_provider' => 'dns_cf', 'dns_env' => { 'CF_Key' => 'x' }) }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend              => 'consul',
              consul               => { 'url' => 'https://consul.example.com:8501' },
              areas                => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              default_worker       => 'worker1.example.com',
              dns_profiles         => { 'route53' => { 'hook' => 'dns_aws' } },
              default_dns_profile  => 'route53',
            }
          PUPPET
        end

        it 'uses the manual override instead of the default profile' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'dns_provider' => 'dns_cf',
            'dns_env'      => { 'CF_Key' => 'x' },
          )
        end
      end

      context "with challenge_type => 'http-01' while a DNS hook is also given" do
        let(:facts) { worker_facts }
        let(:params) { super().merge('challenge_type' => 'http-01', 'dns_provider' => 'dns_cf') }

        it { is_expected.to compile.and_raise_error(%r{challenge_type is 'http-01' but a DNS hook/profile was also given}) }
      end

      context "with challenge_type => 'dns-01' but no DNS hook or profile" do
        let(:facts) { worker_facts }
        let(:params) { super().merge('challenge_type' => 'dns-01') }

        it { is_expected.to compile.and_raise_error(%r{challenge_type is 'dns-01' but no DNS hook/profile is configured}) }
      end

      context 'posthook_cmd, proxy and exec_timeout' do
        let(:facts) { worker_facts }

        context 'defaulting from the acme_kvstore class' do
          let(:pre_condition) do
            <<~PUPPET
              class { 'acme_kvstore':
                backend         => 'consul',
                consul          => { 'url' => 'https://consul.example.com:8501' },
                areas           => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
                default_worker  => 'worker1.example.com',
                posthook_cmd    => '/usr/bin/notify-deploy',
                proxy           => 'proxy.example.com:3128',
                exec_timeout    => 120,
              }
            PUPPET
          end

          it 'passes the class-level defaults through' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'posthook_cmd' => '/usr/bin/notify-deploy',
              'proxy'        => 'proxy.example.com:3128',
              'exec_timeout' => 120,
            )
          end
        end

        context 'overridden per certificate' do
          let(:params) do
            super().merge(
              'posthook_cmd' => '/usr/bin/notify-other',
              'proxy'        => 'other-proxy.example.com:3128',
              'exec_timeout' => 90,
            )
          end

          it 'uses the per-certificate overrides' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'posthook_cmd' => '/usr/bin/notify-other',
              'proxy'        => 'other-proxy.example.com:3128',
              'exec_timeout' => 90,
            )
          end
        end
      end

      context 'renew_before_days and purge_key_on_mismatch defaults' do
        let(:facts) { worker_facts }

        it 'uses the class-wide defaults' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'renew_before_days'     => 30,
            'purge_key_on_mismatch' => true,
          )
        end

        context 'overridden in the acme_kvstore class' do
          let(:pre_condition) do
            <<~PUPPET
              class { 'acme_kvstore':
                backend               => 'consul',
                consul                => { 'url' => 'https://consul.example.com:8501' },
                areas                 => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
                default_worker        => 'worker1.example.com',
                renew_before_days     => 21,
                purge_key_on_mismatch => false,
              }
            PUPPET
          end

          it 'passes them through' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'renew_before_days'     => 21,
              'purge_key_on_mismatch' => false,
            )
          end
        end

        context 'overridden per certificate' do
          let(:params) { super().merge('renew_before_days' => 14, 'purge_key_on_mismatch' => false) }

          it 'uses the per-certificate values' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'renew_before_days'     => 14,
              'purge_key_on_mismatch' => false,
            )
          end
        end
      end

      context 'DNS-01' do
        let(:facts) { worker_facts }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend             => 'consul',
              consul              => { 'url' => 'https://consul.example.com:8501' },
              areas               => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              default_worker      => 'worker1.example.com',
              dnssleep            => 45,
              dns_profiles        => {
                'cloudflare' => { 'hook' => 'dns_cf', 'env' => { 'CF_Token' => Sensitive('cf-secret') } },
                'slow'       => { 'hook' => 'dns_aws', 'options' => { 'dnssleep' => 120, 'aws_region' => Sensitive('eu-central-1') } },
                'bind'       => {
                  'hook'    => 'dns_nsupdate',
                  'env'     => { 'NSUPDATE_SERVER' => 'bind.example.com' },
                  'options' => { 'nsupdate_id' => 'acme-key', 'nsupdate_type' => 'hmac-sha256', 'nsupdate_key' => Sensitive('c2VjcmV0'), 'nsupdate_zone' => 'example.com' },
                },
              },
              default_dns_profile => 'cloudflare',
            }
          PUPPET
        end

        it 'uses the class-wide dnssleep and unwraps Sensitive env values' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'dns_provider' => 'dns_cf',
            'dns_env'      => { 'CF_Token' => 'cf-secret' },
            'dnssleep'     => 45,
            'dns_options'  => {},
          )
        end

        context "with a profile's own dnssleep" do
          let(:params) { super().merge('use_dns_profile' => 'slow') }

          it 'prefers it over the class default and does not pass it on as a DNS hook option' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'dnssleep'    => 120,
              'dns_options' => { 'aws_region' => 'eu-central-1' },
            )
          end
        end

        context 'with a per-certificate dnssleep' do
          let(:params) { super().merge('use_dns_profile' => 'slow', 'dnssleep' => 30) }

          it { is_expected.to contain_acme_kvstore_certificate('shop-example-com').with('dnssleep' => 30) }
        end

        context 'with a dnssleep not lower than exec_timeout' do
          let(:params) { super().merge('dnssleep' => 300) }

          it { is_expected.to compile.and_raise_error(%r{dnssleep \(300\) must be lower than exec_timeout \(300\)}) }
        end

        context 'with a dns_nsupdate profile (TSIG key handled like puppet-acme)' do
          let(:params) { super().merge('use_dns_profile' => 'bind') }

          it 'points NSUPDATE_KEY at the key file written by acme_kvstore::worker and keeps the key out of the environment' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'dns_provider' => 'dns_nsupdate',
              'dns_env'      => { 'NSUPDATE_KEY' => '/etc/acme_kvstore/nsupdate/bind.key', 'NSUPDATE_SERVER' => 'bind.example.com' },
              'dns_options'  => { 'nsupdate_zone' => 'example.com' },
            )
          end

          it { is_expected.to contain_file('/etc/acme_kvstore/nsupdate/bind.key') }
        end

        context 'with a wildcard certificate' do
          let(:params) { super().merge('domain' => '*.example.com', 'subject_alt_names' => ['example.com']) }

          it { is_expected.to compile.with_all_deps }

          it 'issues it via the DNS profile' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'domains'      => ['*.example.com', 'example.com'],
              'dns_provider' => 'dns_cf',
            )
          end
        end
      end

      context 'with a wildcard certificate but only HTTP-01 available' do
        let(:facts) { worker_facts }
        let(:params) { super().merge('domain' => '*.example.com') }

        it { is_expected.to compile.and_raise_error(%r{wildcard domains \(\*\.example\.com\) require DNS-01 validation}) }
      end

      context 'HTTP-01 webroot and acme.sh logging from acme_kvstore::worker' do
        let(:facts) { worker_facts }

        it 'uses the worker defaults' do
          is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
            'webroot'   => '/var/www/acme-challenge',
            'log_file'  => '/var/log/acme.sh/acme.log',
            'log_level' => 1,
          )
        end

        context 'with a customised worker' do
          let(:pre_condition) do
            "#{super()}\nclass { 'acme_kvstore::worker': webroot => '/srv/acme-challenge', acme_log_file => false, acme_log_level => 2 }\n"
          end

          it 'passes the configured webroot and no log file' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'webroot'  => '/srv/acme-challenge',
              'log_file' => nil,
            )
          end
        end
      end

      context 'run_as_user/run_as_group/run_as_home resolution from acme_kvstore::worker' do
        let(:facts) { worker_facts }

        context 'when the worker runs as root (the default)' do
          it 'passes no run_as_* overrides' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'run_as_user'  => nil,
              'run_as_group' => nil,
              'run_as_home'  => nil,
              'acmesh_path'  => '/root/.acme.sh/acme.sh',
            )
          end
        end

        context 'when acme_kvstore::worker is configured with a dedicated user' do
          let(:pre_condition) do
            "#{super()}\nclass { 'acme_kvstore::worker': user => 'acme', group => 'acme' }\n"
          end

          it 'resolves run_as_user/run_as_group/run_as_home and acmesh_path from the worker' do
            is_expected.to contain_acme_kvstore_certificate('shop-example-com').with(
              'run_as_user'  => 'acme',
              'run_as_group' => 'acme',
              'run_as_home'  => '/home/acme/.acme.sh',
              'acmesh_path'  => '/home/acme/.acme.sh/acme.sh',
            )
          end
        end
      end
    end
  end
end
