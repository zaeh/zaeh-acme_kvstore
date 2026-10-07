# Redis backend

## Prerequisite

The Ruby gem `redis` must be installed wherever the module talks to Redis:

- on the ACME worker - automatically via
  `acme_kvstore::worker { manage_gems => true }` (the default);
- on every Puppet/OpenVox **server** that compiles catalogues with
  `acme_kvstore::deploy` or `acme_kvstore::lookup_cert`, since those read
  Redis while compiling. The server runs its own JRuby with its own gems,
  so install it there with `puppetserver gem install redis` (or the
  `puppetserver_gem` package provider of the `puppetlabs-puppetserver_gem`
  module) and restart the server;
- on nodes using `acme_kvstore_cert_data` with the Redis provider (e.g. a
  `package { 'redis': provider => puppet_gem }`).

The Consul backend needs no gem anywhere: it only uses Ruby's built-in
`Net::HTTP`.

## Connection configuration (`$acme_kvstore::redis`)

```puppet
redis => {
  'host'      => 'redis.example.com',
  'port'      => 6379,
  'db'        => 0,                             # optional
  'tls'       => true,                          # optional, recommended for a cluster reached over the network
  'ca_file'   => '/etc/ssl/certs/redis-ca.pem',      # optional, TLS verification
  'cert_file' => '/etc/ssl/certs/redis-client.pem',  # optional, for mTLS
  'key_file'  => '/etc/ssl/private/redis-client.key',# optional, for mTLS
  'insecure'  => false,                          # optional, disables TLS verification (do not use in production!)
}
```

There is deliberately no global `'username'`/`'password'` here (they are
rejected): with the Redis backend, every area authenticates as its own
Redis ACL user (Redis 6+), `redis_username` and `redis_password` in
`$acme_kvstore::areas`, limited to that area's keys below
`<prefix>/<area>/` (see [KV layout in Redis](#kv-layout-in-redis)).

The `RedisClient` (`lib/puppet_x/acme_kvstore/redis_client.rb`) uses:

- **Reads**: `MGET` for any number of keys in a single round trip.
- **Writes**: `MULTI`/`EXEC` for all documents from a renewal in a single
  atomic transaction.

## Compare-and-set (CAS)

Every write goes through `RedisClient#transactional_update`, which uses
Redis's native `WATCH`/`MULTI`/`EXEC` mechanism: the meta key is
`WATCH`ed, its current value is read and handed to the caller, and the
resulting writes are queued inside `MULTI`. If another client writes to
the watched key between `WATCH` and `EXEC`, Redis aborts the transaction
and `EXEC` returns `nil`, which is surfaced as a
`PuppetX::AcmeKvstore::RedisClient::CasConflictError`.

`WATCH` only notices changes made after it was set. Since the worker
decides on the basis of the meta document read at the start of the run,
the value read after `WATCH` is also compared with that earlier read; any
difference is a conflict as well, so nothing written in between is ever
overwritten.

Unlike the Consul implementation, this does add one extra round trip
compared to an unprotected write (`WATCH`, then a plain `GET` of the
watched key, then `MULTI`/`EXEC`) - the price paid here for genuine CAS
semantics on a backend whose native protocol does not expose a
version/index token the way Consul's `ModifyIndex` does.

> Note: a sharded Redis **Cluster** is not supported. The keys belonging
> to one certificate (meta, certificate, key) are written in
> one `MULTI`/`EXEC` and read with one `MGET`, which Redis Cluster only
> allows for keys in the same hash slot; this module does not use hash
> tags, so these commands would fail with a `CROSSSLOT` error. Use a
> single Redis node or a Sentinel-managed primary/replica setup.

## KV layout in Redis

```text
acme/web/certids/shop-example-com      -> meta JSON (string)
acme/web/certs/shop-example-com/1      -> certificate JSON (string)
acme/web/keys/shop-example-com/2       -> encrypted key JSON (string)
```

Can be checked with, for example, `redis-cli --tls GET acme/web/certids/shop-example-com`.

Since all keys of an area live below `<prefix>/<area>/`, a Redis ACL user
per area (that area's `redis_username`/`redis_password` in
`$acme_kvstore::areas`, required with the Redis backend) can be
restricted to its own keys. The commands
this module uses are `GET`, `MGET`, `SET`, `EXISTS`, `WATCH`, `UNWATCH`,
`MULTI` and `EXEC`:

```text
ACL SETUSER acme-web on >password ~acme/web/* +get +mget +set +exists +watch +unwatch +multi +exec
```

A consumer that only reads certificates needs just `~acme/web/* +get +mget`;
`acme_kvstore::deploy` uses such a user as the area's `redis_read_username`
and `redis_read_password` (required when it builds the connection from
Hiera):

```text
ACL SETUSER acme-web-read on >password ~acme/web/* +get +mget
```

Building a chain by **search** (see
[architecture.md](architecture.md#issuer-entries)) additionally needs
`+scan`: for certificates not issued by this module, or issued with
`store_issuers => false`, and only when a chain is requested at all
(`deploy` with `chain_path`/`fullchain_path`/`combined_path`,
`include_chain` elsewhere). Note that `SCAN` lists key *names* of the
whole database, not only the area's - grant it only where needed. Without
it, the search fails gracefully: `deploy` warns (naming the error) and
writes the certificate, key and DH files, but no chain.

## Read access from consumer systems

```puppet
acme_kvstore_cert_data { 'shop-example-com':
  provider       => 'redis',
  area           => 'web',
  backend_config => {
    'host' => 'redis.example.com',
    'tls'  => true,
    'prefix' => 'acme',
  },
}
```
