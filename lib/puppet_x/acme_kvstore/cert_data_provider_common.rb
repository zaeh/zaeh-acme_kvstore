# frozen_string_literal: true

require 'puppet_x'
require 'puppet_x/acme_kvstore/cert_lookup'

module PuppetX::AcmeKvstore
  # acme_kvstore_cert_data providers: one CertLookup per resource, cached
  # for all properties.
  module CertDataProviderCommon
    PROPERTIES = %i[status active_version latest_version updated_at pem chain fullchain chain_missing chain_error root has_key
                    private_key].freeze

    PROPERTIES.each do |prop|
      define_method(prop) do
        load!
        @data[prop]
      end
    end

    def exists?
      load!
      !@data[:status].nil?
    end

    private

    def load!
      return if @loaded

      @loaded = true
      @data = PuppetX::AcmeKvstore::CertLookup.lookup(
        kv_client:,
        prefix: resource[:prefix] || resource[:backend_config]['prefix'],
        area: resource[:area],
        certid: resource[:certid],
        decrypt_key: resource[:decrypt_key].to_s == 'true',
        include_chain: resource[:include_chain].to_s == 'true',
        area_secret: resource[:area_secret],
      )
    end
  end
end
