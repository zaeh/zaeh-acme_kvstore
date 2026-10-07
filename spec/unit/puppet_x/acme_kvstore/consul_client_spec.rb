# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/consul_client'

describe PuppetX::AcmeKvstore::ConsulClient do
  let(:client) { described_class.new('url' => 'https://consul.example.com:8501') }
  let(:http_double) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:use_ssl?).and_return(true)
    allow(http_double).to receive(:read_timeout=)
    allow(http_double).to receive(:ca_file=)
    allow(http_double).to receive(:verify_mode=)
  end

  def response_double(code, body)
    instance_double(Net::HTTPResponse, code: code.to_s, body:)
  end

  describe '#read_multi_with_index' do
    it 'issues a single transaction request and returns value + ModifyIndex per key' do
      body = {
        'Results' => [
          {
            'KV' => {
              'Key' => 'acme/web/certids/shop-example-com',
              'Value' => Base64.strict_encode64({ 'status' => 'active' }.to_json),
              'ModifyIndex' => 42,
            },
          },
        ],
      }.to_json
      expect(http_double).to receive(:request).once do |req|
        expect(JSON.parse(req.body)).to eq([{ 'KV' => { 'Verb' => 'get-or-empty', 'Key' => 'acme/web/certids/shop-example-com' } }])
        response_double(200, body)
      end

      result = client.read_multi_with_index(['acme/web/certids/shop-example-com'])

      expect(result['acme/web/certids/shop-example-com'][:value]).to eq('status' => 'active')
      expect(result['acme/web/certids/shop-example-com'][:index]).to eq(42)
    end

    # What Consul's "get-or-empty" returns for a missing key (see
    # agent/consul/state/txn.go): the key with a null Value and ModifyIndex 0.
    it 'returns index 0 and a nil value for a key that does not exist, alongside existing ones' do
      body = {
        'Results' => [
          { 'KV' => { 'Key' => 'acme/web/certs/shop-example-com/1', 'Value' => Base64.strict_encode64({ 'pem' => 'X' }.to_json), 'ModifyIndex' => 5 } },
          { 'KV' => { 'Key' => 'acme/web/keys/shop-example-com/1', 'Value' => nil, 'ModifyIndex' => 0 } },
        ],
      }.to_json
      allow(http_double).to receive(:request).and_return(response_double(200, body))

      result = client.read_multi_with_index(['acme/web/certs/shop-example-com/1', 'acme/web/keys/shop-example-com/1'])

      expect(result['acme/web/certs/shop-example-com/1']).to eq(value: { 'pem' => 'X' }, index: 5)
      expect(result['acme/web/keys/shop-example-com/1']).to eq(value: nil, index: 0)
    end
  end

  describe '#write_atomic' do
    it 'sends a plain "set" verb when no cas index is given' do
      allow(http_double).to receive(:request) do |req|
        ops = JSON.parse(req.body)
        expect(ops.first['KV']['Verb']).to eq('set')
        expect(ops.first['KV']).not_to have_key('Index')
        response_double(200, '{}')
      end

      client.write_atomic('acme', { 'web/certids/shop-example-com' => { 'status' => 'active' } })
    end

    it 'sends a "cas" verb with the given index when cas is specified' do
      allow(http_double).to receive(:request) do |req|
        ops = JSON.parse(req.body)
        expect(ops.first['KV']['Verb']).to eq('cas')
        expect(ops.first['KV']['Index']).to eq(7)
        response_double(200, '{}')
      end

      client.write_atomic('acme', { 'web/certids/shop-example-com' => { 'status' => 'active' } }, cas: { 'web/certids/shop-example-com' => 7 })
    end

    it 'raises CasConflictError on an HTTP 409 response' do
      allow(http_double).to receive(:request).and_return(response_double(409, '{"Errors":["cas mismatch"]}'))

      expect do
        client.write_atomic('acme', { 'web/certids/shop-example-com' => { 'status' => 'active' } }, cas: { 'web/certids/shop-example-com' => 7 })
      end.to raise_error(PuppetX::AcmeKvstore::ConsulClient::CasConflictError)
    end

    it 'raises the generic Error class on other non-2xx responses' do
      allow(http_double).to receive(:request).and_return(response_double(500, 'boom'))

      expect do
        client.write_atomic('acme', { 'web/certids/shop-example-com' => { 'status' => 'active' } })
      end.to raise_error(PuppetX::AcmeKvstore::ConsulClient::Error)
    end
  end

  describe '#transactional_update' do
    it 'creates every other written key (an immutable version) only if it does not exist yet, as CCI-UI does' do
      requests = []
      allow(http_double).to receive(:request) do |req|
        requests << JSON.parse(req.body)
        response_double(200, '{}')
      end

      client.transactional_update('acme', 'web/certids/shop-example-com', expected: { value: { 'latest_version' => 4 }, index: 99 }) do
        { 'web/certs/shop-example-com/5' => { 'pem' => 'P' }, 'web/certids/shop-example-com' => { 'latest_version' => 5 } }
      end

      ops = requests.last.to_h { |op| [op['KV']['Key'], op['KV'].slice('Verb', 'Index')] }
      expect(ops).to eq(
        'acme/web/certs/shop-example-com/5' => { 'Verb' => 'cas', 'Index' => 0 },
        'acme/web/certids/shop-example-com' => { 'Verb' => 'cas', 'Index' => 99 },
      )
    end

    it 'reads the watched key, yields its value, and writes using its ModifyIndex as the cas condition' do
      read_body = {
        'Results' => [
          {
            'KV' => {
              'Key' => 'acme/web/certids/shop-example-com',
              'Value' => Base64.strict_encode64({ 'latest_version' => 4 }.to_json),
              'ModifyIndex' => 99,
            },
          },
        ],
      }.to_json

      call_count = 0
      allow(http_double).to receive(:request) do |req|
        call_count += 1
        if call_count == 1
          response_double(200, read_body)
        else
          ops = JSON.parse(req.body)
          expect(ops.first['KV']['Verb']).to eq('cas')
          expect(ops.first['KV']['Index']).to eq(99)
          response_double(200, '{}')
        end
      end

      yielded = nil
      client.transactional_update('acme', 'web/certids/shop-example-com') do |current|
        yielded = current
        { 'web/certids/shop-example-com' => { 'latest_version' => 5 } }
      end

      expect(yielded).to eq('latest_version' => 4)
      expect(call_count).to eq(2)
    end

    it 'uses cas with index 0 (key must not exist yet) for the first issuance' do
      missing = { 'Results' => [{ 'KV' => { 'Key' => 'acme/web/certids/new-cert', 'Value' => nil, 'ModifyIndex' => 0 } }] }.to_json
      requests = []
      allow(http_double).to receive(:request) do |req|
        requests << JSON.parse(req.body)
        response_double(200, (requests.size == 1) ? missing : '{}')
      end

      client.transactional_update('acme', 'web/certids/new-cert') do |current|
        expect(current).to be_nil
        { 'web/certs/new-cert/1' => { 'pem' => 'X' }, 'web/certids/new-cert' => { 'latest_version' => 1 } }
      end

      meta_op = requests.last.find { |op| op['KV']['Key'] == 'acme/web/certids/new-cert' }['KV']
      expect(meta_op).to include('Verb' => 'cas', 'Index' => 0)
    end

    it 'guards writes that leave the watched key untouched with check-index' do
      read_body = { 'Results' => [{ 'KV' => { 'Key' => 'acme/web/certids/shop-example-com', 'Value' => Base64.strict_encode64({ 'active_version' => 3 }.to_json), 'ModifyIndex' => 99 } }] }.to_json
      requests = []
      allow(http_double).to receive(:request) do |req|
        requests << JSON.parse(req.body)
        response_double(200, (requests.size == 1) ? read_body : '{}')
      end

      client.transactional_update('acme', 'web/certids/shop-example-com') { |_current| { 'web/keys/shop-example-com/3' => { 'data' => 'X' } } }

      expect(requests.last).to eq(
        [
          { 'KV' => { 'Verb' => 'check-index', 'Key' => 'acme/web/certids/shop-example-com', 'Index' => 99 } },
          { 'KV' => { 'Verb' => 'cas', 'Key' => 'acme/web/keys/shop-example-com/3', 'Value' => Base64.strict_encode64({ 'data' => 'X' }.to_json), 'Index' => 0 } },
        ],
      )
    end

    it 'raises CasConflictError when such a check fails (HTTP 409, transaction rolled back)' do
      read_body = { 'Results' => [{ 'KV' => { 'Key' => 'acme/web/certids/shop-example-com', 'Value' => Base64.strict_encode64({}.to_json), 'ModifyIndex' => 99 } }] }.to_json
      responses = [response_double(200, read_body), response_double(409, '{"Errors":[{"OpIndex":0,"What":"index mismatch"}]}')]
      allow(http_double).to receive(:request) { responses.shift }

      expect do
        client.transactional_update('acme', 'web/certids/shop-example-com') { |_current| { 'web/keys/shop-example-com/3' => { 'data' => 'X' } } }
      end.to raise_error(PuppetX::AcmeKvstore::ConsulClient::CasConflictError)
    end

    it 'uses the index from an earlier read (expected:) without reading again' do
      requests = []
      allow(http_double).to receive(:request) do |req|
        requests << JSON.parse(req.body)
        response_double(200, '{}')
      end

      client.transactional_update('acme', 'web/certids/shop-example-com', expected: { value: { 'latest_version' => 4 }, index: 55 }) do |current|
        expect(current).to eq('latest_version' => 4)
        { 'web/certids/shop-example-com' => { 'latest_version' => 5 } }
      end

      expect(requests.size).to eq(1)
      expect(requests.first.first['KV']).to include('Verb' => 'cas', 'Index' => 55)
    end

    it 'performs no write when the block returns nil' do
      expect(http_double).to receive(:request).once.and_return(response_double(200, { 'Results' => [] }.to_json))

      result = client.transactional_update('acme', 'web/certids/shop-example-com') { |_current| nil }

      expect(result).to be(true)
    end
  end

  describe '#read_prefix' do
    it 'reads every key below the prefix with one recursive GET' do
      expect(http_double).to receive(:request) do |req|
        expect(req).to be_a(Net::HTTP::Get)
        expect(req.path).to eq('/v1/kv/acme/web/certs/?recurse=true')
        response_double(200, [{ 'Key' => 'acme/web/certs/a/1', 'Value' => Base64.strict_encode64({ 'pem' => 'P' }.to_json) }].to_json)
      end

      expect(client.read_prefix('acme/web/certs/')).to eq('acme/web/certs/a/1' => { 'pem' => 'P' })
    end

    it 'returns an empty hash when nothing is stored below the prefix (HTTP 404)' do
      expect(http_double).to receive(:request).and_return(response_double(404, ''))
      expect(client.read_prefix('acme/web/certs/')).to eq({})
    end
  end
end
