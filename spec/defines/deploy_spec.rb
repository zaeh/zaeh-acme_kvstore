# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/cert_lookup'
require 'puppet_x/acme_kvstore/consul_client'
require 'puppet_x/acme_kvstore/redis_client'

describe 'acme_kvstore::deploy' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }
      let(:title) { 'shop-example-com' }
      # deploy does not declare the acme_kvstore class; its defaults come
      # straight from Hiera (backend, consul, prefix, default_area, areas).
      let(:hiera_config) { File.expand_path('../fixtures/hiera/hiera.yaml', __dir__) }

      before do
        allow(PuppetX::AcmeKvstore::ConsulClient).to receive(:new)
          .and_return(instance_double(PuppetX::AcmeKvstore::ConsulClient))
      end

      context 'with an active certificate and no key_path' do
        let(:title) { 'shop-active-no-key' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem' } }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: 'CERTDATA', chain: 'CHAINDATA', fullchain: nil, has_key: false, private_key: nil
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/etc/ssl/certs/shop.pem').with_ensure('file').with_content('CERTDATA') }
        it { is_expected.not_to contain_file('/etc/ssl/private/shop.key') }

        # A distinct title here (rather than reusing the title used by the
        # sibling examples above) is required, not just cosmetic: rspec-puppet
        # caches compiled catalogues process-wide, keyed on (node, facts,
        # generated code) - NOT on what our mocks return. The sibling examples
        # above already populate that cache for this context's title using the
        # general `allow` stub, so this example's own, more specific `expect`
        # would otherwise never be consulted at all.
        context 'checking the decrypt_key argument specifically' do
          let(:title) { 'shop-active-no-key-decrypt-check' }

          it 'does not ask lookup_cert to decrypt a key' do
            expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(decrypt_key: false)).and_return(
              status: 'active', active_version: 1, latest_version: 1, updated_at: 'x', pem: 'CERTDATA', chain: 'CHAINDATA', fullchain: nil, has_key: false, private_key: nil,
            )
            catalogue
          end
        end
      end

      context 'with a key_path given' do
        let(:title) { 'shop-with-key-path' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'key_path' => '/etc/ssl/private/shop.key' } }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: 'CERTDATA', chain: 'CHAINDATA', fullchain: nil, has_key: true, private_key: 'KEYDATA'
          )
        end

        it { is_expected.to contain_file('/etc/ssl/private/shop.key').with_mode('0600').with_show_diff(false) }

        # See the comment above the sibling nested context in "with an active
        # certificate and no key_path" for why this needs its own title.
        context 'checking the decrypt_key argument specifically' do
          let(:title) { 'shop-with-key-path-decrypt-check' }

          it 'asks lookup_cert to decrypt the key' do
            expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(decrypt_key: true)).and_return(
              status: 'active', active_version: 1, latest_version: 1, updated_at: 'x', pem: 'CERTDATA', chain: 'CHAINDATA', fullchain: nil, has_key: true, private_key: 'KEYDATA',
            )
            catalogue
          end
        end
      end

      context 'with every optional output file' do
        let(:title) { 'shop-all-files' }
        let(:params) do
          {
            'cert_path'           => '/etc/ssl/shop/cert.pem',
            'key_path'            => '/etc/ssl/shop/key.pem',
            'chain_path'          => '/etc/ssl/shop/chain.pem',
            'fullchain_path'      => '/etc/ssl/shop/fullchain.pem',
            'combined_path'       => '/etc/ssl/shop/combined.pem',
            'combined_include_dh' => true,
            'dh_path'             => '/etc/ssl/shop/dhparams.pem',
            'dh_param_size'       => 3072,
          }
        end

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: leaf, chain:, fullchain: "#{leaf}#{chain}", has_key: true, private_key: key
          )
        end

        def leaf
          "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n"
        end

        def chain
          "-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----\n"
        end

        def key
          "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n"
        end

        def content_of(path)
          content = catalogue.resource('File', path)[:content]
          content.respond_to?(:unwrap) ? content.unwrap : content
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/etc/ssl/shop/cert.pem').with_content(leaf).with_mode('0644') }
        it { is_expected.to contain_file('/etc/ssl/shop/chain.pem').with_content(chain).with_mode('0644') }
        it { is_expected.to contain_file('/etc/ssl/shop/fullchain.pem').with_content("#{leaf}#{chain}") }
        it { is_expected.to contain_file('/etc/ssl/shop/combined.pem').with_mode('0600').with_show_diff(false) }

        it 'writes certificate, chain, key and DH parameters into the combined file, in that order' do
          content = content_of('/etc/ssl/shop/combined.pem')
          expect(content).to start_with("#{leaf}#{chain}#{key}-----BEGIN DH PARAMETERS-----")
        end

        it 'writes the RFC 7919 ffdhe group of the requested size' do
          expect(content_of('/etc/ssl/shop/dhparams.pem')).to eq(File.read(File.expand_path('../../files/dhparams/ffdhe3072.pem', __dir__)))
        end
      end

      context 'with only combined_path (and no key_path)' do
        let(:title) { 'shop-combined-decrypt-check' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'combined_path' => '/etc/haproxy/shop.pem' } }

        it 'still asks lookup_cert to decrypt the key' do
          expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(decrypt_key: true)).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: 'CERTDATA', chain: nil, fullchain: nil, has_key: true, private_key: 'KEYDATA'
          )
          catalogue
        end
      end

      context 'with chain/fullchain/combined paths for a certificate whose issuer is not stored' do
        let(:title) { 'shop-issuer-missing' }
        let(:params) do
          {
            'cert_path'      => '/etc/ssl/shop/cert.pem',
            'chain_path'     => '/etc/ssl/shop/chain.pem',
            'fullchain_path' => '/etc/ssl/shop/fullchain.pem',
            'combined_path'  => '/etc/ssl/shop/combined.pem',
          }
        end
        let(:logs) { [] }

        before do
          Puppet::Util::Log.newdestination(Puppet::Test::LogCollector.new(logs))
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: "CERTDATA\n", chain: nil, fullchain: nil, chain_missing: true, has_key: true, private_key: "KEYDATA\n"
          )
        end

        after { Puppet::Util::Log.close_all }

        it 'writes the certificate, skips chain and fullchain, writes combined without chain, and warns once' do
          is_expected.to compile.with_all_deps
          is_expected.to contain_file('/etc/ssl/shop/cert.pem').with_content("CERTDATA\n")
          is_expected.not_to contain_file('/etc/ssl/shop/chain.pem')
          is_expected.not_to contain_file('/etc/ssl/shop/fullchain.pem')
          expect(catalogue.resource('File', '/etc/ssl/shop/combined.pem')[:content]).to eq("CERTDATA\nKEYDATA\n")

          warnings = logs.select { |log| log.level == :warning }.map(&:message)
          expect(warnings.grep(%r{issuer of certificate 'shop-issuer-missing' not found in area 'web'}).size).to eq(1)
        end
      end

      {
        'cert_path'      => '/etc/ssl/one/cert.pem',
        'chain_path'     => '/etc/ssl/one/chain.pem',
        'fullchain_path' => '/etc/ssl/one/fullchain.pem',
        'combined_path'  => '/etc/ssl/one/combined.pem',
      }.each do |param, file|
        context "with only #{param} (besides the required cert_path)" do
          let(:title) { "shop-only-#{param.tr('_', '-')}" }
          let(:params) { { 'cert_path' => '/etc/ssl/one/cert.pem', param => file } }

          before do
            allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
              status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
              pem: "CERTDATA\n", chain: "CHAINDATA\n", fullchain: "CERTDATA\nCHAINDATA\n", chain_missing: false,
              has_key: true, private_key: "KEYDATA\n"
            )
          end

          it 'writes exactly the requested files' do
            expected = {
              'cert_path'      => "CERTDATA\n",
              'chain_path'     => "CHAINDATA\n",
              'fullchain_path' => "CERTDATA\nCHAINDATA\n",
              'combined_path'  => "CERTDATA\nCHAINDATA\nKEYDATA\n",
            }
            managed = catalogue.resources.select { |res| res.type == 'File' }.map(&:title)
            expect(managed).to match_array(['/etc/ssl/one/cert.pem', file].uniq)
            content = catalogue.resource('File', file)[:content]
            expect(content.respond_to?(:unwrap) ? content.unwrap : content).to eq(expected[param])
          end
        end
      end

      context 'with chain_include_root' do
        let(:title) { 'shop-with-root' }
        let(:params) do
          {
            'cert_path'          => '/etc/ssl/root/cert.pem',
            'chain_path'         => '/etc/ssl/root/chain.pem',
            'fullchain_path'     => '/etc/ssl/root/fullchain.pem',
            'combined_path'      => '/etc/ssl/root/combined.pem',
            'chain_include_root' => true,
          }
        end

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(include_root: true)).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: "CERT\n", chain: "INT\n", fullchain: "CERT\nINT\n", chain_missing: false, root: "ROOT\n",
            has_key: true, private_key: "KEY\n"
          )
        end

        it 'appends the root to chain, fullchain and the certificates of the combined file' do
          is_expected.to contain_file('/etc/ssl/root/cert.pem').with_content("CERT\n")
          is_expected.to contain_file('/etc/ssl/root/chain.pem').with_content("INT\nROOT\n")
          is_expected.to contain_file('/etc/ssl/root/fullchain.pem').with_content("CERT\nINT\nROOT\n")
          expect(catalogue.resource('File', '/etc/ssl/root/combined.pem')[:content]).to eq("CERT\nINT\nROOT\nKEY\n")
        end
      end

      context 'with chain_include_root but no stored root' do
        let(:title) { 'shop-root-missing' }
        let(:params) { { 'cert_path' => '/etc/ssl/noroot/cert.pem', 'fullchain_path' => '/etc/ssl/noroot/fullchain.pem', 'chain_include_root' => true } }
        let(:logs) { [] }

        before do
          Puppet::Util::Log.newdestination(Puppet::Test::LogCollector.new(logs))
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: "CERT\n", chain: "INT\n", fullchain: "CERT\nINT\n", chain_missing: false, root: nil, has_key: false, private_key: nil
          )
        end

        after { Puppet::Util::Log.close_all }

        it 'writes the chain without the root and warns' do
          is_expected.to contain_file('/etc/ssl/noroot/fullchain.pem').with_content("CERT\nINT\n")
          expect(logs.select { |log| log.level == :warning }.map(&:message))
            .to include(a_string_matching(%r{root CA of certificate 'shop-root-missing' not stored in area 'web'.*import it}))
        end
      end

      context 'without chain_include_root' do
        let(:title) { 'shop-without-root' }
        let(:params) { { 'cert_path' => '/etc/ssl/plain/cert.pem', 'fullchain_path' => '/etc/ssl/plain/fullchain.pem' } }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(include_root: false)).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: "CERT\n", chain: "INT\n", fullchain: "CERT\nINT\n", chain_missing: false, root: "ROOT\n", has_key: false, private_key: nil
          )
        end

        it 'never adds the root, even when it is stored' do
          is_expected.to contain_file('/etc/ssl/plain/fullchain.pem').with_content("CERT\nINT\n")
        end
      end

      context 'with only cert_path and key_path' do
        let(:title) { 'shop-no-chain-needed' }
        let(:params) { { 'cert_path' => '/etc/ssl/nochain/cert.pem', 'key_path' => '/etc/ssl/nochain/key.pem' } }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(include_chain: false)).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x', pem: "CERT\n", has_key: true, private_key: "KEY\n",
          )
        end

        it 'does not ask for a chain (no issuer search)' do
          is_expected.to compile.with_all_deps
          is_expected.to contain_file('/etc/ssl/nochain/cert.pem').with_content("CERT\n")
        end
      end

      %w[chain_path fullchain_path combined_path].each do |param|
        context "with #{param}" do
          let(:title) { "shop-chain-needed-#{param.tr('_', '-')}" }
          let(:params) { { 'cert_path' => '/etc/ssl/needed/cert.pem', param => '/etc/ssl/needed/other.pem' } }

          before do
            allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(include_chain: true)).and_return(
              status: 'active', active_version: 1, latest_version: 1, updated_at: 'x', pem: "CERT\n", chain: "INT\n",
              fullchain: "CERT\nINT\n", chain_missing: false, has_key: true, private_key: "KEY\n"
            )
          end

          it { is_expected.to compile.with_all_deps }
        end
      end

      context 'when the issuer search failed' do
        let(:title) { 'shop-search-failed' }
        let(:params) { { 'cert_path' => '/etc/ssl/failed/cert.pem', 'fullchain_path' => '/etc/ssl/failed/fullchain.pem' } }
        let(:logs) { [] }

        before do
          Puppet::Util::Log.newdestination(Puppet::Test::LogCollector.new(logs))
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x', pem: "CERT\n", chain: nil, fullchain: nil,
            chain_missing: true, chain_error: 'RuntimeError: NOPERM scan', has_key: false, private_key: nil
          )
        end

        after { Puppet::Util::Log.close_all }

        it 'names the reason in the warning and still writes the certificate' do
          is_expected.to contain_file('/etc/ssl/failed/cert.pem').with_content("CERT\n")
          is_expected.not_to contain_file('/etc/ssl/failed/fullchain.pem')
          expect(logs.select { |log| log.level == :warning }.map(&:message))
            .to include(a_string_matching(%r{not found in area 'web' \(search failed: RuntimeError: NOPERM scan\)}))
        end
      end

      context 'with a norollout certificate' do
        let(:title) { 'shop-norollout' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem' } }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'norollout', active_version: 1, latest_version: 1, updated_at: 'x', pem: nil, has_key: nil, private_key: nil,
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_file('/etc/ssl/certs/shop.pem') }
      end

      context 'with a certificate marked delete' do
        let(:title) { 'shop-delete' }
        let(:params) do
          {
            'cert_path'       => '/etc/ssl/shop/cert.pem',
            'key_path'        => '/etc/ssl/shop/key.pem',
            'chain_path'      => '/etc/ssl/shop/chain.pem',
            'fullchain_path'  => '/etc/ssl/shop/fullchain.pem',
            'combined_path'   => '/etc/ssl/shop/combined.pem',
            'dh_path'         => '/etc/ssl/shop/dhparams.pem',
            'notify_services' => ['nginx'],
          }
        end
        let(:pre_condition) { "service { 'nginx': }" }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'delete', active_version: 1, latest_version: 1, updated_at: 'x', pem: nil, has_key: nil, private_key: nil,
          )
        end

        it { is_expected.to compile.with_all_deps }

        %w[cert key chain fullchain combined dhparams].each do |name|
          it "removes /etc/ssl/shop/#{name}.pem and notifies the services" do
            is_expected.to contain_file("/etc/ssl/shop/#{name}.pem").with_ensure('absent').that_notifies('Service[nginx]')
          end
        end
      end

      context 'with an unknown status' do
        let(:title) { 'shop-unknown-status' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem' } }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'paused', active_version: 1, latest_version: 1, updated_at: 'x', pem: nil, has_key: nil, private_key: nil,
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_file('/etc/ssl/certs/shop.pem') }
      end

      context 'with no certificate issued yet' do
        let(:title) { 'shop-no-cert-yet' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem' } }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: nil, active_version: nil, latest_version: nil, updated_at: nil, pem: nil, has_key: nil, private_key: nil,
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_file('/etc/ssl/certs/shop.pem') }
      end

      context 'with notify_services' do
        let(:title) { 'shop-notify-services' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'notify_services' => ['nginx'] } }
        let(:pre_condition) { "service { 'nginx': }" }

        before do
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x', pem: 'CERTDATA', chain: 'CHAINDATA', fullchain: nil, has_key: false, private_key: nil,
          )
        end

        it { is_expected.to contain_file('/etc/ssl/certs/shop.pem').that_notifies('Service[nginx]') }
      end

      context 'without an area and without acme_kvstore::default_area in Hiera' do
        let(:title) { 'shop-no-area' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem' } }
        let(:hiera_config) { File::NULL }

        it { is_expected.to compile.and_raise_error(%r{no 'area' given and no acme_kvstore::default_area in Hiera}) }
      end

      context 'independent of the acme_kvstore class and the worker' do
        let(:title) { 'shop-standalone' }
        let(:hiera_config) { File::NULL }
        let(:params) do
          {
            'cert_path'      => '/etc/ssl/certs/shop.pem',
            'key_path'       => '/etc/ssl/private/shop.key',
            'area'           => 'edge',
            'area_secret'    => 'E' * 32,
            'backend'        => 'redis',
            'backend_config' => { 'host' => 'redis.example.com', 'prefix' => 'certs' },
          }
        end

        before do
          allow(PuppetX::AcmeKvstore::RedisClient).to receive(:new)
            .and_return(instance_double(PuppetX::AcmeKvstore::RedisClient))
          allow(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: 'CERTDATA', chain: nil, fullchain: nil, has_key: true, private_key: 'KEYDATA'
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_class('acme_kvstore') }
        it { is_expected.not_to contain_class('acme_kvstore::worker') }
        it { is_expected.to contain_file('/etc/ssl/private/shop.key') }

        context 'checking the explicitly passed values specifically' do
          let(:title) { 'shop-standalone-args-check' }

          it 'uses only the explicitly passed backend, area and secret' do
            expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(
              hash_including(prefix: 'certs', area: 'edge', certid: 'shop-standalone-args-check', decrypt_key: true, area_secret: 'E' * 32),
            ).and_return(
              status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
              pem: 'CERTDATA', chain: nil, fullchain: nil, has_key: true, private_key: 'KEYDATA'
            )
            catalogue
          end
        end
      end

      context 'without a key to write' do
        let(:title) { 'shop-unknown-area-no-key' }
        let(:params) do
          {
            'cert_path'      => '/etc/ssl/certs/shop.pem',
            'area'           => 'not_in_hiera',
            'backend_config' => { 'url' => 'https://consul.example.com:8501', 'token' => 'explicit-token', 'prefix' => 'acme' },
          }
        end

        it 'needs no area secret at all' do
          expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(area: 'not_in_hiera', area_secret: nil)).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: 'CERTDATA', chain: nil, fullchain: nil, has_key: false, private_key: nil
          )
          catalogue
        end
      end

      context 'with the Redis backend and an area with its own read-only Redis ACL user' do
        let(:title) { 'shop-redis-area-user-check' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'area' => 'internal', 'backend' => 'redis' } }

        it "connects as the area's read-only Redis user, not the worker's" do
          expect(PuppetX::AcmeKvstore::RedisClient).to receive(:new)
            .with({ 'username' => 'acme-internal-read', 'password' => 'internal-read-password', 'prefix' => 'acme' })
            .and_return(instance_double(PuppetX::AcmeKvstore::RedisClient))
          expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(area: 'internal')).and_return(
            status: nil, active_version: nil, latest_version: nil, updated_at: nil,
            pem: nil, chain: nil, fullchain: nil, has_key: nil, private_key: nil
          )
          catalogue
        end
      end

      context 'with the Consul backend from Hiera and an area that is not in Hiera' do
        let(:title) { 'shop-no-area-token' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'area' => 'not_in_hiera' } }

        it { is_expected.to compile.and_raise_error(%r{area 'not_in_hiera' has no 'consul_read_token'}) }
      end

      context 'with an area that only has the worker credentials' do
        context 'with Consul' do
          let(:title) { 'shop-workeronly-consul' }
          let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'area' => 'workeronly' } }

          it 'does not fall back to the worker token' do
            is_expected.to compile.and_raise_error(%r{area 'workeronly' has no 'consul_read_token'})
          end
        end

        context 'with Redis' do
          let(:title) { 'shop-workeronly-redis' }
          let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'area' => 'workeronly', 'backend' => 'redis' } }

          it 'does not fall back to the worker user' do
            is_expected.to compile.and_raise_error(%r{area 'workeronly' has no 'redis_read_username'/'redis_read_password'})
          end
        end
      end

      context 'with a key to write but an area that is neither passed nor in Hiera' do
        let(:title) { 'shop-unknown-area-key' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'key_path' => '/etc/ssl/private/shop.key', 'area' => 'not_in_hiera' } }

        it { is_expected.to compile.and_raise_error(%r{no 'area_secret' given and area 'not_in_hiera' not found}) }
      end

      context 'with the defaults from Hiera' do
        let(:title) { 'shop-hiera-defaults-check' }
        let(:params) { { 'cert_path' => '/etc/ssl/certs/shop.pem', 'key_path' => '/etc/ssl/private/shop.key' } }

        it "uses the Consul settings with the area's read-only token, the prefix, default area and area secret from Hiera" do
          expect(PuppetX::AcmeKvstore::ConsulClient).to receive(:new)
            .with({ 'url' => 'https://consul.example.com:8501', 'datacenter' => 'dc2', 'token' => 'web-read-token', 'prefix' => 'acme' })
            .and_return(instance_double(PuppetX::AcmeKvstore::ConsulClient))
          expect(PuppetX::AcmeKvstore::CertLookup).to receive(:lookup).with(hash_including(area: 'web', area_secret: 'S' * 32)).and_return(
            status: 'active', active_version: 1, latest_version: 1, updated_at: 'x',
            pem: 'CERTDATA', chain: nil, fullchain: nil, has_key: true, private_key: 'KEYDATA'
          )
          catalogue
        end
      end
    end
  end
end
