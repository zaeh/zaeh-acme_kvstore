# `acme_kvstore::lookup_cert`

A compile-time function for delivering a certificate (and, optionally, its
decrypted private key) managed by `acme_kvstore` to a node **other than**
the ACME worker that issues and renews it. It is the compile-time
counterpart of the [`acme_kvstore_cert_data`](consul.md) type: use whichever
fits your architecture better.

| | `acme_kvstore::lookup_cert` | `acme_kvstore_cert_data` |
| --- | --- | --- |
| Runs on | The Puppet server (or wherever the catalogue is compiled) | The target/consumer node itself, during catalog application |
| Needs KV network access from | The compiler | The agent |
| Result becomes | Literal content embedded in the compiled catalogue | A resource property, read live by the provider |

Because `lookup_cert` (and `acme_kvstore::deploy`, which is built on it)
runs on the Puppet/OpenVox server, it runs under the server's **JRuby**
(OpenVox Server 8: JRuby 9.4, 9: JRuby 10), not MRI. The module's lookup
code is checked there with `bundle exec rake jruby:compat`. With the Redis
backend, the server needs the `redis` gem in its own JRuby - see
[redis.md](redis.md#prerequisite).

Neither is used by, or should be used on, the ACME worker itself, which
manages certificates exclusively through the `acme_kvstore_certificate`
type - see [architecture.md](architecture.md) for how the write and read
paths relate to one another.

## Usage

```puppet
$cert = acme_kvstore::lookup_cert(
  'shop-example-com',                                              # certid
  'web',                                                            # area
  'consul',                                                         # backend
  { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' }, # backend_config
  $area_secret,                                                     # area_secret (only needed if decrypting)
  true,                                                             # decrypt_key
)

if $cert['status'] == 'active' {
  file { '/etc/ssl/certs/shop.pem':
    ensure  => file,
    content => $cert['pem'],
  }

  file { '/etc/ssl/private/shop.key':
    ensure    => file,
    content   => Sensitive($cert['private_key']),
    mode      => '0600',
    show_diff => false,
  }
}
```

If the node compiling the catalogue has also included the `acme_kvstore`
class purely for its global configuration (no worker or certificates of
its own), the connection details can be reused instead of repeating them:

```puppet
include acme_kvstore

$cert = acme_kvstore::lookup_cert(
  'shop-example-com', 'web', $acme_kvstore::backend,
  $acme_kvstore::consul + { 'prefix' => $acme_kvstore::prefix },
  $area_secret, true
)
```

## Return value

A `Hash` with the keys `status`, `active_version`, `latest_version`,
`updated_at`, `pem` (the certificate only), `has_key`, `private_key`,
and - only with `include_chain` - `chain` (its issuers without
self-signed roots, built from the [issuer entries](architecture.md#issuer-entries)),
`fullchain` (certificate + chain), `chain_missing` (`true` if the
certificate's issuer is not stored in the area; `chain`/`fullchain` are
then `undef`), `chain_error` (why the search for the issuer failed, e.g.
a Redis user without `+scan`) and `root` (the self-signed root of the
chain if stored - never part of `chain`/`fullchain`). Only `status` (and the version/timestamp fields) are ever
populated for a certificate whose status is anything but `active`, or
for a `certid`/`area` combination that has never had a certificate issued
at all - all certificate/key fields stay `undef` in that case, **and the
certificate/key documents are not even read from the KV store**. See
[architecture.md](architecture.md#status-values) for what each status
means.

## Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `certid` | `String[1]` | The certificate ID to look up. |
| `area` | `String[1]` | The area the certificate belongs to. |
| `backend` | `Enum[consul, redis]` | Which KV backend to query. |
| `backend_config` | `Hash` | Backend connection details, including `'prefix'` - see [consul.md](consul.md) / [redis.md](redis.md). |
| `area_secret` | `Optional[String[1]]` | The area's 32-byte secret. Required only when `decrypt_key` is `true`. |
| `decrypt_key` | `Boolean` | Whether to also decrypt and return the private key. Defaults to `false`. |
| `include_chain` | `Boolean` | Whether to build `chain`, `fullchain` and `root` at all - this can cost a read of all certificates of the area (see [architecture.md](architecture.md#issuer-entries)). Defaults to `false`. |
| `include_root` | `Boolean` | With `include_chain`: whether to also search the area for the root when the recorded chain does not end in one (CAs rarely deliver it). Defaults to `false`. |

## Why a separate function instead of reusing the type?

Custom Puppet types are designed to run through the compile-apply cycle on
the node that ends up managing that resource - they are not generally
meant to be evaluated purely for their return value *during* compilation of
some other node's catalogue. A plain function is the idiomatic tool for
"fetch this value now, while building the catalogue" - which is exactly
what delivering a certificate to a consumer node's `file` resources
requires.

Concretely: there is no supported Puppet DSL syntax for wiring a custom
type's live property (as read by its provider at apply time) into another
resource's parameter within the same catalogue - a resource's attributes
are all fixed once compilation finishes. This is why
`acme_kvstore::deploy` below is built on this function rather than on
`acme_kvstore_cert_data`, even though the latter looks superficially more
convenient.

## `acme_kvstore::deploy`

A defined type wrapping the pattern above for the common case: write the
certificate and its key to disk with the right ownership/permissions, and
notify a service. By default only the certificate (`cert_path`) and, if
`key_path` is given, the key are written; every other output file is
opt-in via its own `*_path` parameter. Since it calls
`acme_kvstore::lookup_cert` internally, it inherits the same
"runs wherever this node's catalogue is compiled" behaviour: the
certificate is fetched on the compiler and written on the node the
catalogue is for, which may be any node.

`acme_kvstore::deploy` is independent of the `acme_kvstore` class, of
`acme_kvstore::worker` and of the certificates configured for the worker:
it declares none of them and needs none of their settings. Pass
`backend`, `backend_config`, `area` and (only if a key is written)
`area_secret` explicitly, or leave them undef to fall back to the
matching Hiera keys (`acme_kvstore::backend`, `acme_kvstore::consul` or
`acme_kvstore::redis` plus `acme_kvstore::prefix`,
`acme_kvstore::default_area`, `acme_kvstore::areas`).

When deploy builds the connection from Hiera, it authenticates with the
area's **read-only** credentials - `consul_read_token`, or
`redis_read_username` and `redis_read_password` in `acme_kvstore::areas` -
and fails if they are missing. It never uses the worker's read/write
credentials (`consul_token`, `redis_username`/`redis_password`); see
[configuration.md](configuration.md#areas).

```puppet
acme_kvstore::deploy { 'shop-example-com':
  cert_path       => '/etc/ssl/certs/shop.pem',
  key_path        => '/etc/ssl/private/shop.key',
  owner           => 'nginx',
  group           => 'nginx',
  notify_services => ['nginx'],
}
```

Most web servers want the certificate together with its chain; nginx for
example, plus DH parameters:

```puppet
acme_kvstore::deploy { 'shop-example-com':
  cert_path       => '/etc/nginx/tls/shop.crt',
  fullchain_path  => '/etc/nginx/tls/shop.fullchain.pem', # ssl_certificate
  key_path        => '/etc/nginx/tls/shop.key',           # ssl_certificate_key
  dh_path         => '/etc/nginx/tls/dhparams.pem',       # ssl_dhparam
  notify_services => ['nginx'],
}
```

HAProxy expects everything in a single file:

```puppet
acme_kvstore::deploy { 'shop-example-com':
  cert_path       => '/etc/haproxy/tls/shop.crt',
  combined_path   => '/etc/haproxy/tls/shop.pem', # certificate + chain + key
  notify_services => ['haproxy'],
}
```

The DH parameters are the fixed, well-known finite-field groups from
[RFC 7919](https://www.rfc-editor.org/rfc/rfc7919) (`ffdhe2048`,
`ffdhe3072`, `ffdhe4096`, shipped in `files/dhparams/`), as recommended by
e.g. Mozilla's server-side TLS guidelines, instead of generating random
parameters per host: they are at least as secure, need no expensive
generation on every node, and are identical (and therefore idempotent)
everywhere.

The certificate's status (see
[architecture.md](architecture.md#status-values)) decides what happens to
the files:

- `active`: they are written.
- `delete`: every configured path (`cert_path`, `key_path`, `chain_path`,
  `fullchain_path`, `combined_path`, `dh_path`) is removed
  (`ensure => absent`), notifying `notify_services`.
- `norollout`, a not-yet-issued certificate or any other value: no file is
  managed at all - not created, not emptied, not removed - so a paused
  certificate never causes a broken or missing file on the node.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `cert_path` | `Stdlib::Absolutepath` | **required** | Where to write the (leaf) certificate PEM. |
| `key_path` | `Optional[Stdlib::Absolutepath]` | `undef` | Where to write the decrypted private key. Leave `undef` to not write a key. |
| `chain_path` | `Optional[Stdlib::Absolutepath]` | `undef` | Where to write the issuer chain (without the certificate and self-signed roots). Skipped with a warning if the issuer is not stored. |
| `fullchain_path` | `Optional[Stdlib::Absolutepath]` | `undef` | Where to write the certificate followed by its issuer chain. Skipped with a warning if the issuer is not stored. |
| `combined_path` | `Optional[Stdlib::Absolutepath]` | `undef` | Where to write certificate + chain + key in one file (written with `key_mode`). If the issuer is not stored, only certificate + key, with a warning. |
| `combined_include_dh` | `Boolean` | `false` | Append the DH parameters to `combined_path`. |
| `chain_include_root` | `Boolean` | `false` | Append the self-signed root to `chain_path`, `fullchain_path` and the certificates of `combined_path` - for applications without a usable trust store (by design, in containers). The root must be stored in the area; CAs rarely deliver it, so import it (e.g. in [CCI-UI](cci-ui.md)); without it the files are written without root, with a warning. |
| `dh_path` | `Optional[Stdlib::Absolutepath]` | `undef` | Where to write DH parameters (RFC 7919 group of `dh_param_size` bits). |
| `dh_param_size` | `Optional[Acme_kvstore::Dh_param_size]` | `undef` (-> Hiera `acme_kvstore::dh_param_size`) | `2048`, `3072` or `4096`. |
| `certid` | `String[1]` | `$title` | The certificate ID to look up. |
| `area` | `Optional[String[1]]` | `undef` (-> Hiera `acme_kvstore::default_area`) | Area the certificate belongs to. |
| `area_secret` | `Optional[Variant[String[1], Sensitive[String[1]]]]` | `undef` (-> `secret` of the area in Hiera `acme_kvstore::areas`) | Only needed when a key is written (`key_path`, `combined_path`). |
| `backend` | `Optional[Enum['consul','redis']]` | `undef` (-> Hiera `acme_kvstore::backend`) | Which KV backend to query. |
| `backend_config` | `Optional[Hash]` | `undef` (-> Hiera `acme_kvstore::consul`/`redis` + `acme_kvstore::prefix` + the area's read-only credentials) | Backend connection details including `prefix` and credentials; used as given. |
| `owner` | `String[1]` | `'root'` | Owner for all files. |
| `group` | `String[1]` | `'root'` | Group for all files. |
| `cert_mode` | `Stdlib::Filemode` | `'0644'` | File mode for all files without a private key. |
| `key_mode` | `Stdlib::Filemode` | `'0600'` | File mode for `key_path` and `combined_path`. |
| `notify_services` | `Array[String[1]]` | `[]` | Names of `Service` resources to notify when any file changes. |
