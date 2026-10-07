# frozen_string_literal: true

require_relative '../../../puppet_x/acme_kvstore/cert_lookup'
require_relative '../../../puppet_x/acme_kvstore/consul_client'
require_relative '../../../puppet_x/acme_kvstore/redis_client'

# @summary Looks up a certificate (and optionally its decrypted private key) stored by acme_kvstore, at catalog-compile time.
#
# Reads directly from Consul/Redis while the catalogue is compiled, for
# delivering a certificate to any node (see docs/lookup_cert.md).
# Certificate and key data are only returned while the status is
# 'active'.
Puppet::Functions.create_function(:'acme_kvstore::lookup_cert') do
  # @param certid The certificate ID to look up.
  # @param area The area the certificate belongs to.
  # @param backend Which KV backend to query: 'consul' or 'redis'.
  # @param backend_config Backend connection details (Hash), including 'prefix' - see docs/consul.md / docs/redis.md.
  # @param area_secret The area's 32-byte secret. Required only when decrypt_key is true.
  # @param decrypt_key Whether to also decrypt and return the private key. Defaults to false.
  # @param include_chain Whether to build the chain (chain, fullchain, root) at all; it can cost a read of all certificates
  #   of the area. Defaults to false.
  # @param include_root With include_chain: whether to also search the area for the root if the recorded chain does not end in
  #   one. Defaults to false.
  # @return A Hash with the keys 'status', 'active_version', 'latest_version', 'updated_at', 'pem' (certificate only),
  #   with include_chain 'chain' (issuers without self-signed roots, built from the issuer entries), 'fullchain'
  #   (certificate + chain), 'chain_missing' (the certificate's issuer is not stored; chain/fullchain are then undef),
  #   'chain_error' (why the issuer search failed, if it did), 'root' (the self-signed root of the chain, if stored;
  #   never part of chain/fullchain),
  #   'has_key', 'private_key'.
  # @example Deliver an active certificate's PEM and key to a node's catalog
  #   $cert = acme_kvstore::lookup_cert('shop-example-com', 'web', 'consul',
  #     { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' }, $area_secret, true)
  #   if $cert['status'] == 'active' {
  #     file { '/etc/ssl/certs/shop.pem': content => $cert['pem'] }
  #     file { '/etc/ssl/private/shop.key': content => Sensitive($cert['private_key']), mode => '0600' }
  #   }
  dispatch :lookup_cert do
    param 'String[1]', :certid
    param 'String[1]', :area
    param 'Enum[consul, redis]', :backend
    param 'Hash', :backend_config
    optional_param 'Optional[String[1]]', :area_secret
    optional_param 'Boolean', :decrypt_key
    optional_param 'Boolean', :include_chain
    optional_param 'Boolean', :include_root
    return_type 'Hash'
  end

  def lookup_cert(certid, area, backend, backend_config, area_secret = nil, decrypt_key = false, include_chain = false,
                  include_root = false)
    prefix = backend_config['prefix'] || backend_config[:prefix]
    raise Puppet::ParseError, "acme_kvstore::lookup_cert: backend_config must include a 'prefix' key" if prefix.nil?

    raise Puppet::ParseError, 'acme_kvstore::lookup_cert: area_secret is required when decrypt_key is true' if decrypt_key && (area_secret.nil? || area_secret.empty?)

    kv_client = build_kv_client(backend, backend_config)

    result = PuppetX::AcmeKvstore::CertLookup.lookup(
      kv_client:,
      prefix:,
      area:,
      certid:,
      decrypt_key:,
      area_secret:,
      include_chain:,
      include_root:,
    )

    result.transform_keys(&:to_s)
  end

  private

  def build_kv_client(backend, backend_config)
    case backend
    when 'consul'
      PuppetX::AcmeKvstore::ConsulClient.new(backend_config)
    when 'redis'
      PuppetX::AcmeKvstore::RedisClient.new(backend_config)
    end
  end
end
