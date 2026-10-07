# frozen_string_literal: true

require_relative 'acceptance_helper'

%i[consul redis].each do |backend|
  describe "KV client against a real #{backend}" do
    let(:kv_backend) { backend }
    let(:writer) { AcceptanceEnv.kv_client(kv_backend, 'web', 'write') }
    let(:reader) { AcceptanceEnv.kv_client(kv_backend, 'web', 'read') }
    let(:certid) { AcceptanceEnv.new_certid }

    def prefix = AcceptanceEnv::PREFIX
    def meta_suffix = "web/certids/#{certid}"
    def meta_key = "#{prefix}/#{meta_suffix}"

    def conflict
      (kv_backend == :consul) ? PuppetX::AcmeKvstore::ConsulClient::CasConflictError : PuppetX::AcmeKvstore::RedisClient::CasConflictError
    end

    def create_meta(client, version)
      client.transactional_update(prefix, meta_suffix) do |current|
        { meta_suffix => (current || {}).merge('latest_version' => version), "web/certs/#{certid}/#{version}" => { 'pem' => "v#{version}" } }
      end
    end

    it 'reads a missing key as nil' do
      expect(writer.read_multi([meta_key])).to eq(meta_key => nil)
    end

    it 'writes the meta document and a new version together, and reads them back' do
      create_meta(writer, 1)
      expect(writer.read_multi([meta_key, "#{prefix}/web/certs/#{certid}/1"]).values).to eq([{ 'latest_version' => 1 }, { 'pem' => 'v1' }])
    end

    it 'rejects a write based on a meta document that changed meanwhile (compare-and-set)' do
      create_meta(writer, 1)
      stale = writer.read_multi_with_index([meta_key])[meta_key]
      create_meta(AcceptanceEnv.kv_client(backend, 'web', 'write'), 2)

      expect { writer.transactional_update(prefix, meta_suffix, expected: stale) { { meta_suffix => { 'latest_version' => 9 } } } }
        .to raise_error(conflict)
      expect(writer.read_multi([meta_key])[meta_key]).to eq('latest_version' => 2)
    end

    it 'never overwrites an existing version' do
      create_meta(writer, 1)
      expect do
        writer.transactional_update(prefix, meta_suffix) { { meta_suffix => { 'latest_version' => 1 }, "web/certs/#{certid}/1" => { 'pem' => 'other' } } }
      end.to raise_error(conflict)
      expect(writer.read_multi(["#{prefix}/web/certs/#{certid}/1"]).values.first).to eq('pem' => 'v1')
    end

    it 'reads every key below a prefix' do
      create_meta(writer, 1)
      create_meta(writer, 2)
      reading = (backend == :redis) ? AcceptanceEnv.kv_client(backend, 'web', 'read_scan') : reader
      keys = reading.read_prefix("#{prefix}/web/certs/#{certid}/").keys
      expect(keys).to contain_exactly("#{prefix}/web/certs/#{certid}/1", "#{prefix}/web/certs/#{certid}/2")
    end

    describe 'least privilege' do
      it 'lets the read-only credentials read' do
        create_meta(writer, 1)
        expect(reader.read_multi([meta_key])[meta_key]).to eq('latest_version' => 1)
      end

      it 'refuses writes with the read-only credentials' do
        expect { create_meta(reader, 1) }.to raise_error(StandardError, %r{denied|NOPERM|403}i)
        expect(writer.read_multi([meta_key])[meta_key]).to be_nil
      end

      it "never shows or changes another area's keys" do
        other_suffix = "internal/certids/#{certid}"
        AcceptanceEnv.kv_client(backend, 'internal', 'write').transactional_update(prefix, other_suffix) { { other_suffix => { 'secret' => 'internal' } } }

        if backend == :consul
          # Consul hides keys a token may not read, as if they did not exist.
          expect(writer.read_multi(["#{prefix}/#{other_suffix}"])).to eq("#{prefix}/#{other_suffix}" => nil)
        else
          expect { writer.read_multi(["#{prefix}/#{other_suffix}"]) }.to raise_error(StandardError, %r{NOPERM}i)
        end
        expect { writer.transactional_update(prefix, other_suffix) { { other_suffix => { 'secret' => 'overwritten' } } } }
          .to raise_error(StandardError, %r{denied|NOPERM|403}i)
        internal = AcceptanceEnv.kv_client(backend, 'internal', 'read').read_multi(["#{prefix}/#{other_suffix}"]).values.first
        expect(internal).to eq('secret' => 'internal')
      end

      if backend == :redis
        it 'refuses SCAN to a read-only user without +scan' do
          expect { reader.read_prefix("#{prefix}/web/") }.to raise_error(StandardError, %r{NOPERM}i)
        end
      end
    end
  end
end
