# @summary Connection details for the Redis backend ($acme_kvstore::redis).
#
# Deliberately without 'username'/'password': every area authenticates as
# its own Redis ACL user (redis_username/redis_password, see
# Acme_kvstore::Area). The KV prefix is added from $acme_kvstore::prefix.
type Acme_kvstore::Redis_config = Struct[{
  Optional['host']      => Stdlib::Host,
  Optional['port']      => Stdlib::Port,
  Optional['db']        => Integer[0],
  Optional['tls']       => Boolean,
  Optional['ca_file']   => Stdlib::Absolutepath,
  Optional['cert_file'] => Stdlib::Absolutepath,
  Optional['key_file']  => Stdlib::Absolutepath,
  Optional['insecure']  => Boolean,
}]
