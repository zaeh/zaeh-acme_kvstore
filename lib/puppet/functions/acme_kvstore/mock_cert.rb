# frozen_string_literal: true

require_relative '../../../puppet_x/acme_kvstore/mock_cert'

# @summary Returns a fake certificate in the shape of acme_kvstore::lookup_cert, for tests (acme_kvstore::deploy's mock mode).
#
# No KV store is read. The leaf certificate (CN and, for a host name, SAN =
# certid) is signed by the fixed mock PKI in files/mock and is the same on
# every call; root and intermediate are valid until the end of 2099. The
# private key is publicly known: never use the result in production.
Puppet::Functions.create_function(:'acme_kvstore::mock_cert') do
  # @param certid The certificate ID, used as the CN of the leaf.
  # @param decrypt_key Whether to return the (fake) private key.
  # @param include_chain Whether to return chain and fullchain.
  # @param include_root With include_chain: whether to return the mock root.
  # @return A Hash with the same keys as acme_kvstore::lookup_cert; status is always 'active'.
  # @example
  #   $cert = acme_kvstore::mock_cert('shop-example-com', true, true)
  dispatch :mock_cert do
    param 'String[1]', :certid
    optional_param 'Boolean', :decrypt_key
    optional_param 'Boolean', :include_chain
    optional_param 'Boolean', :include_root
    return_type 'Hash'
  end

  def mock_cert(certid, decrypt_key = false, include_chain = false, include_root = false)
    PuppetX::AcmeKvstore::MockCert.lookup(certid:, decrypt_key:, include_chain:, include_root:).transform_keys(&:to_s)
  end
end
