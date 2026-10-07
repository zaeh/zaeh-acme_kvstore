# frozen_string_literal: true

require 'puppet_x'

module PuppetX::AcmeKvstore
  # Makes an acme_kvstore_cert_data property read-only (never enforced).
  module ReadOnlyProperty
    def insync?(_is)
      true
    end

    def retrieve
      provider.send(name)
    end
  end
end
