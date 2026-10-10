# frozen_string_literal: true

require 'spec_helper'

describe 'acme_kvstore::worker' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }
      let(:pre_condition) do
        <<~PUPPET
          class { 'acme_kvstore':
            backend => 'consul',
            consul  => { 'url' => 'https://consul.example.com:8501' },
            areas   => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
          }
        PUPPET
      end

      context 'with default parameters (root)' do
        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_user('root') }
        it { is_expected.to contain_file('/root/.acme.sh').with_owner('root').with_group('root') }
        it { is_expected.to contain_file('/var/www/acme-challenge').with_owner('root').with_group('root') }

        it 'creates the webroot with missing parents, without managing them' do
          is_expected.to contain_exec('acme_kvstore-webroot').with(
            'command' => ['mkdir', '-p', '/var/www/acme-challenge'], 'creates' => '/var/www/acme-challenge',
          ).that_comes_before('File[/var/www/acme-challenge]')
        end

        it { is_expected.not_to contain_file('/var/www') }
        it { is_expected.to contain_exec('acme_kvstore-install-acmesh').with_cwd('/opt/acme.sh-src') }

        it 'reinstalls acme.sh only when the source has another VER (no creates)' do
          is_expected.to contain_exec('acme_kvstore-install-acmesh').with(
            'command'  => '/opt/acme.sh-src/acme.sh --install --home /root/.acme.sh --nocron',
            'provider' => 'shell',
            'unless'   => "test -x '/root/.acme.sh/acme.sh' && " \
                          "[ \"$(grep -m1 '^VER=' '/opt/acme.sh-src/acme.sh')\" = \"$(grep -m1 '^VER=' '/root/.acme.sh/acme.sh')\" ]",
            'creates'  => nil,
          ).that_requires('Vcsrepo[/opt/acme.sh-src]')
        end

        it { is_expected.not_to contain_package('acme_kvstore-redis-gem') }
        it { is_expected.not_to contain_package('acme.sh') }
        it { is_expected.to contain_package('acme_kvstore-git').with_name('git') }
        it { is_expected.to contain_vcsrepo('/opt/acme.sh-src').with_revision('3.0.9').with_force(false) }
        it { is_expected.to contain_file('/var/log/acme.sh').with_ensure('directory').with_owner('root').with_mode('0750') }
        it { is_expected.to contain_file('/var/log/acme.sh/acme.log').with_ensure('file').with_owner('root').with_mode('0640') }
        it { is_expected.to contain_file('/etc/acme_kvstore').with_ensure('directory').with_mode('0750') }
        it { is_expected.not_to contain_file('/etc/acme_kvstore/nsupdate') }
        it { is_expected.not_to contain_file('/root/.acme.sh/dnsapi') }
      end

      context 'with acme_log_file => false' do
        let(:params) { { 'acme_log_file' => false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_file('/var/log/acme.sh/acme.log') }
        it { is_expected.not_to contain_file('/var/log/acme.sh') }
      end

      context 'with a log file in a shared directory and manage_log_dir => false' do
        let(:params) { { 'acme_log_file' => '/var/log/acme.log', 'manage_log_dir' => false } }

        it { is_expected.to contain_file('/var/log/acme.log').with_ensure('file') }
        it { is_expected.not_to contain_file('/var/log') }
      end

      context 'with manage_packages => false' do
        let(:params) { { 'manage_packages' => false } }

        it { is_expected.not_to contain_package('acme_kvstore-git') }
      end

      context 'with a dedicated, self-managed user' do
        let(:params) { { 'user' => 'acme', 'group' => 'acme' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_user('acme') }
        it { is_expected.to contain_file('/home/acme/.acme.sh').with_owner('acme').with_group('acme') }
        it { is_expected.to contain_file('/var/www/acme-challenge').with_owner('acme').with_group('acme') }
      end

      context 'with manage_user => true' do
        let(:params) { { 'manage_user' => true, 'user' => 'acme', 'group' => 'acme' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_group('acme') }

        it do
          is_expected.to contain_user('acme').with(
            'gid' => 'acme',
            'home' => '/home/acme/.acme.sh',
            'system' => true,
            'shell' => '/usr/sbin/nologin',
            'managehome' => true,
          )
        end
      end

      context 'with CA and DNS profiles giving CA certificates as PEM or as a file' do
        let(:pem) { "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n" }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend     => 'consul',
              consul      => { 'url' => 'https://consul.example.com:8501' },
              areas       => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              ca_profiles => {
                'letsencrypt'      => {},
                'letsencrypt_test' => {},
                'step ca'          => { 'directory_url' => 'https://ca.example.com/acme/acme/directory', 'ca_certificates' => #{pem.inspect} },
                'corp'             => { 'directory_url' => 'https://acme.example.com/directory', 'ca_bundle' => '/etc/pki/corp.pem' },
              },
              dns_profiles => {
                'infoblox' => { 'hook' => 'dns_infoblox', 'ca_certificates' => #{pem.inspect} },
                'route53'  => { 'hook' => 'dns_aws' },
              },
            }
          PUPPET
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/etc/acme_kvstore/ca').with(ensure: 'directory', owner: 'root', mode: '0755') }

        it 'writes the PEM to a file-safe name, readable by the acme.sh user' do
          is_expected.to contain_file('/etc/acme_kvstore/ca/ca-step_ca.pem').with(owner: 'root', mode: '0644', content: pem)
        end

        it { is_expected.to contain_file('/etc/acme_kvstore/ca/dns-infoblox.pem').with(owner: 'root', mode: '0644', content: pem) }
        it { is_expected.not_to contain_file('/etc/acme_kvstore/ca/dns-route53.pem') }

        it { is_expected.not_to contain_file('/etc/pki/corp.pem') }
      end

      context 'with manage_gems => true' do
        let(:params) { { 'manage_gems' => true } }

        it { is_expected.to contain_package('acme_kvstore-redis-gem').with(name: 'redis', provider: 'puppet_gem') }
      end

      context "with install_method => 'archive'" do
        let(:params) { { 'install_method' => 'archive' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_vcsrepo('/opt/acme.sh-src') }
        it { is_expected.not_to contain_package('acme_kvstore-git') }

        it 'downloads the GitHub archive of acme_version, checked against the SHA-256' do
          is_expected.to contain_file('/opt/acme.sh-3.0.9.tar.gz').with(
            'source'         => 'https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.0.9.tar.gz',
            'checksum'       => 'sha256',
            'checksum_value' => 'a599e8373cd327fb611362bec6f1bfb0bf65c97b3401c440cfea9304a0f0cb41',
          )
        end

        it 'unpacks it into a directory of its own, whatever its top directory' do
          is_expected.to contain_exec('acme_kvstore-extract-acmesh').with(
            'command' => ['tar', 'xzf', '/opt/acme.sh-3.0.9.tar.gz', '-C', '/opt/acme.sh-3.0.9', '--strip-components=1'],
            'creates' => '/opt/acme.sh-3.0.9/acme.sh',
          ).that_requires(['File[/opt/acme.sh-3.0.9.tar.gz]', 'File[/opt/acme.sh-3.0.9]'])
        end

        it 'installs from there' do
          is_expected.to contain_exec('acme_kvstore-install-acmesh')
            .with(command: '/opt/acme.sh-3.0.9/acme.sh --install --home /root/.acme.sh --nocron', cwd: '/opt/acme.sh-3.0.9')
            .that_requires('Exec[acme_kvstore-extract-acmesh]')
        end
      end

      context "with install_method => 'archive' from a mirror" do
        let(:params) do
          { 'install_method' => 'archive', 'acme_version' => '3.1.1', 'acme_archive_url' => 'https://mirror.example.com/acme.sh-3.1.1.tar.gz',
            'acme_archive_sha256' => 'b' * 64, }
        end

        it do
          is_expected.to contain_file('/opt/acme.sh-3.1.1.tar.gz')
            .with(source: 'https://mirror.example.com/acme.sh-3.1.1.tar.gz', checksum_value: 'b' * 64)
        end
      end

      context 'with an invalid acme_archive_sha256' do
        let(:params) { { 'install_method' => 'archive', 'acme_archive_sha256' => 'not-a-checksum' } }

        it { is_expected.to compile.and_raise_error(%r{acme_archive_sha256}) }
      end

      context "with install_method => 'package' and a fixed version" do
        let(:params) { { 'install_method' => 'package', 'acme_package_ensure' => '3.0.9-1' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('acme.sh').with_ensure('3.0.9-1') }
        it { is_expected.not_to contain_exec('acme_kvstore-install-acmesh') }
        it { is_expected.not_to contain_vcsrepo('/opt/acme.sh-src') }
      end

      context 'with manage_user => true and manage_home => false' do
        let(:params) { { 'manage_user' => true, 'manage_home' => false, 'user' => 'acme', 'group' => 'acme' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_user('acme').with_managehome(false) }
        it { is_expected.not_to contain_file('/home/acme/.acme.sh') }
      end

      context 'with a custom acme_git_url, acme_git_force and acme_version' do
        let(:params) do
          { 'acme_git_url' => 'https://git.example.com/mirror/acme.sh.git', 'acme_git_force' => true, 'acme_version' => '3.1.1' }
        end

        it do
          is_expected.to contain_vcsrepo('/opt/acme.sh-src').with(
            'source'   => 'https://git.example.com/mirror/acme.sh.git',
            'force'    => true,
            'revision' => '3.1.1',
          )
        end
      end

      context 'with custom DNS API scripts' do
        let(:params) { { 'user' => 'acme', 'group' => 'acme' } }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend        => 'consul',
              consul         => { 'url' => 'https://consul.example.com:8501' },
              areas          => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              dnsapi_scripts => {
                'dns_rockenstein' => { 'source' => 'puppet:///modules/profile/acme/dns_rockenstein.sh' },
                'dns_inline'      => { 'content' => "dns_inline_add() { :; }\ndns_inline_rm() { :; }\n" },
              },
              dns_profiles   => {
                'rockenstein'       => { 'hook' => 'dns_rockenstein', 'env' => { 'ROX_Token' => Sensitive('token') } },
                'rockenstein_alias' => { 'hook' => 'dns_rockenstein', 'challenge_alias' => 'validation.example.com' },
                'route53'           => { 'hook' => 'dns_aws' },
              },
            }
          PUPPET
        end

        it { is_expected.to compile.with_all_deps }

        it 'installs the script into acme.sh\'s dnsapi directory, readable but not writable by the acme.sh user' do
          is_expected.to contain_file('/home/acme/.acme.sh/dnsapi/dns_rockenstein.sh').with(
            'ensure' => 'file',
            'owner'  => 'root',
            'group'  => 'acme',
            'mode'   => '0640',
            'source' => 'puppet:///modules/profile/acme/dns_rockenstein.sh',
          )
        end

        it { is_expected.to contain_file('/home/acme/.acme.sh/dnsapi/dns_rockenstein.sh').without_content }
        it { is_expected.to contain_file('/home/acme/.acme.sh/dnsapi/dns_inline.sh').with_content(%r{dns_inline_add}).with_mode('0640').without_source }

        it 'creates the dnsapi directory after acme.sh is installed' do
          is_expected.to contain_file('/home/acme/.acme.sh/dnsapi').with(
            'ensure' => 'directory', 'owner' => 'root', 'group' => 'acme', 'mode' => '0755',
          ).that_requires('Exec[acme_kvstore-install-acmesh]')
        end

        it { is_expected.not_to contain_file('/home/acme/.acme.sh/dnsapi/dns_aws.sh') }
      end

      context 'with a dns_nsupdate DNS profile' do
        let(:params) { { 'user' => 'acme', 'group' => 'acme' } }
        let(:pre_condition) do
          <<~PUPPET
            class { 'acme_kvstore':
              backend      => 'consul',
              consul       => { 'url' => 'https://consul.example.com:8501' },
              areas        => { 'web' => { 'secret' => '#{'S' * 32}', 'consul_token' => 'web-token' } },
              dns_profiles => {
                'bind'  => {
                  'hook'    => 'dns_nsupdate',
                  'env'     => { 'NSUPDATE_SERVER' => 'bind.example.com' },
                  'options' => { 'nsupdate_id' => 'acme-key', 'nsupdate_type' => 'hmac-sha256', 'nsupdate_key' => Sensitive('c2VjcmV0') },
                },
                'route53' => { 'hook' => 'dns_aws' },
              },
            }
          PUPPET
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/etc/acme_kvstore/nsupdate').with_owner('root').with_group('acme').with_mode('0750') }

        it 'writes the TSIG key file read-only for the acme.sh group, without showing a diff' do
          is_expected.to contain_file('/etc/acme_kvstore/nsupdate/bind.key').with(
            'owner' => 'root', 'group' => 'acme', 'mode' => '0640', 'show_diff' => false,
          )
        end

        it 'renders the key in BIND TSIG key format' do
          content = catalogue.resource('File', '/etc/acme_kvstore/nsupdate/bind.key')[:content]
          content = content.unwrap if content.respond_to?(:unwrap)
          expect(content).to include(%(key "acme-key" {), 'algorithm hmac-sha256;', %(secret "c2VjcmV0";))
        end

        it { is_expected.not_to contain_file('/etc/acme_kvstore/nsupdate/route53.key') }
      end
    end
  end
end
