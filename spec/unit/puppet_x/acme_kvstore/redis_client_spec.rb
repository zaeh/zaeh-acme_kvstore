# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/redis_client'

# A minimal in-memory stand-in for the real Redis client, faithfully
# emulating just enough of WATCH/MULTI/EXEC semantics to exercise
# RedisClient#transactional_update without a real Redis server: EXEC
# aborts (returns nil) if a watched key's "version" changed since WATCH -
# exactly as real Redis does when another client wrote to it meanwhile.
class FakeRedisForSpec
  MultiProxy = Struct.new(:commands) do
    def set(key, value)
      commands << [key, value]
    end
  end

  def initialize
    @store = {}
    @versions = Hash.new(0)
    @watched = nil
  end

  def get(key)
    @store[key]
  end

  def mget(*keys)
    keys.map { |k| @store[k] }
  end

  def set(key, value)
    @store[key] = value
    @versions[key] += 1
  end

  # Like Redis, a WATCH inside the block adds keys to the watched set.
  def watch(*keys)
    @watched = (@watched || {}).merge(keys.to_h { |k| [k, @versions[k]] })
    return 'OK' unless block_given?

    yield
  end

  def exists?(key)
    @store.key?(key)
  end

  def scan_each(match:, count: nil) # rubocop:disable Lint/UnusedMethodArgument
    @store.keys.select { |key| File.fnmatch(match, key) }.each
  end

  def unwatch
    @watched = nil
  end

  def multi
    proxy = MultiProxy.new([])
    yield proxy

    conflict = @watched&.any? { |k, version| @versions[k] != version }
    @watched = nil
    return nil if conflict

    proxy.commands.each { |(k, v)| set(k, v) }
    proxy.commands.map { 'OK' }
  end

  # Test helper simulating a write performed by a *different* client,
  # independent of any WATCH currently held by the client under test.
  def simulate_concurrent_write(key, value)
    @store[key] = value
    @versions[key] += 1
  end
end

