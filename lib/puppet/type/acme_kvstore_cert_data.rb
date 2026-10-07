# frozen_string_literal: true

require 'puppet_x/acme_kvstore/read_only_property'

Puppet::Type.newtype(:acme_kvstore_cert_data) do
  @doc = <<-EOT
    A purely read-only type for querying a certificate stored by
    acme_kvstore (and optionally its decrypted private key) from a Consul
    or Redis KV store on the target system.

    This type never modifies data in the KV store; all properties are
    read-only (insync? always returns true, so there is never a 'change'
    event). It is useful, for example, for custom functions/facts that need
    to process certificate data from the KV store without the module
    itself being responsible for that (see docs/consul.md and docs/redis.md).

    The pem/has_key/private_key properties are only populated when the
    certificate's status is "active"; for any other status they stay
    undef, and the certificate/key documents are not even read from the KV
    store. See docs/lookup_cert.md for the compile-time equivalent of this
    type (acme_kvstore::lookup_cert), intended for use on the Puppet server.

    @example Read an active certificate and its key on the consumer node
      acme_kvstore_cert_data { 'shop-example-com':
        provider       => 'consul',
        area           => 'web',
        backend_config => { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' },
        decrypt_key    => true,
        area_secret    => $area_secret,
      }
  EOT

  newparam(:certid, namevar: true) do
    desc 'Certificate ID, as assigned when the certificate was created with acme_kvstore_certificate.'
  end

  newparam(:area) do
    desc 'Logical area of the certificate.'
  end

  newparam(:prefix) do
    desc 'Overrides the global KV prefix for this query.'
  end

  newparam(:backend_config) do
    desc 'Fully resolved backend connection details (Hash), including "prefix".'
    validate do |value|
      raise ArgumentError, 'backend_config must be a Hash' unless value.is_a?(Hash)
    end
  end

  newparam(:area_secret) do
    desc 'Area secret, only required when decrypt_key => true.'
  end

  newparam(:decrypt_key, boolean: true) do
    desc 'Whether the private key should be decrypted and exposed via the private_key property.'
    newvalues(:true, :false)
    defaultto :false
    # newvalues stores :true/:false symbols; munge to real booleans.
    munge { |value| [:true, true].include?(value) }
  end

  newparam(:include_chain, boolean: true) do
    desc 'Whether to build the chain, fullchain and root properties; it can cost a read of all certificates of the area.'
    newvalues(:true, :false)
    defaultto :false
    munge { |value| [:true, true].include?(value) }
  end

  newproperty(:status) do
    desc "One of 'active', 'norollout' or 'delete'."
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:active_version) do
    desc 'Currently active version number.'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:latest_version) do
    desc 'Most recently written version number.'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:updated_at) do
    desc 'Timestamp of the last change (ISO 8601).'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:pem) do
    desc 'PEM-encoded certificate (without chain).'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:chain) do
    desc 'PEM-encoded issuer chain without self-signed roots, built from the issuer entries (undef if the issuer is not stored).'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:fullchain) do
    desc 'PEM-encoded certificate + chain (undef if the issuer is not stored).'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:root) do
    desc 'PEM-encoded self-signed root of the chain, if it is among the issuers found (never part of chain/fullchain).'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:chain_error) do
    desc 'Why the search for the issuer failed, if it did (e.g. a Redis user without +scan).'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:chain_missing) do
    desc "Whether the certificate's issuer is not stored in the area."
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:has_key) do
    desc 'Whether a private key is stored.'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
  newproperty(:private_key) do
    desc 'Decrypted private key (only when decrypt_key => true).'
    include PuppetX::AcmeKvstore::ReadOnlyProperty
  end
end
