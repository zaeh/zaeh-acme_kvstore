# frozen_string_literal: true

require_relative 'acceptance_helper'

%i[consul redis].each do |backend|
  describe "Issuing with acme.sh against Pebble, stored in #{backend}" do
    let(:kv_backend) { backend }
    let(:certid) { AcceptanceEnv.new_certid }
    let(:kv) { AcceptanceEnv.kv_client(kv_backend, 'web', 'write') }
    let(:doc) { PuppetX::AcmeKvstore::KvDocument }

    def read(suffix)
      kv.read_multi(["#{AcceptanceEnv::PREFIX}/#{suffix}"]).values.first
    end

    def provider(**params)
      AcceptanceEnv.certificate_provider(kv_backend, certid, **params)
    end

    def change_status(status)
      suffix = "web/certids/#{certid}"
      kv.transactional_update(AcceptanceEnv::PREFIX, suffix) { |meta| { suffix => meta.merge('status' => status) } }
    end

    it 'issues at once and stores certificate, encrypted key and issuer entry' do
      first = provider
      expect(first.exists?).to be(false)
      first.create

      meta = read("web/certids/#{certid}")
      expect(meta).to include('active_version' => 1, 'latest_version' => 1, 'status' => 'active', 'client' => 'puppet')
      renewal = meta.fetch('acme_renewal')
      expect(renewal).to include('version' => 1, 'domains' => ["#{certid}.example.test"], 'key_type' => 'ec', 'key_size' => 256)

      cert_doc = read("web/certs/#{certid}/1")
      expect(cert_doc.keys).to include('pem', 'tags', 'has_key', 'created_at', 'client')
      expect(cert_doc).to include('tags' => [], 'has_key' => true)
      expect(doc.split_pem(cert_doc['pem']).size).to eq(1)
      leaf = OpenSSL::X509::Certificate.new(cert_doc['pem'])

      envelope = read("web/keys/#{certid}/1")
      secret = PuppetX::AcmeKvstore::Crypto.decode_area_secret(AcceptanceEnv.area_secret)
      key = PuppetX::AcmeKvstore::Crypto.decrypt(envelope, secret, aad: PuppetX::AcmeKvstore::Crypto.aad('web', certid, 1))
      expect(leaf.check_private_key(OpenSSL::PKey.read(key))).to be(true)

      issuer_id = renewal.fetch('issuers').first
      expect(issuer_id).to match(%r{\Apebble-intermediate-ca-[0-9a-f]+_\d{4}-\d{2}-\d{2}\z})
      issuer = OpenSSL::X509::Certificate.new(read("web/certs/#{issuer_id}/1").fetch('pem'))
      expect(leaf.verify(issuer.public_key)).to be(true)
      expect(read("web/certids/#{issuer_id}")).to include('status' => 'active')
      expect(read("web/keys/#{issuer_id}/1")).to be_nil

      expect(provider.exists?).to be(true)
    end

    it 'renews into a new version when the module asks, keeping the status and reusing the issuer entry' do
      provider.create
      issuers = read("web/certids/#{certid}").dig('acme_renewal', 'issuers')
      change_status('norollout')

      renewing = provider(renew_before_days: 3650)
      expect(renewing.exists?).to be(false)
      renewing.create

      meta = read("web/certids/#{certid}")
      expect(meta).to include('active_version' => 2, 'latest_version' => 2, 'status' => 'norollout')
      expect(meta.dig('acme_renewal', 'issuers')).to eq(issuers)
      expect(read("web/certs/#{certid}/2")['pem']).not_to eq(read("web/certs/#{certid}/1")['pem'])
    end

    it 'reissues at once for a changed key type' do
      provider.create
      drifted = provider(key_type: 'rsa', key_size: 2048)
      expect(drifted.exists?).to be(false)
      drifted.create

      leaf = OpenSSL::X509::Certificate.new(read("web/certs/#{certid}/2")['pem'])
      expect(leaf.public_key).to be_a(OpenSSL::PKey::RSA)
    end

    it 'stops renewing with ensure => absent, keeping status and versions' do
      provider.create
      absent = provider(ensure: :absent)
      expect(absent.exists?).to be(true)
      absent.destroy

      meta = read("web/certids/#{certid}")
      expect(meta).not_to have_key('acme_renewal')
      expect(meta).to include('status' => 'active', 'active_version' => 1)
    end

    # A DNS hook that, like dns_infoblox, saves its setting in account.conf
    # (_saveaccountconf); Pebble accepts DNS-01 without a record.
    it 'passes the configured DNS hook settings every time, even after the hook saved older ones' do
      seen = File.join(AcceptanceEnv.workdir, "seen-#{certid}")
      hook = File.join(File.dirname(AcceptanceEnv.acmesh_path), 'dnsapi', 'dns_acceptance.sh')
      File.write(hook, <<~SH)
        dns_acceptance_add() { echo "$ACCEPTANCE_VALUE" >>"$ACCEPTANCE_SEEN"; _saveaccountconf ACCEPTANCE_VALUE "$ACCEPTANCE_VALUE"; }
        dns_acceptance_rm() { return 0; }
      SH
      dns = ->(value) { { dns_provider: 'dns_acceptance', dnssleep: 1, dns_env: { 'ACCEPTANCE_VALUE' => value, 'ACCEPTANCE_SEEN' => seen } } }

      provider(**dns.call('first')).create
      provider(**dns.call('second'), renew_before_days: 3650).create

      expect(File.readlines(seen, chomp: true)).to eq(%w[first second])
      expect(File.read(File.join(AcceptanceEnv.workdir, 'home', '.acme.sh', 'account.conf'))).not_to include('ACCEPTANCE_')
    end

    it 'stores no issuer entries with store_issuers => false' do
      provider(store_issuers: false).create
      expect(read("web/certids/#{certid}")['acme_renewal']).not_to have_key('issuers')
    end
  end
end
