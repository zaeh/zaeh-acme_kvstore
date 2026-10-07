# Consul backend

## Connection configuration (`$acme_kvstore::consul`)

```puppet
consul => {
  'url'          => 'https://consul.example.com:8501', # required (https recommended)
  'datacenter'   => 'dc1',                              # optional
  'ca_file'      => '/etc/ssl/certs/consul-ca.pem',      # optional, for TLS verification
  'cert_file'    => '/etc/ssl/certs/consul-client.pem',  # optional, for mTLS
  'key_file'     => '/etc/ssl/private/consul-client.key',# optional, for mTLS
  'insecure'     => false,                               # optional, disables TLS verification (do not use in production!)
  'read_timeout' => 10,                                  # optional, seconds
}
```

There is deliberately no global `'token'` here (it is rejected): every
area has its own ACL token, `consul_token` in `$acme_kvstore::areas`,
limited to that area's keys below `<prefix>/<area>/` (see
[Required ACL policy](#required-acl-policy-example)). With the Consul
backend, every area must have one.

The `ConsulClient` (`lib/puppet_x/acme_kvstore/consul_client.rb`) uses
exclusively the **Transaction API** (`PUT /v1/txn`):

- **Reads**: several keys are queried as `"Verb": "get-or-empty"`
  operations within a single transaction -> one HTTP request regardless of
  the number of keys (Consul allows up to 64 operations per transaction).
  A missing key (e.g. before the first issuance, or an optional key
  document) simply comes back empty; plain `"get"` would roll back the
  whole transaction instead.
- **Writes**: all documents from a renewal (meta + certificate + optional
  key) are written in **one** atomic, compare-and-set
  protected transaction - either every change is applied, or none is.

## Compare-and-set (CAS)

Every write goes through `ConsulClient#transactional_update`, which reads
the certificate's meta document (`<prefix>/<area>/certids/<certid>`)
together with its current `ModifyIndex` and makes that index the
condition of the write transaction:

- When the meta document is written itself (issuance, renewal,
  `ensure => absent`), with Consul's `"cas"` verb and that index (`0` if
  the key does not exist yet, i.e. "only create it").
- When it is not (a write that leaves the meta document unchanged), with a
  `"check-index"` operation (`"check-not-exists"` for index `0`) in the
  same transaction.

If another client has written to the meta document in the meantime,
Consul rolls the whole transaction back with HTTP 409, which is surfaced
as a `PuppetX::AcmeKvstore::ConsulClient::CasConflictError`. The
certificate and key documents (which are always new, immutable
versions) are written in the same atomic transaction, so a CAS conflict
aborts the whole write - no orphaned certificate/key versions are left
behind.

This adds no extra network round trip compared to a plain, unprotected
write: the worker reads the meta document (with its `ModifyIndex`) once
at the start of the run anyway, and every write of that run uses exactly
that index - there is no second read. A renewal therefore costs one read
and one write transaction; a run with nothing to do, one read transaction
(see [architecture.md](architecture.md#kv-operations-per-run)).

## Required ACL policy (example)

All keys of an area live below `<prefix>/<area>/`, so tokens can be
scoped per area. The ACME worker needs write access to the areas it
manages, e.g. for the `web` area (used as that area's `consul_token`):

```hcl
key_prefix "acme/web/" {
  policy = "write"
}
```

A consumer that only fetches certificates of that area needs just
`policy = "read"` on the same prefix: `acme_kvstore::deploy` uses such a
token as the area's `consul_read_token` (required when it builds the
connection from Hiera), `lookup_cert`/`acme_kvstore_cert_data` get it in
their `backend_config`. Consul's `read` also covers the recursive read of
`<prefix>/<area>/certs/` used to find the issuers of certificates not
issued by this module (see
[architecture.md](architecture.md#issuer-entries)).

## KV layout in Consul

```text
acme/web/certids/shop-example-com      -> meta JSON
acme/web/certs/shop-example-com/1      -> certificate JSON (version 1)
acme/web/certs/shop-example-com/2      -> certificate JSON (version 2)
acme/web/keys/shop-example-com/2       -> encrypted key JSON (version 2)
acme/web/certids/r11_2027-03-12        -> issuer entry (an intermediate), certid = <cn>_<expiry date>
acme/web/certs/r11_2027-03-12/1        -> its certificate JSON
```

This can be inspected with, for example:

```sh
consul kv get -recurse acme/web/
consul kv get acme/web/certs/shop-example-com/2
```

## Read access from consumer systems

```puppet
acme_kvstore_cert_data { 'shop-example-com':
  provider       => 'consul',
  area           => 'web',
  backend_config => {
    'url' => 'https://consul.example.com:8501',
    'prefix' => 'acme',
  },
}
```

Without `decrypt_key => true` (default `false`), the private key is never
read from the KV store in the first place.
