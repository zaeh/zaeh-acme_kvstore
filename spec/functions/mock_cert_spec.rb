# frozen_string_literal: true

require 'spec_helper'

describe 'acme_kvstore::mock_cert' do
  it 'returns a string-keyed Hash like lookup_cert, without any KV access' do
    expect(PuppetX::AcmeKvstore::ConsulClient).not_to receive(:new) if defined?(PuppetX::AcmeKvstore::ConsulClient)
    result = subject.execute('shop.example.com', true, true)
    expect(result).to include('status' => 'active', 'has_key' => true, 'chain_missing' => false)
    expect(result['private_key']).to include('PRIVATE KEY')
    expect(result['fullchain']).to eq(result['pem'] + result['chain'])
  end

  it 'returns neither key nor chain unless asked' do
    expect(subject.execute('shop.example.com')).to include('status' => 'active', 'private_key' => nil, 'chain' => nil, 'root' => nil)
  end
end
