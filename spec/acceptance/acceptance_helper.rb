# frozen_string_literal: true

# Acceptance tests against real Consul, Redis and acme.sh (talking to Pebble),
# started by spec/acceptance/compose.yml - run them with
# `bundle exec rake acceptance`. Every credential is generated per run or a
# throwaway test value; nothing here is a real secret.
require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'openssl'
require 'securerandom'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'puppet'
require 'puppet_x/acme_kvstore/consul_client'
require 'puppet_x/acme_kvstore/redis_client'
require 'puppet_x/acme_kvstore/cert_lookup'
require 'puppet_x/acme_kvstore/crypto'
require 'puppet_x/acme_kvstore/kv_document'

# The services and per-run credentials shared by all acceptance specs.
module AcceptanceEnv
  COMPOSE = File.expand_path('compose.yml', __dir__)
  PREFIX = 'acceptance'
  CONSUL_URL = 'http://127.0.0.1:18500'
  CONSUL_MANAGEMENT_TOKEN = 'acceptance-test-management-token' # see compose.yml
  REDIS_HOST = '127.0.0.1'
  REDIS_PORT = 16_379
  ACME_DIRECTORY = 'https://localhost:14000/dir'
  PEBBLE_MANAGEMENT = 'https://localhost:15000'
  ACMESH_VERSION = '3.0.9'
  ACMESH_SHA256 = 'a599e8373cd327fb611362bec6f1bfb0bf65c97b3401c440cfea9304a0f0cb41'
  AREAS = %w[web internal].freeze

  module_function

  def workdir
    @workdir ||= Dir.mktmpdir('acme_kvstore_acceptance')
  end

  def area_secret
    @area_secret ||= Base64.strict_encode64(OpenSSL::Random.random_bytes(32))
  end

  # Pebble's TLS CA; acme.sh reads CA_BUNDLE (verified in the 3.0.9 source:
  # curl --cacert / wget --ca-certificate) and inherits the environment.
  def pebble_ca
    @pebble_ca ||= begin
      path = File.join(workdir, 'pebble.minica.pem')
      run!('docker', 'compose', '-f', COMPOSE, 'cp', 'pebble:/test/certs/pebble.minica.pem', path)
      ENV['CA_BUNDLE'] = path
      path
    end
  end

  def pebble_root_pem
    https_get("#{PEBBLE_MANAGEMENT}/roots/0")
  end

  # acme.sh from its release tarball, verified by SHA-256.
  def acmesh_path
    @acmesh_path ||= begin
      tarball = File.join(workdir, "acme.sh-#{ACMESH_VERSION}.tar.gz")
      File.binwrite(tarball, http_get("https://github.com/acmesh-official/acme.sh/archive/refs/tags/#{ACMESH_VERSION}.tar.gz"))
      raise 'acme.sh tarball checksum mismatch' unless Digest::SHA256.file(tarball).hexdigest == ACMESH_SHA256

      run!('tar', 'xzf', tarball, '-C', workdir)
      File.join(workdir, "acme.sh-#{ACMESH_VERSION}", 'acme.sh')
    end
  end

  # Consul: per area a read/write token for the worker and a read-only one,
  # each limited to <prefix>/<area>/.
  def consul_tokens
    @consul_tokens ||= AREAS.to_h do |area|
      tokens = %w[write read].to_h do |access|
        policy = consul_put('/v1/acl/policy', 'Name' => "#{PREFIX}-#{area}-#{access}",
                                              'Rules' => %(key_prefix "#{PREFIX}/#{area}/" { policy = "#{access}" }))
        token = consul_put('/v1/acl/token', 'Policies' => [{ 'ID' => policy.fetch('ID') }])
        [access, token.fetch('SecretID')]
      end
      [area, tokens]
    end
  end

  def consul_config(token)
    { 'url' => CONSUL_URL, 'token' => token, 'prefix' => PREFIX }
  end

  # Redis: per area a worker user, a read-only user, and a read-only user with
  # +scan; the default user is switched off afterwards.
  def redis_users
    @redis_users ||= begin
      admin = { 'username' => 'acceptance-admin', 'password' => SecureRandom.hex(16) }
      redis_command(nil, 'ACL', 'SETUSER', admin['username'], 'on', ">#{admin['password']}", '~*', '+@all')
      users = AREAS.to_h do |area|
        rights = {
          'write' => %w[+get +mget +set +exists +watch +unwatch +multi +exec],
          'read' => %w[+get +mget],
          'read_scan' => %w[+get +mget +scan],
        }
        [area, rights.to_h do |access, commands|
          user = { 'username' => "#{area}-#{access}", 'password' => SecureRandom.hex(16) }
          redis_command(admin, 'ACL', 'SETUSER', user['username'], 'on', ">#{user['password']}", "~#{PREFIX}/#{area}/*", *commands)
          [access, user]
        end,]
      end
      redis_command(admin, 'ACL', 'SETUSER', 'default', 'off')
      users
    end
  end

  def redis_config(user)
    { 'host' => REDIS_HOST, 'port' => REDIS_PORT, 'prefix' => PREFIX }.merge(user)
  end

  def backend_config(backend, area, access)
    (backend == :consul) ? consul_config(consul_tokens.fetch(area).fetch(access)) : redis_config(redis_users.fetch(area).fetch(access))
  end

  def kv_client(backend, area, access)
    config = backend_config(backend, area, access)
    (backend == :consul) ? PuppetX::AcmeKvstore::ConsulClient.new(config) : PuppetX::AcmeKvstore::RedisClient.new(config)
  end

  # An acme_kvstore_certificate provider with real KV clients and acme.sh.
  def certificate_provider(backend, certid, **params)
    home = File.join(workdir, 'home')
    webroot = File.join(workdir, 'webroot')
    FileUtils.mkdir_p([home, webroot])
    Puppet::Type.type(:acme_kvstore_certificate).new(
      {
        name: certid, area: 'web', domains: ["#{certid}.example.test"], provider: backend,
        backend_config: backend_config(backend, 'web', 'write'), area_secret:,
        server: ACME_DIRECTORY, acmesh_path:, run_as_home: home, webroot:,
        key_type: 'ec', key_size: 256, client_id: 'puppet', updated_by: 'acceptance',
        # Pebble's default profile issues 6-day certificates.
        renew_before_days: 1,
      }.merge(params),
    ).provider
  end

  def new_certid
    "cert-#{SecureRandom.hex(4)}"
  end

  # A certificate issued once per backend and variant, shared by read-only specs.
  def issued(backend, variant = :default, **params)
    @issued ||= {}
    @issued[[backend, variant]] ||= new_certid.tap { |certid| certificate_provider(backend, certid, **params).create }
  end

  def setup!
    pebble_ca
    acmesh_path
    consul_tokens
    redis_users
  end

  def consul_put(path, body)
    uri = URI("#{CONSUL_URL}#{path}")
    request = Net::HTTP::Put.new(uri, 'X-Consul-Token' => CONSUL_MANAGEMENT_TOKEN, 'Content-Type' => 'application/json')
    request.body = body.to_json
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    raise "Consul #{path}: HTTP #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def redis_command(user, *command)
    options = { host: REDIS_HOST, port: REDIS_PORT }
    options.merge!(username: user['username'], password: user['password']) if user
    redis = ::Redis.new(options)
    redis.call(*command)
  ensure
    redis&.close
  end

  def http_get(url, redirects = 5)
    response = Net::HTTP.get_response(URI(url))
    return http_get(response['location'], redirects - 1) if response.is_a?(Net::HTTPRedirection) && redirects.positive?
    raise "GET #{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  def https_get(url)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, ca_file: pebble_ca) { |http| http.get(uri.request_uri).body }
  end

  def run!(*command)
    output, status = Open3.capture2e(*command)
    raise "#{command.first} failed: #{output}" unless status.success?

    output
  end
end

RSpec.configure do |config|
  config.before(:suite) { AcceptanceEnv.setup! }
  config.after(:suite) { FileUtils.rm_rf(AcceptanceEnv.workdir) }
end
