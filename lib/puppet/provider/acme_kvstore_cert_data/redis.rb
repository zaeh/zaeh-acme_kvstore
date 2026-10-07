# frozen_string_literal: true

require 'puppet_x/acme_kvstore/cert_data_provider_common'
require 'puppet_x/acme_kvstore/redis_client'

Puppet::Type.type(:acme_kvstore_cert_data).provide(:redis) do
  desc 'Reads certificate data from a Redis cluster.'

  include PuppetX::AcmeKvstore::CertDataProviderCommon

  def kv_client
    @kv_client ||= PuppetX::AcmeKvstore::RedisClient.new(resource[:backend_config])
  end
end
