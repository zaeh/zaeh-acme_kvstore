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
            'gid'    => 'acme',
            'home'   => '/home/acme/.acme.sh',
            'system' => true,
            'shell'  => '/usr/sbin/nologin',
          )
        end
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
