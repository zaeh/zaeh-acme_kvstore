# frozen_string_literal: true

require 'puppet_x/acme_kvstore/cert_data_provider_common'
require 'puppet_x/acme_kvstore/consul_client'

Puppet::Type.type(:acme_kvstore_cert_data).provide(:consul) do
  desc 'Reads certificate data from a Consul KV store.'

  include PuppetX::AcmeKvstore::CertDataProviderCommon

  def kv_client
    @kv_client ||= PuppetX::AcmeKvstore::ConsulClient.new(resource[:backend_config])
  end
end
