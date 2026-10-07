# @summary Connection details for the Consul backend ($acme_kvstore::consul).
#
# Deliberately without a 'token': every area uses its own consul_token
# (see Acme_kvstore::Area), so a token with access to all areas cannot be
# configured here. The KV prefix is added from $acme_kvstore::prefix.
type Acme_kvstore::Consul_config = Struct[{
  Optional['url']          => Stdlib::HTTPUrl,
  Optional['datacenter']   => String[1],
  Optional['ca_file']      => Stdlib::Absolutepath,
  Optional['cert_file']    => Stdlib::Absolutepath,
  Optional['key_file']     => Stdlib::Absolutepath,
  Optional['insecure']     => Boolean,
  Optional['read_timeout'] => Integer[1],
}]
