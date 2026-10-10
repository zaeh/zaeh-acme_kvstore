# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/mock_cert'

describe PuppetX::AcmeKvstore::MockCert do
  let(:pki) { described_class.pki }
  let(:root) { OpenSSL::X509::Certificate.new(pki[:root_pem]) }
  let(:intermediate) { OpenSSL::X509::Certificate.new(pki[:intermediate_pem]) }

  def leaf(certid) = OpenSSL::X509::Certificate.new(described_class.leaf_pem(certid))

  def san(cert) = cert.extensions.find { |ext| ext.oid == 'subjectAltName' }&.value

  it 'returns the same certificate on every call, also after the cache is cleared' do
    first = described_class.leaf_pem('shop.example.com')
    described_class.instance_variable_set(:@cache, {})
    expect(described_class.leaf_pem('shop.example.com')).to eq(first)
  end

  it 'gives every certid its own certificate' do
    expect(described_class.leaf_pem('a.example.com')).not_to eq(described_class.leaf_pem('b.example.com'))
    expect(leaf('a.example.com').serial).not_to eq(leaf('b.example.com').serial)
  end

  it 'chains to the mock root, with the fixed leaf key' do
    store = OpenSSL::X509::Store.new
    store.add_cert(root)
    cert = leaf('shop.example.com')
    expect(store.verify(cert, [intermediate])).to be(true)
    expect(cert.check_private_key(OpenSSL::PKey.read(pki[:leaf_key_pem]))).to be(true)
  end

  it 'keeps root and intermediate valid far beyond the next 15 years' do
    [root, intermediate, leaf('shop.example.com')].each do |cert|
      expect(cert.not_after).to be > Time.utc(2099, 1, 1)
      expect(cert.not_before).to eq(Time.utc(2026, 1, 1))
    end
  end

  it 'names the leaf after the certid, with a SAN for a host name' do
    cert = leaf('shop.example.com')
    expect(cert.subject.to_a.assoc('CN')[1]).to eq('shop.example.com')
    expect(san(cert)).to eq('DNS:shop.example.com')
  end

  it 'leaves out the SAN for a certid that is no host name and cuts the CN to 64 characters' do
    expect(san(leaf('shop_example_com'))).to be_nil
    expect(leaf('x' * 100).subject.to_a.assoc('CN')[1]).to eq('x' * 64)
  end

  it "returns CertLookup's keys, filled as asked" do
    full = described_class.lookup(certid: 'shop.example.com', decrypt_key: true, include_chain: true, include_root: true)
    expect(full).to include(status: 'active', active_version: 1, has_key: true, chain: pki[:intermediate_pem], root: pki[:root_pem],
                            chain_missing: false, private_key: pki[:leaf_key_pem])
    expect(full[:fullchain]).to eq(full[:pem] + pki[:intermediate_pem])

    bare = described_class.lookup(certid: 'shop.example.com')
    expect(bare).to include(status: 'active', chain: nil, fullchain: nil, root: nil, private_key: nil)
    expect(bare.keys).to match_array(full.keys)
  end
end
