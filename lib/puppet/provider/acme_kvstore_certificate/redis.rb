# frozen_string_literal: true

require_relative '../../../puppet_x/acme_kvstore/provider_common'
require_relative '../../../puppet_x/acme_kvstore/redis_client'

Puppet::Type.type(:acme_kvstore_certificate).provide(:redis) do
  desc <<-EOT
    Stores ACME certificates and keys in a Redis cluster (via WATCH/MULTI/EXEC, with compare-and-set
    protection, TLS/mTLS supported).
  EOT

  include PuppetX::AcmeKvstore::ProviderCommon

  def kv_client
    @kv_client ||= PuppetX::AcmeKvstore::RedisClient.new(resource[:backend_config])
  end
end