describe PuppetX::AcmeKvstore::RedisClient do
  let(:fake_redis) { FakeRedisForSpec.new }
  let(:client) do
    described_class.allocate.tap do |c|
      c.instance_variable_set(:@redis, fake_redis)
    end
  end

  describe '#initialize' do
    it 'authenticates as the configured ACL user, e.g. an area-scoped one' do
      expect(Redis).to receive(:new).with(hash_including(host: 'redis.example.com', username: 'acme-web', password: 'secret'))
      described_class.new('host' => 'redis.example.com', 'username' => 'acme-web', 'password' => 'secret')
    end

    it 'passes no username when none is configured' do
      expect(Redis).to receive(:new).with(hash_not_including(:username))
      described_class.new('host' => 'redis.example.com')
    end
  end

  describe '#write_atomic' do
    it 'writes several keys in a single MULTI/EXEC' do
      client.write_atomic('acme', 'web/certids/shop-example-com' => { 'status' => 'active' }, 'web/certs/shop-example-com/1' => { 'pem' => 'X' })

      expect(JSON.parse(fake_redis.get('acme/web/certids/shop-example-com'))).to eq('status' => 'active')
      expect(JSON.parse(fake_redis.get('acme/web/certs/shop-example-com/1'))).to eq('pem' => 'X')
    end
  end

  describe '#transactional_update' do
    it 'yields the current value and commits the returned writes when nothing else interferes' do
      fake_redis.set('acme/web/certids/shop-example-com', { 'latest_version' => 1 }.to_json)

      yielded = nil
      result = client.transactional_update('acme', 'web/certids/shop-example-com') do |current|
        yielded = current
        { 'web/certids/shop-example-com' => { 'latest_version' => 2 } }
      end

      expect(yielded).to eq('latest_version' => 1)
      expect(result).to be(true)
      expect(JSON.parse(fake_redis.get('acme/web/certids/shop-example-com'))).to eq('latest_version' => 2)
    end

    it 'performs no write and returns true when the block returns nil' do
      result = client.transactional_update('acme', 'web/certids/shop-example-com') { |_current| nil }
      expect(result).to be(true)
      expect(fake_redis.get('acme/web/certids/shop-example-com')).to be_nil
    end

    it 'raises CasConflictError when the watched key changes between WATCH and EXEC' do
      fake_redis.set('acme/web/certids/shop-example-com', { 'latest_version' => 1 }.to_json)

      expect do
        client.transactional_update('acme', 'web/certids/shop-example-com') do |_current|
          # Simulate a second worker completing a renewal for the same
          # certificate while we are still deciding what to write.
          fake_redis.simulate_concurrent_write('acme/web/certids/shop-example-com', { 'latest_version' => 2 }.to_json)
          { 'web/certids/shop-example-com' => { 'latest_version' => 2 } }
        end
      end.to raise_error(PuppetX::AcmeKvstore::RedisClient::CasConflictError)
    end

    it 'creates the other written keys only if they do not exist yet' do
      fake_redis.set('acme/web/certids/shop-example-com', { 'latest_version' => 4 }.to_json)
      fake_redis.set('acme/web/certs/shop-example-com/5', { 'pem' => 'OLD' }.to_json)

      expect do
        client.transactional_update('acme', 'web/certids/shop-example-com') do |_current|
          { 'web/certs/shop-example-com/5' => { 'pem' => 'NEW' }, 'web/certids/shop-example-com' => { 'latest_version' => 5 } }
        end
      end.to raise_error(PuppetX::AcmeKvstore::RedisClient::CasConflictError, %r{acme/web/certs/shop-example-com/5 already exist})
      expect(JSON.parse(fake_redis.get('acme/web/certs/shop-example-com/5'))).to eq('pem' => 'OLD')
      expect(JSON.parse(fake_redis.get('acme/web/certids/shop-example-com'))).to eq('latest_version' => 4)
    end

    it 'fails when another client creates such a key between the check and EXEC' do
      expect do
        client.transactional_update('acme', 'web/certids/shop-example-com') do |_current|
          fake_redis.simulate_concurrent_write('acme/web/certs/shop-example-com/1', { 'pem' => 'OTHER' }.to_json)
          { 'web/certs/shop-example-com/1' => { 'pem' => 'NEW' }, 'web/certids/shop-example-com' => { 'latest_version' => 1 } }
        end
      end.to raise_error(PuppetX::AcmeKvstore::RedisClient::CasConflictError)
    end

    context 'with the value from an earlier read (expected:)' do
      let(:meta) { { 'latest_version' => 1 } }

      before { fake_redis.set('acme/web/certids/shop-example-com', meta.to_json) }

      it 'writes when the key is unchanged since that read' do
        client.transactional_update('acme', 'web/certids/shop-example-com', expected: { value: meta, index: nil }) do |current|
          expect(current).to eq(meta)
          { 'web/certids/shop-example-com' => { 'latest_version' => 2 } }
        end

        expect(JSON.parse(fake_redis.get('acme/web/certids/shop-example-com'))).to eq('latest_version' => 2)
      end

      it 'raises CasConflictError when the key changed between that read and WATCH, without calling the block' do
        fake_redis.simulate_concurrent_write('acme/web/certids/shop-example-com', { 'latest_version' => 2 }.to_json)

        expect do
          client.transactional_update('acme', 'web/certids/shop-example-com', expected: { value: meta, index: nil }) do |_current|
            raise 'must not be called'
          end
        end.to raise_error(PuppetX::AcmeKvstore::RedisClient::CasConflictError, %r{changed since it was read})
      end
    end
  end

  describe '#read_multi_with_index' do
    it 'returns the values with a nil index (Redis uses WATCH instead)' do
      fake_redis.set('acme/web/certids/shop-example-com', { 'status' => 'active' }.to_json)

      expect(client.read_multi_with_index(['acme/web/certids/shop-example-com', 'acme/web/certids/missing'])).to eq(
        'acme/web/certids/shop-example-com' => { value: { 'status' => 'active' }, index: nil },
        'acme/web/certids/missing'          => { value: nil, index: nil },
      )
    end
  end

  describe '#read_prefix' do
    it 'returns every key below the prefix (SCAN), parsed' do
      fake_redis.set('acme/web/certs/a/1', { 'pem' => 'A' }.to_json)
      fake_redis.set('acme/web/certs/b/2', { 'pem' => 'B' }.to_json)
      fake_redis.set('acme/web/certids/a', { 'status' => 'active' }.to_json)

      expect(client.read_prefix('acme/web/certs/')).to eq(
        'acme/web/certs/a/1' => { 'pem' => 'A' }, 'acme/web/certs/b/2' => { 'pem' => 'B' },
      )
    end
  end
end
