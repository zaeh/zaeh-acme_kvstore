# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/cert_lookup'
require 'puppet_x/acme_kvstore/crypto'
require 'puppet_x/acme_kvstore/consul_client'

describe PuppetX::AcmeKvstore::CertLookup do
  let(:kv_client) { instance_double(PuppetX::AcmeKvstore::ConsulClient) }
  let(:base_args) { { kv_client:, prefix: 'acme', area: 'web', certid: 'shop-example-com' } }
  let(:pki) { AcmeKvstoreSpecPki.chain }

  def leaf = pki[:leaf]
  def intermediate = pki[:intermediate]
  def root = pki[:root]
  def meta_key = 'acme/web/certids/shop-example-com'
  def cert_key = 'acme/web/certs/shop-example-com/2'
  def key_key = 'acme/web/keys/shop-example-com/2'

  def certid_of(cert)
    PuppetX::AcmeKvstore::KvDocument.issuer_certid(cert)
  end

  def cert_doc(cert, has_key: false)
    { 'pem' => cert.to_pem, 'tags' => [], 'has_key' => has_key, 'created_at' => 'x', 'client' => 'puppet' }
  end

  def stub_meta(meta)
    expect(kv_client).to receive(:read_multi).with([meta_key]).and_return(meta_key => meta)
  end

  def active_meta(renewal = nil)
    meta = { 'status' => 'active', 'active_version' => 2, 'latest_version' => 2, 'updated_at' => 'x' }
    meta['acme_renewal'] = renewal if renewal
    meta
  end

  it 'returns all-nil when no meta document exists, with a single read' do
    stub_meta(nil)

    expect(described_class.lookup(**base_args)).to eq(
      status: nil, active_version: nil, latest_version: nil, updated_at: nil,
      pem: nil, chain: nil, fullchain: nil, chain_missing: nil, chain_error: nil, root: nil, has_key: nil, private_key: nil
    )
  end

  %w[norollout delete paused].each do |status|
    it "returns the status but withholds certificate data for status '#{status}', without reading it" do
      stub_meta('status' => status, 'active_version' => 3, 'latest_version' => 4, 'updated_at' => 'x')
      expect(kv_client).not_to receive(:read_prefix)

      result = described_class.lookup(**base_args)

      expect(result).to include(status:, active_version: 3, latest_version: 4, pem: nil, chain: nil, has_key: nil, private_key: nil)
    end
  end

  it 'builds no chain without include_chain: no issuer reads, no search' do
    stub_meta(active_meta('version' => 2, 'issuers' => [certid_of(intermediate)]))
    expect(kv_client).to receive(:read_multi).with([cert_key]).and_return(cert_key => cert_doc(leaf))
    expect(kv_client).not_to receive(:read_prefix)

    expect(described_class.lookup(**base_args)).to include(pem: leaf.to_pem, chain: nil, fullchain: nil, chain_missing: nil, root: nil)
  end

  it 'reports a failed search (e.g. Redis without +scan) as a missing chain instead of failing' do
    stub_meta(active_meta)
    expect(kv_client).to receive(:read_multi).with([cert_key]).and_return(cert_key => cert_doc(leaf))
    expect(kv_client).to receive(:read_prefix).with('acme/web/certs/').and_raise(RuntimeError, "NOPERM this user has no permissions to run the 'scan' command")

    expect(described_class.lookup(**base_args, include_chain: true)).to include(
      pem: leaf.to_pem, chain: nil, fullchain: nil, chain_missing: true, chain_error: a_string_matching(%r{\ARuntimeError: NOPERM}),
    )
  end

  describe 'chain from the issuers recorded in acme_renewal (no search)' do
    it 'reads certificate and issuer metas together, then the issuer certificates' do
      stub_meta(active_meta('version' => 2, 'issuers' => [certid_of(intermediate)]))
      int_meta_key = "acme/web/certids/#{certid_of(intermediate)}"
      expect(kv_client).to receive(:read_multi).with([cert_key, int_meta_key]).and_return(
        cert_key => cert_doc(leaf), int_meta_key => { 'active_version' => 1, 'status' => 'active' },
      )
      expect(kv_client).to receive(:read_multi).with(["acme/web/certs/#{certid_of(intermediate)}/1"]).and_return(
        "acme/web/certs/#{certid_of(intermediate)}/1" => cert_doc(intermediate),
      )
      expect(kv_client).not_to receive(:read_prefix)

      result = described_class.lookup(**base_args, include_chain: true)

      expect(result).to include(pem: leaf.to_pem, chain: intermediate.to_pem, fullchain: leaf.to_pem + intermediate.to_pem,
                                chain_missing: false)
    end

    it 'leaves a self-signed root out of chain and fullchain' do
      stub_meta(active_meta('version' => 2, 'issuers' => [certid_of(intermediate), certid_of(root)]))
      metas = [intermediate, root].to_h { |ca| ["acme/web/certids/#{certid_of(ca)}", { 'active_version' => 1 }] }
      expect(kv_client).to receive(:read_multi).with([cert_key] + metas.keys).and_return(metas.merge(cert_key => cert_doc(leaf)))
      expect(kv_client).to receive(:read_multi).with([intermediate, root].map { |ca| "acme/web/certs/#{certid_of(ca)}/1" }).and_return(
        [intermediate, root].to_h { |ca| ["acme/web/certs/#{certid_of(ca)}/1", cert_doc(ca)] },
      )

      expect(described_class.lookup(**base_args, include_chain: true)[:chain]).to eq(intermediate.to_pem)
    end

    it 'searches the area instead when a recorded issuer entry is missing' do
      stub_meta(active_meta('version' => 2, 'issuers' => [certid_of(intermediate)]))
      int_meta_key = "acme/web/certids/#{certid_of(intermediate)}"
      expect(kv_client).to receive(:read_multi).with([cert_key, int_meta_key]).and_return(cert_key => cert_doc(leaf), int_meta_key => nil)
      expect(kv_client).to receive(:read_prefix).with('acme/web/certs/').and_return(
        'acme/web/certs/other/1' => cert_doc(intermediate),
      )

      expect(described_class.lookup(**base_args, include_chain: true)[:chain]).to eq(intermediate.to_pem)
    end
  end

  describe 'root certificate' do
    def stub_recorded_chain(cas)
      stub_meta(active_meta('version' => 2, 'issuers' => cas.map { |ca| certid_of(ca) }))
      metas = cas.to_h { |ca| ["acme/web/certids/#{certid_of(ca)}", { 'active_version' => 1 }] }
      expect(kv_client).to receive(:read_multi).with([cert_key] + metas.keys).and_return(metas.merge(cert_key => cert_doc(leaf)))
      expect(kv_client).to receive(:read_multi).with(cas.map { |ca| "acme/web/certs/#{certid_of(ca)}/1" }).and_return(
        cas.to_h { |ca| ["acme/web/certs/#{certid_of(ca)}/1", cert_doc(ca)] },
      )
    end

    it 'returns a recorded root separately, never inside chain' do
      stub_recorded_chain([intermediate, root])
      expect(kv_client).not_to receive(:read_prefix)

      expect(described_class.lookup(**base_args, include_chain: true)).to include(chain: intermediate.to_pem, root: root.to_pem)
    end

    it 'does not search for a root that was not recorded unless include_root is set' do
      stub_recorded_chain([intermediate])
      expect(kv_client).not_to receive(:read_prefix)

      expect(described_class.lookup(**base_args, include_chain: true)).to include(chain: intermediate.to_pem, root: nil)
    end

    it 'searches the area above the recorded chain with include_root (e.g. a root imported in CCI-UI)' do
      stub_recorded_chain([intermediate])
      expect(kv_client).to receive(:read_prefix).with('acme/web/certs/').and_return('acme/web/certs/r/1' => cert_doc(root))

      expect(described_class.lookup(**base_args, include_chain: true, include_root: true)).to include(chain: intermediate.to_pem, root: root.to_pem)
    end

    it 'returns no root when it is not stored, even with include_root' do
      stub_recorded_chain([intermediate])
      expect(kv_client).to receive(:read_prefix).and_return({})

      expect(described_class.lookup(**base_args, include_chain: true, include_root: true)).to include(chain: intermediate.to_pem, root: nil, chain_missing: false)
    end
  end

  describe 'chain by search (CCI-UI style), e.g. for certificates not issued by this module' do
    def expect_cert_read
      expect(kv_client).to receive(:read_multi).with([cert_key]).and_return(cert_key => cert_doc(leaf))
    end

    it 'finds the issuers by name, CA flag and signature among all certificates of the area' do
      stub_meta(active_meta)
      expect_cert_read
      unrelated = AcmeKvstoreSpecPki.chain[:intermediate]
      expect(kv_client).to receive(:read_prefix).with('acme/web/certs/').and_return(
        'acme/web/certs/a/1' => cert_doc(unrelated), 'acme/web/certs/b/1' => cert_doc(root),
        'acme/web/certs/c/1' => cert_doc(intermediate), 'acme/web/certs/shop-example-com/2' => cert_doc(leaf)
      )

      result = described_class.lookup(**base_args, include_chain: true)

      expect(result).to include(chain: intermediate.to_pem, fullchain: leaf.to_pem + intermediate.to_pem, chain_missing: false)
    end

    it 'searches when acme_renewal describes another version than the active one' do
      stub_meta(active_meta('version' => 1, 'issuers' => [certid_of(intermediate)]))
      expect_cert_read
      expect(kv_client).to receive(:read_prefix).with('acme/web/certs/').and_return('acme/web/certs/c/1' => cert_doc(intermediate))

      expect(described_class.lookup(**base_args, include_chain: true)[:chain]).to eq(intermediate.to_pem)
    end

    it 'skips documents that hold no readable certificate' do
      stub_meta(active_meta)
      expect_cert_read
      expect(kv_client).to receive(:read_prefix).and_return(
        'acme/web/certs/broken/1' => { 'pem' => 'not a certificate' }, 'acme/web/certs/other/1' => { 'note' => 'no pem' },
        'acme/web/certs/c/1' => cert_doc(intermediate)
      )

      expect(described_class.lookup(**base_args, include_chain: true)).to include(chain: intermediate.to_pem, chain_error: nil)
    end

    it 'rejects a certificate that only shares the issuer name (different key, or no CA)' do
      stub_meta(active_meta)
      expect_cert_read
      impostor = AcmeKvstoreSpecPki.cert(subject: '/O=Test/CN=Test R1', key: OpenSSL::PKey::RSA.new(1024), ca_flag: true)
      expect(kv_client).to receive(:read_prefix).and_return('acme/web/certs/x/1' => cert_doc(impostor))

      expect(described_class.lookup(**base_args, include_chain: true)).to include(chain: nil, fullchain: nil, chain_missing: true)
    end

    it 'reports a missing issuer and returns no chain' do
      stub_meta(active_meta)
      expect_cert_read
      expect(kv_client).to receive(:read_prefix).and_return({})

      expect(described_class.lookup(**base_args, include_chain: true)).to include(pem: leaf.to_pem, chain: nil, fullchain: nil, chain_missing: true)
    end
  end

  describe 'private key' do
    let(:plaintext_key) { "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n" }
    let(:secret) { 'S' * 32 }

    it 'decrypts it with the associated data of this area, certid and version' do
      stub_meta(active_meta)
      enc = PuppetX::AcmeKvstore::Crypto.encrypt(plaintext_key, secret, aad: 'cci:web:shop-example-com/2')
      expect(kv_client).to receive(:read_multi).with([cert_key, key_key]).and_return(cert_key => cert_doc(leaf, has_key: true), key_key => enc)

      expect(described_class.lookup(**base_args, decrypt_key: true, area_secret: secret)[:private_key]).to eq(plaintext_key)
    end

    it 'does not read the key document when decrypt_key is false' do
      stub_meta(active_meta)
      expect(kv_client).to receive(:read_multi).with([cert_key]).and_return(cert_key => cert_doc(leaf, has_key: true))

      expect(described_class.lookup(**base_args)).to include(has_key: true, private_key: nil)
    end

    it 'does not attempt to decrypt when has_key is false' do
      stub_meta(active_meta)
      expect(kv_client).to receive(:read_multi).with([cert_key, key_key]).and_return(cert_key => cert_doc(leaf), key_key => nil)

      expect(described_class.lookup(**base_args, decrypt_key: true, area_secret: secret)).to include(has_key: false, private_key: nil)
    end
  end
end
