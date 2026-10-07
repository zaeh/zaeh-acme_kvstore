# @summary One entry of $acme_kvstore::areas.
#
# Each area has its own 32-byte AES secret (raw, hex or base64) and its own
# KV credentials, limited to the area's keys below <prefix>/<area>/:
# - for the ACME worker (read/write): consul_token with Consul,
#   redis_username/redis_password with Redis (required by the acme_kvstore
#   class for the backend in use);
# - for acme_kvstore::deploy (read only): consul_read_token, or
#   redis_read_username/redis_read_password (required by deploy when it
#   builds the connection from Hiera).
type Acme_kvstore::Area = Struct[{
  secret                          => Acme_kvstore::Secret,
  Optional['consul_token']        => Acme_kvstore::Secret,
  Optional['redis_username']      => String[1],
  Optional['redis_password']      => Acme_kvstore::Secret,
  Optional['consul_read_token']   => Acme_kvstore::Secret,
  Optional['redis_read_username'] => String[1],
  Optional['redis_read_password'] => Acme_kvstore::Secret,
}]
