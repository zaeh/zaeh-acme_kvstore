# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/acmesh'

describe Puppet::Type.type(:acme_kvstore_certificate).provider(:consul) do
  let(:resource) do
    Puppet::Type.type(:acme_kvstore_certificate).new(
      name:              'shop-example-com',
      area:              'web',
      domains:           ['shop.example.com'],
      backend_config:    { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' },
      area_secret:       'S' * 32,
      renew_before_days: 30,
      provider:          :consul,
    )
  end
  let(:provider) { resource.provider }
  let(:kv_client) { instance_double(PuppetX::AcmeKvstore::ConsulClient) }

  before do
    allow(provider).to receive(:kv_client).and_return(kv_client)
  end

  def meta_key
    'acme/web/certids/shop-example-com'
  end

  # The meta document's acme_renewal summary, as #create writes it.
  def summary(not_after: Time.now + (200 * 86_400), domains: ['shop.example.com'], key_type: 'rsa', key_size: 2048)
    PuppetX::AcmeKvstore::KvDocument.renewal_summary(not_after:, domains:, key_type:, key_size:)
  end

  def stub_meta(value, index: 7, client: kv_client)
    allow(client).to receive(:read_multi_with_index).with([meta_key]).and_return(meta_key => { value:, index: })
  end

  def active_meta(renewal = summary, version: 1, status: 'active')
    { 'status' => status, 'active_version' => version, 'latest_version' => version, 'acme_renewal' => renewal }
  end

  # A provider in a catalogue with a schedule 'nightly' whose window is open or closed right now.
  def scheduled_provider(open:)
    window = open ? { range: '00:00:00 - 23:59:59' } : { weekday: ((Time.now.wday + 1) % 7).to_s }
    catalog = Puppet::Resource::Catalog.new
    catalog.add_resource(Puppet::Type.type(:schedule).new(name: 'nightly', **window))
    scheduled = provider_for(renew_schedule: 'nightly')
    catalog.add_resource(scheduled.resource)
    scheduled
  end

  def provider_for(**params)
    defaults = {
      name: 'shop-example-com', area: 'web', domains: ['shop.example.com'],
      backend_config: { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' },
      area_secret: 'S' * 32, provider: :consul,
    }
    Puppet::Type.type(:acme_kvstore_certificate).new(defaults.merge(params))
                .provider.tap { |p| allow(p).to receive(:kv_client).and_return(kv_client) }
  end

  def issued(cert: build_pem(not_after: Time.now + (90 * 86_400)), chain: nil, fullchain: nil, key: nil)
    { cert:, chain:, fullchain:, key: }
  end

  describe '#exists?' do
    it 'returns false when no meta entry exists yet (first issuance)' do
      stub_meta(nil, index: 0)
      expect(provider.exists?).to be(false)
    end

    it 'issues a missing certificate at once, even outside the renew_schedule window' do
      stub_meta(nil, index: 0)
      expect(scheduled_provider(open: false).exists?).to be(false)
    end

    it 'decides from the meta document alone, with exactly one KV read' do
      expect(kv_client).to receive(:read_multi_with_index).once.with([meta_key]).and_return(meta_key => { value: active_meta, index: 7 })
      expect(kv_client).not_to receive(:read_multi)

      expect(provider.exists?).to be(true)
    end

    it 'never renews an entry archived in CCI-UI' do
      stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400)), status: 'delete').merge('archived' => true))
      expect(Puppet).to receive(:info).with(%r{archived \(CCI-UI\); not renewing it})
      expect(provider.exists?).to be(true)
    end

    describe 'another version activated in CCI-UI (acme_renewal describes an older one)' do
      let(:cert_key) { 'acme/web/certs/shop-example-com/3' }
      # purge_key_on_mismatch => false: the spec certificate's 1024-bit key is no drift here.
      let(:checker) { provider_for(purge_key_on_mismatch: false) }

      def meta_with_active(version)
        active_meta(summary.merge('version' => 2, 'issuers' => [])).merge('active_version' => version, 'latest_version' => 3)
      end

      it 'decides from the active certificate itself: valid -> nothing to do' do
        stub_meta(meta_with_active(3))
        expect(kv_client).to receive(:read_multi).with([cert_key]).and_return(
          cert_key => { 'pem' => AcmeKvstoreSpecPki.chain(leaf_not_after: Time.now + (200 * 86_400))[:leaf].to_pem },
        )
        expect(checker.exists?).to be(true)
      end

      it 'decides from the active certificate itself: due -> renew' do
        stub_meta(meta_with_active(3))
        expect(kv_client).to receive(:read_multi).with([cert_key]).and_return(
          cert_key => { 'pem' => AcmeKvstoreSpecPki.chain(leaf_not_after: Time.now + (5 * 86_400))[:leaf].to_pem },
        )
        expect(checker.exists?).to be(false)
      end

      it 'decides from the active certificate itself: other names -> reissue' do
        stub_meta(meta_with_active(3))
        expect(kv_client).to receive(:read_multi).with([cert_key]).and_return(
          cert_key => { 'pem' => build_pem(not_after: Time.now + (200 * 86_400)) },
        )
        expect(checker.exists?).to be(false)
      end

      it 'does not read again while acme_renewal describes the active version' do
        stub_meta(meta_with_active(2))
        expect(kv_client).not_to receive(:read_multi)
        expect(checker.exists?).to be(true)
      end
    end

    describe 'status (only relevant for distribution)' do
      %w[norollout delete].each do |status|
        it "does not reissue a valid certificate with status '#{status}'" do
          stub_meta(active_meta(status:))
          expect(provider.exists?).to be(true)
        end

        it "still renews a due certificate with status '#{status}'" do
          stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400)), status:))
          expect(provider.exists?).to be(false)
        end
      end
    end

    describe 'a meta document without acme_renewal (not issued by this module)' do
      let(:foreign_meta) { { 'status' => 'active', 'active_version' => 1, 'latest_version' => 1 } }

      it 'warns and never overwrites it' do
        stub_meta(foreign_meta)
        expect(kv_client).not_to receive(:read_multi)
        expect(Puppet).to receive(:warning).with(%r{acme/web/certids/shop-example-com exists but was not issued by acme_kvstore})

        expect(provider.exists?).to be(true)
      end

      it 'does nothing with ensure => absent' do
        resource[:ensure] = :absent
        stub_meta(foreign_meta)
        expect(Puppet).not_to receive(:warning)

        expect(provider.exists?).to be(false)
      end
    end

    it 'returns false when the certificate expires within renew_before_days (ensure => present)' do
      stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400))))
      expect(provider.exists?).to be(false)
    end

    describe 'renew_schedule' do
      it 'renews a due certificate while the window is open' do
        stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400))))
        expect(scheduled_provider(open: true).exists?).to be(false)
      end

      it 'postpones a due renewal while the window is closed' do
        stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400))))
        expect(Puppet).to receive(:info).with(%r{renewal due, outside schedule 'nightly'})
        expect(scheduled_provider(open: false).exists?).to be(true)
      end

      it 'does not postpone a reissue for configuration drift' do
        stub_meta(active_meta(summary(domains: ['other.example.com'])))
        expect(scheduled_provider(open: false).exists?).to be(false)
      end

      it 'fails clearly for an unknown schedule' do
        stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400))))
        catalog = Puppet::Resource::Catalog.new
        unknown = provider_for(renew_schedule: 'missing')
        catalog.add_resource(unknown.resource)
        expect { unknown.exists? }.to raise_error(Puppet::Error, %r{schedule 'missing' not found})
      end
    end

    describe 'configuration drift (forces a reissue even before the renewal window)' do
      it 'returns false when the SAN list no longer matches the resource' do
        stub_meta(active_meta(summary(domains: ['shop.example.com', 'checkout.example.com'])))
        expect(provider.exists?).to be(false)
      end

      it 'returns false when the key_type no longer matches the resource' do
        stub_meta(active_meta(summary(key_type: 'ec')))
        expect(provider.exists?).to be(false)
      end

      it 'returns false when the key_size no longer matches the resource' do
        stub_meta(active_meta(summary(key_size: 4096)))
        expect(provider.exists?).to be(false)
      end

      it 'ignores reordered SANs' do
        stub_meta(active_meta(summary(domains: ['shop.example.com', 'b.example.com', 'a.example.com'])))
        expect(provider_for(domains: ['shop.example.com', 'a.example.com', 'b.example.com']).exists?).to be(true)
      end

      it 'returns false when the primary domain changed, even with the same set of names' do
        stub_meta(active_meta(summary(domains: ['www.shop.example.com', 'shop.example.com'])))
        expect(provider_for(domains: ['shop.example.com', 'www.shop.example.com']).exists?).to be(false)
      end

      context 'with purge_key_on_mismatch => false' do
        it 'does not force a reissue for a changed key_size (it takes effect at the next regular renewal)' do
          stub_meta(active_meta(summary(key_size: 4096)))
          expect(provider_for(purge_key_on_mismatch: false).exists?).to be(true)
        end

        it 'still forces a reissue for a changed SAN list' do
          stub_meta(active_meta(summary(domains: ['other.example.com'], key_size: 4096)))
          expect(provider_for(purge_key_on_mismatch: false).exists?).to be(false)
        end
      end
    end

    it 'returns true for a soon-expiring certificate when ensure => absent, so destroy still runs' do
      resource[:ensure] = :absent
      stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400))))
      expect(provider.exists?).to be(true)
    end

    it 'lets KV read errors fail the resource instead of triggering an issuance' do
      allow(kv_client).to receive(:read_multi_with_index).and_raise(StandardError, 'connection failed')
      expect { provider.exists? }.to raise_error(StandardError, 'connection failed')
    end
  end

  describe '#create' do
    it 'invokes acme.sh and writes meta (with summary), certificate and key in one transactional_update' do
      leaf = build_pem(not_after: Time.utc(2027, 1, 1))
      allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(
        issued(cert: leaf, key: "-----BEGIN PRIVATE KEY-----\nFAKEKEY\n-----END PRIVATE KEY-----\n"),
      )

      expect(kv_client).to receive(:transactional_update).once do |prefix, watch_suffix, &block|
        expect(prefix).to eq('acme')
        expect(watch_suffix).to eq('web/certids/shop-example-com')
        writes = block.call(nil)

        expect(writes.keys).to contain_exactly('web/certs/shop-example-com/1', 'web/keys/shop-example-com/1', 'web/certids/shop-example-com')
        meta = writes['web/certids/shop-example-com']
        expect(meta).to include('active_version' => 1, 'status' => 'active')
        expect(meta).not_to have_key('active')
        expect(meta['acme_renewal']).to eq(
          'not_after' => '2027-01-01T00:00:00Z', 'domains' => ['shop.example.com'], 'key_type' => 'rsa', 'key_size' => 2048,
          'version' => 1, 'issuers' => []
        )
        expect(writes['web/certs/shop-example-com/1']).to eq(
          'pem' => leaf, 'tags' => [], 'has_key' => true, 'created_at' => writes['web/certs/shop-example-com/1']['created_at'],
          'client' => 'puppet', 'created_by' => provider.resource[:updated_by]
        )
        envelope = writes['web/keys/shop-example-com/1']
        expect(PuppetX::AcmeKvstore::Crypto.decrypt(envelope, 'S' * 32, aad: 'cci:web:shop-example-com/1')).to include('FAKEKEY')
        true
      end

      expect(provider.create).to be(true)
    end

    describe 'chain certificates' do
      let(:pki) { AcmeKvstoreSpecPki.chain }

      def int = pki[:intermediate]
      def name = PuppetX::AcmeKvstore::KvDocument.issuer_certid(int)
      def alt = PuppetX::AcmeKvstore::KvDocument.issuer_certid_alternative(int)
      def meta_key_of(certid) = "acme/web/certids/#{certid}"

      # Another CA certificate with the same CN and expiry date, i.e. the same name.
      def namesake
        AcmeKvstoreSpecPki.cert(subject: '/O=Test/CN=Test R1', key: OpenSSL::PKey::RSA.new(1024), ca_flag: true,
                                not_after: int.not_after)
      end

      def stub_issuer_metas(name_meta: nil, alt_meta: nil)
        expect(kv_client).to receive(:read_multi_with_index).with([meta_key_of(name), meta_key_of(alt)]).and_return(
          meta_key_of(name) => { value: name_meta, index: name_meta ? 5 : 0 },
          meta_key_of(alt) => { value: alt_meta, index: alt_meta ? 6 : 0 },
        )
      end

      def expect_leaf_write(issuers)
        expect(kv_client).to receive(:transactional_update).with('acme', 'web/certids/shop-example-com', expected: nil) do |*_args, &block|
          expect(block.call(nil)['web/certids/shop-example-com']['acme_renewal']).to include('version' => 1, 'issuers' => issuers)
          true
        end
      end

      before do
        allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(issued(cert: pki[:leaf].to_pem, chain: int.to_pem))
      end

      it 'names an entry <cn>_<expiry date>' do
        expect(name).to eq("test-r1_#{int.not_after.utc.strftime('%Y-%m-%d')}")
      end

      it 'stores each one as its own entry under that name, before the certificate itself' do
        stub_issuer_metas
        expect(kv_client).to receive(:transactional_update)
          .with('acme', "web/certids/#{name}", expected: { value: nil, index: 0 }).ordered do |*_args, &block|
            writes = block.call(nil)
            expect(writes.keys).to contain_exactly("web/certids/#{name}", "web/certs/#{name}/1")
            expect(writes["web/certids/#{name}"]).to include('active_version' => 1, 'latest_version' => 1, 'status' => 'active', 'client' => 'puppet')
            expect(writes["web/certids/#{name}"]).not_to have_key('acme_renewal')
            expect(writes["web/certs/#{name}/1"]).to include('pem' => int.to_pem, 'tags' => [], 'has_key' => false)
            true
          end
        expect_leaf_write([name]).ordered

        provider.create
      end

      it 'reuses an existing entry holding the same certificate (e.g. imported in CCI-UI) without touching it' do
        stub_issuer_metas(name_meta: { 'active_version' => 3, 'status' => 'active' })
        expect(kv_client).to receive(:read_multi).with(["acme/web/certs/#{name}/3"]).and_return("acme/web/certs/#{name}/3" => { 'pem' => int.to_pem })
        expect(kv_client).not_to receive(:transactional_update).with('acme', "web/certids/#{name}", anything)
        expect_leaf_write([name])

        provider.create
      end

      it 'stores another certificate with the same name under the alternative name' do
        stub_issuer_metas(name_meta: { 'active_version' => 1 })
        expect(kv_client).to receive(:read_multi).with(["acme/web/certs/#{name}/1"]).and_return("acme/web/certs/#{name}/1" => { 'pem' => namesake.to_pem })
        expect(kv_client).to receive(:transactional_update).with('acme', "web/certids/#{alt}", expected: { value: nil, index: 0 }).and_return(true)
        expect(kv_client).not_to receive(:transactional_update).with('acme', "web/certids/#{name}", anything)
        expect_leaf_write([alt])

        provider.create
      end

      it 'reuses the alternative name when it already holds the certificate' do
        stub_issuer_metas(name_meta: { 'active_version' => 1 }, alt_meta: { 'active_version' => 1 })
        expect(kv_client).to receive(:read_multi).with(["acme/web/certs/#{name}/1", "acme/web/certs/#{alt}/1"]).and_return(
          "acme/web/certs/#{name}/1" => { 'pem' => namesake.to_pem }, "acme/web/certs/#{alt}/1" => { 'pem' => int.to_pem },
        )
        expect_leaf_write([alt])

        provider.create
      end

      it 'fails rather than overwrite when both names hold other certificates' do
        stub_issuer_metas(name_meta: { 'active_version' => 1 }, alt_meta: { 'active_version' => 1 })
        other = namesake.to_pem
        expect(kv_client).to receive(:read_multi).and_return("acme/web/certs/#{name}/1" => { 'pem' => other }, "acme/web/certs/#{alt}/1" => { 'pem' => other })
        expect(kv_client).not_to receive(:transactional_update)

        expect { provider.create }.to raise_error(Puppet::Error, %r{#{name} and #{alt} hold other certificates})
      end

      it 'accepts that another writer stored it concurrently' do
        stub_issuer_metas
        expect(kv_client).to receive(:transactional_update).with('acme', "web/certids/#{name}", anything)
                                                           .and_raise(PuppetX::AcmeKvstore::ConsulClient::CasConflictError, '409')
        expect_leaf_write([name])

        expect(provider.create).to be(true)
      end

      it 'with store_issuers => false: neither reads nor writes issuer entries, and records no issuers' do
        expect(kv_client).not_to receive(:read_multi_with_index)
        expect(kv_client).to receive(:transactional_update).once.with('acme', 'web/certids/shop-example-com', expected: nil) do |*_args, &block|
          writes = block.call(nil)
          expect(writes.keys).to contain_exactly('web/certids/shop-example-com', 'web/certs/shop-example-com/1')
          expect(writes['web/certids/shop-example-com']['acme_renewal']).not_to have_key('issuers')
          true
        end

        provider_for(store_issuers: false).create
      end

      it 'does not store the certificate when its chain cannot be stored' do
        stub_issuer_metas
        expect(kv_client).to receive(:transactional_update).with('acme', "web/certids/#{name}", anything)
                                                           .and_raise(PuppetX::AcmeKvstore::ConsulClient::Error, 'HTTP 500')
        expect(kv_client).not_to receive(:transactional_update).with('acme', 'web/certids/shop-example-com', anything)

        expect { provider.create }.to raise_error(PuppetX::AcmeKvstore::ConsulClient::Error)
      end
    end

    it "writes on the basis of exists?'s read, without reading the meta document again" do
      stub_meta(active_meta(summary(not_after: Time.now + (10 * 86_400)), version: 4), index: 42)
      allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(issued)

      expect(provider.exists?).to be(false)
      expect(kv_client).to receive(:transactional_update)
        .with('acme', 'web/certids/shop-example-com', expected: { value: hash_including('latest_version' => 4), index: 42 }) do |*_args, &block|
          expect(block.call(active_meta(version: 4)).keys).to include('web/certs/shop-example-com/5')
          true
        end

      provider.create
      expect(kv_client).to have_received(:read_multi_with_index).once
    end

    it 'runs posthook_cmd after a successful create, with the configured user/group/timeout' do
      hooked_provider = provider_for(posthook_cmd: '/usr/bin/notify-deploy', exec_timeout: 60, run_as_user: 'acme', run_as_group: 'acme')
      allow(kv_client).to receive(:transactional_update)
      allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(issued)

      expect(PuppetX::AcmeKvstore::Acmesh).to receive(:run_posthook)
        .with('/usr/bin/notify-deploy', timeout: 60, run_as_user: 'acme', run_as_group: 'acme')

      hooked_provider.create
    end

    it 'logs a warning but does not fail the resource when posthook_cmd raises' do
      hooked_provider = provider_for(posthook_cmd: '/usr/bin/notify-deploy')
      allow(kv_client).to receive(:transactional_update)
      allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(issued)
      allow(PuppetX::AcmeKvstore::Acmesh).to receive(:run_posthook)
        .and_raise(PuppetX::AcmeKvstore::Acmesh::Error, 'notification endpoint unreachable')

      expect(Puppet).to receive(:warning).with(%r{posthook_cmd failed: notification endpoint unreachable})
      expect { hooked_provider.create }.not_to raise_error
    end

    it 'increments the version number when a certificate already exists' do
      allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(issued)

      expect(kv_client).to receive(:transactional_update) do |_prefix, _watch_suffix, &block|
        writes = block.call('latest_version' => 4)

        expect(writes.keys).to contain_exactly('web/certs/shop-example-com/5', 'web/certids/shop-example-com')
        expect(writes['web/certids/shop-example-com']['active_version']).to eq(5)
        true
      end

      provider.create
    end

    it 'keeps the existing status and any other fields of the meta document when renewing' do
      allow(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).and_return(issued)

      expect(kv_client).to receive(:transactional_update) do |_prefix, _watch_suffix, &block|
        meta = block.call(active_meta(version: 2, status: 'norollout').merge('note' => 'kept'))['web/certids/shop-example-com']

        expect(meta).to include('status' => 'norollout', 'note' => 'kept', 'active_version' => 3, 'latest_version' => 3)
        true
      end

      provider.create
    end
  end

  describe '#create with CA/DNS profile-derived parameters' do
    it 'forwards them all through to Acmesh.issue_or_renew' do
      profiled_provider = provider_for(
        server: 'zerossl', account_email: 'ssl@example.com', eab_kid: 'KID123', eab_hmac_key: 'HMAC456',
        dns_provider: 'dns_aws', dns_env: { 'AWS_ACCESS_KEY_ID' => 'x' }, dns_options: { 'aws_region' => 'eu-central-1' },
        challenge_alias: 'alias.example.com', domain_alias: 'domain-alias.example.com',
        proxy: 'proxy.example.com:3128', exec_timeout: 120,
        run_as_user: 'acme', run_as_group: 'acme', run_as_home: '/home/acme/.acme.sh',
        dnssleep: 90, webroot: '/srv/acme-challenge', log_file: '/var/log/acme.sh/acme.log', log_level: 2
      )
      allow(kv_client).to receive(:transactional_update)

      expect(PuppetX::AcmeKvstore::Acmesh).to receive(:issue_or_renew).with(
        hash_including(
          server: 'zerossl', account_email: 'ssl@example.com', eab_kid: 'KID123', eab_hmac_key: 'HMAC456',
          dns_provider: 'dns_aws', dns_env: { 'AWS_ACCESS_KEY_ID' => 'x' }, dns_options: { 'aws_region' => 'eu-central-1' },
          challenge_alias: 'alias.example.com', domain_alias: 'domain-alias.example.com',
          proxy: 'proxy.example.com:3128', exec_timeout: 120,
          run_as_user: 'acme', run_as_group: 'acme', run_as_home: '/home/acme/.acme.sh',
          dnssleep: 90, webroot: '/srv/acme-challenge', log_file: '/var/log/acme.sh/acme.log', log_level: 2
        ),
      ).and_return(issued)

      profiled_provider.create
    end
  end

  describe '#destroy' do
    it 'only removes acme_renewal; status and versions stay' do
      expect(kv_client).to receive(:transactional_update) do |_prefix, _watch_suffix, &block|
        meta = block.call(active_meta(status: 'active'))['web/certids/shop-example-com']
        expect(meta).not_to have_key('acme_renewal')
        expect(meta).to include('status' => 'active', 'active_version' => 1, 'latest_version' => 1)
        true
      end
      provider.destroy
    end

    it 'writes nothing when no meta entry exists yet' do
      expect(kv_client).to receive(:transactional_update) do |_prefix, _watch_suffix, &block|
        expect(block.call(nil)).to be_nil
        true
      end
      provider.destroy
    end
  end

  def build_pem(not_after:)
    key = OpenSSL::PKey::RSA.new(1024)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse('/CN=test.example.com')
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = not_after
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    cert.to_pem
  end
end
