# frozen_string_literal: true

require_relative 'acceptance_helper'

%i[consul redis].each do |backend|
  describe "Reading certificates from #{backend} with the read-only credentials" do
    let(:kv_backend) { backend }
    let(:prefix) { AcceptanceEnv::PREFIX }
    let(:writer) { AcceptanceEnv.kv_client(kv_backend, 'web', 'write') }

    # Redis needs +scan for searches; Consul's read token includes it.
    def reader(scan: false)
      AcceptanceEnv.kv_client(kv_backend, 'web', (scan && kv_backend == :redis) ? 'read_scan' : 'read')
    end

    def lookup(certid, client: reader, **options)
      PuppetX::AcmeKvstore::CertLookup.lookup(kv_client: client, prefix:, area: 'web', certid:, **options)
    end

    def read(suffix)
      writer.read_multi(["#{prefix}/#{suffix}"]).values.first
    end

    def pebble_root
      OpenSSL::X509::Certificate.new(AcceptanceEnv.pebble_root_pem)
    end

    it 'returns certificate and decrypted key, without a chain unless asked' do
      certid = AcceptanceEnv.issued(kv_backend)
      result = lookup(certid, decrypt_key: true, area_secret: AcceptanceEnv.area_secret)

      leaf = OpenSSL::X509::Certificate.new(result[:pem])
      expect(result).to include(status: 'active', has_key: true, chain: nil, fullchain: nil, chain_missing: nil)
      expect(leaf.check_private_key(OpenSSL::PKey.read(result[:private_key]))).to be(true)
    end

    it 'builds the chain from the recorded issuer entry' do
      certid = AcceptanceEnv.issued(kv_backend)
      result = lookup(certid, include_chain: true)

      issuer_id = read("web/certids/#{certid}").dig('acme_renewal', 'issuers').first
      expect(result[:chain]).to eq(read("web/certs/#{issuer_id}/1")['pem'])
      expect(result).to include(fullchain: result[:pem] + result[:chain], chain_missing: false)
    end

    it 'finds the root when it is stored as an entry (include_root)' do
      root = pebble_root
      root_id = PuppetX::AcmeKvstore::KvDocument.issuer_certid(root)
      writer.transactional_update(prefix, "web/certids/#{root_id}") do |current|
        next nil if current

        { "web/certids/#{root_id}" => { 'active_version' => 1, 'latest_version' => 1, 'status' => 'active' },
          "web/certs/#{root_id}/1" => { 'pem' => root.to_pem, 'tags' => [], 'has_key' => false, 'created_at' => 'x', 'client' => 'puppet' }, }
      end

      result = lookup(AcceptanceEnv.issued(kv_backend), client: reader(scan: true), include_chain: true, include_root: true)
      expect(result[:root]).to eq(root.to_pem)
      expect(result[:chain]).not_to include(root.to_pem)
    end

    it 'searches the area for the chain of a certificate stored without issuer entries' do
      certid = AcceptanceEnv.issued(kv_backend, :no_issuers, store_issuers: false)
      AcceptanceEnv.issued(kv_backend) # makes sure the intermediate is stored as an entry

      expect(lookup(certid, client: reader(scan: true), include_chain: true)).to include(chain_missing: false)
    end

    if backend == :redis
      it 'degrades a search refused by Redis (no +scan) to a missing chain' do
        certid = AcceptanceEnv.issued(kv_backend, :no_issuers, store_issuers: false)
        result = lookup(certid, include_chain: true)

        expect(result).to include(chain: nil, chain_missing: true)
        expect(result[:chain_error]).to match(%r{NOPERM}i)
        expect(result[:pem]).not_to be_nil
      end
    end

    it 'withholds certificate data for any status but active' do
      certid = AcceptanceEnv.issued(kv_backend, :withheld)
      suffix = "web/certids/#{certid}"
      %w[norollout delete].each do |status|
        writer.transactional_update(prefix, suffix) { |meta| { suffix => meta.merge('status' => status) } }
        expect(lookup(certid, include_chain: true)).to include(status:, pem: nil, chain: nil, private_key: nil)
      end
    end
  end
end
