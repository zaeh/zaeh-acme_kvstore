# frozen_string_literal: true

require_relative '../../../puppet_x/acme_kvstore/provider_common'
require_relative '../../../puppet_x/acme_kvstore/consul_client'

Puppet::Type.type(:acme_kvstore_certificate).provide(:consul) do
  desc <<-EOT
    Stores ACME certificates and keys in a Consul KV store (via /v1/txn, with compare-and-set
    protection, TLS/mTLS supported).
  EOT

  # The default backend; without one, Puppet warns about two equally
  # suitable providers on every run (acme_kvstore::certificate sets it).
  defaultfor kernel: :linux

  include PuppetX::AcmeKvstore::ProviderCommon

  def kv_client
    @kv_client ||= PuppetX::AcmeKvstore::ConsulClient.new(resource[:backend_config])
  end
end
