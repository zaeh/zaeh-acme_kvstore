# Configuration reference

## Compatibility

This module supports both **Puppet 8** / **OpenVox 8** (bundles Ruby 3.2)
and **Puppet 9** (bundles Ruby 4.0, released August 2026). The Ruby code under `lib/` has
been reviewed against the documented Puppet Core 9 / Ruby 4.0 changes
(removal of `Kernel#open`/`IO.open`-style implicit-command execution, the
legacy `Hash#inspect` formatting change, `Net::HTTP` no longer setting a
default `Content-Type` on requests with a body) and does not rely on any of
the removed or changed behaviour. `.rubocop.yml` pins `TargetRubyVersion`
to `3.2` - the floor of what the code must run on - so that linting does
not suggest Ruby-4-only syntax that would break the Puppet 8 lane.

The unit tests run on OpenVox 8 by default. Setting
`OPENVOX_GEM_VERSION='~> 9.0'` under Ruby 4.0 runs them on OpenVox 9
instead; the full suite passes there as well, and CI tests both.

## Hiera

Every parameter of the `acme_kvstore` and `acme_kvstore::worker` classes
can be set in Hiera via automatic parameter lookup. The module's own
defaults live in its module data ([`data/common.yaml`](../data/common.yaml)),
the lowest-priority Hiera layer, so any value in your environment or
global Hiera data overrides them. The only defaults that stay in the
manifests are those that are `undef` and `acme_kvstore::worker`'s `home`
(which depends on `user`).

```yaml
# e.g. data/common.yaml of your control repository
acme_kvstore::backend: 'consul'
acme_kvstore::default_worker: 'acme-worker1.example.com'
acme_kvstore::default_area: 'web'
acme_kvstore::dnssleep: 120
acme_kvstore::areas:
  web:
    secret: >
      ENC[PKCS7,...]
acme_kvstore::dns_profiles:
  cloudflare:
    hook: 'dns_cf'
    env:
      CF_Token: >
        ENC[PKCS7,...]
acme_kvstore::default_dns_profile: 'cloudflare'
acme_kvstore::worker::user: 'acme'
acme_kvstore::worker::group: 'acme'
acme_kvstore::worker::manage_user: true
```

The hash parameters `workers`, `areas`, `consul`, `redis`, `dns_profiles`,
`dnsapi_scripts`, `ca_profiles` and `certificates` are **deep-merged** across all Hiera levels (the module
sets `lookup_options` for them in its own data). So, for example, the
Consul URL can be set in `common.yaml` and the ACL token per environment,
and each level can add areas or DNS/CA profiles. Your own CA profiles are
added to the module's default `letsencrypt`/`letsencrypt_test` profiles
rather than replacing them; which CA profiles can actually be used is
still decided by `ca_whitelist`. To change the merge behaviour of a key,
set `lookup_options` for it in your own Hiera data, which takes precedence
over the module's.

### Certificates in Hiera

The certificates themselves are defined entirely in Hiera, as the
`acme_kvstore::certificates` hash: each key is the `certid`, each value
the parameters of `acme_kvstore::certificate`. The class declares one
`acme_kvstore::certificate` per entry, so `include acme_kvstore` is all the
Puppet code needed:

```yaml
acme_kvstore::certificates:
  shop-example-com:
    domain: 'shop.example.com'
    subject_alt_names:
      - 'www.shop.example.com'
  wildcard-example-com:
    domain: '*.example.com'
    subject_alt_names:
      - 'example.com'
    use_dns_profile: 'cloudflare'
    renew_before_days: 21
```

Each entry is an `Acme_kvstore::Certificate_params`: only `domain` is
required, and every field is optional otherwise and defaults exactly as
the parameter of the same name of `acme_kvstore::certificate` (see the
table [below](#defined-type-acme_kvstorecertificate)). Unknown fields or
invalid values fail at compile time.

| Field | Type |
| --- | --- |
| `domain` | `Acme_kvstore::Domain` (FQDN or `*.example.com`) - **required** |
| `subject_alt_names` | `Array[Acme_kvstore::Domain]` |
| `area` | `Acme_kvstore::Area_name` |
| `worker` | `Stdlib::Fqdn` |
| `backend` | `Enum['consul', 'redis']` |
| `key_type`, `key_size` | `Enum['rsa', 'ec']`, `Integer[256]` |
| `renew_before_days`, `purge_key_on_mismatch`, `store_issuers` | `Integer[1]`, `Boolean`, `Boolean` |
| `tags` | `Array[String[1]]` |
| `challenge_type` | `Enum['http-01', 'dns-01']` |
| `use_dns_profile`, `use_ca_profile` | `String[1]` |
| `dns_provider`, `dns_env` | acme.sh hook name (`dns_...`), `Hash[String[1], String[1]]` |
| `challenge_alias`, `domain_alias` | `Stdlib::Fqdn` |
| `dnssleep`, `exec_timeout` | `Integer[1]` |
| `posthook_cmd`, `proxy`, `renew_schedule` | `String[1]` |

The same hash can be given to every node: each certificate only takes
effect on its responsible worker (`worker`, else `default_worker`). Since
the hash is deep-merged, certificates can be spread across Hiera levels
(e.g. per team or per environment).

`acme_kvstore::deploy` is independent of all this: it does not declare the
`acme_kvstore` class and is not driven by `acme_kvstore::certificates`.
It is called by your own code on the nodes that need the files, takes
everything it needs as parameters, and only falls back to the Hiera keys
`acme_kvstore::backend`, `::consul`/`::redis`, `::prefix`,
`::default_area`, `::areas` and `::dh_param_size` for parameters left
undef (see [lookup_cert.md](lookup_cert.md#acme_kvstoredeploy)).

## Ordering requirement

Always declare or `include` the `acme_kvstore` class before the first
`acme_kvstore::certificate` resource in your catalogue (directly, or by
relying on some other manifest that already does). Several of that defined
type's parameters (`renew_schedule`, `use_ca_profile`, `renew_before_days`,
`purge_key_on_mismatch`, `store_issuers`, `posthook_cmd`,
`proxy`, `exec_timeout`) default to `$acme_kvstore::*`
class parameters, which are only resolvable once the class has actually
been evaluated.

## Class `acme_kvstore`

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `prefix` | `String[1]` | `'acme'` | Global KV path prefix. |
| `backend` | `Enum['consul','redis']` | `'consul'` | Default backend. |
| `default_worker` | `Optional[String[1]]` | `undef` | FQDN of the default ACME worker host. |
| `workers` | `Hash[Stdlib::Fqdn, Hash]` | `{}` | Informational hash of known workers. |
| `areas` | `Hash[Acme_kvstore::Area_name, Acme_kvstore::Area]` | **required** | Area name => secret and the area's own Consul/Redis credentials (worker and read-only), see below. |
| `default_area` | `Optional[Acme_kvstore::Area_name]` | `undef` | Area used when `acme_kvstore::certificate` does not specify one. |
| `consul` | `Acme_kvstore::Consul_config` | `{}` | Consul connection details (no token), see [consul.md](consul.md). |
| `redis` | `Acme_kvstore::Redis_config` | `{}` | Redis connection details (no username/password), see [redis.md](redis.md). |
| `renew_schedule` | `Optional[String[1]]` | `undef` (-> any time) | Default name of a Puppet `schedule` resource (built-in or your own) whose `range`/`weekday` limit when due renewals run; first issuance and configuration changes are never delayed. See [architecture.md](architecture.md#flow-per-puppet-run-on-the-worker). |
| `dns_profiles` | `Hash[String[1], Acme_kvstore::Dns_profile]` | `{}` | Predefined DNS-01 challenge configurations, see [profiles.md](profiles.md). |
| `dnsapi_scripts` | `Hash[Pattern[/\Adns_[a-z0-9_]+\z/], Acme_kvstore::Dnsapi_script]` | `{}` | Custom acme.sh DNS API scripts by hook name, installed on the workers and used by DNS profiles via `hook`, see [profiles.md](profiles.md#custom-dns-api-scripts). |
| `default_dns_profile` | `Optional[String[1]]` | `undef` | DNS profile used when a certificate requests DNS-01 without naming one. |
| `ca_profiles` | `Hash[String[1], Acme_kvstore::Ca_profile]` | `letsencrypt` + `letsencrypt_test` | Predefined ACME CA configurations, see [profiles.md](profiles.md). |
| `default_ca_profile` | `String[1]` | `'letsencrypt'` | CA profile used when a certificate does not specify one. |
| `ca_whitelist` | `Array[String[1]]` | `['letsencrypt', 'letsencrypt_test']` | CA profile names certificates are actually allowed to request. |
| `posthook_cmd` | `Optional[String[1]]` | `undef` | Default command run on the worker after a successful issue/renew. See [profiles.md](profiles.md#posthook_cmd). |
| `proxy` | `Optional[String[1]]` | `undef` | Default HTTP(S) proxy for acme.sh's outbound connections. See [profiles.md](profiles.md#proxy). |
| `exec_timeout` | `Integer[1]` | `300` | Default maximum time in seconds any single acme.sh invocation may run. Must be higher than `dnssleep`. See [profiles.md](profiles.md#exec_timeout). |
| `renew_before_days` | `Integer[1]` | `30` | Default renewal window: renew when fewer days than this remain until expiry. |
| `purge_key_on_mismatch` | `Boolean` | `true` | Default for whether a changed `key_type`/`key_size` forces an immediate reissue. See [profiles.md](profiles.md#configuration-drift). |
| `store_issuers` | `Boolean` | `true` | Default for whether the chain certificates acme.sh returns are stored as [issuer entries](architecture.md#issuer-entries). |
| `dnssleep` | `Integer[1]` | `60` | Default seconds acme.sh waits for DNS-01 TXT records instead of polling public DNS itself. See [profiles.md](profiles.md#dnssleep). |
| `dh_param_size` | `Acme_kvstore::Dh_param_size` (`2048`, `3072`, `4096`) | `2048` | Default size of the DH parameters written by `acme_kvstore::deploy` (read from Hiera by `deploy`). |
| `kv_client` | `Pattern[/\A[a-zA-Z0-9_.-]{1,120}\z/]` | `'puppet'` | Value of the `client` field in the KV documents (see [architecture.md](architecture.md#kv-data-formats)); names referring to `acme` are rejected, as by [CCI-UI](cci-ui.md). |
| `kv_updated_by` | `Optional[String[1, 255]]` | `undef` (-> FQDN of the writing worker) | Value of the `updated_by`/`created_by` fields in the KV documents. |
| `certificates` | `Hash[Acme_kvstore::Certid, Acme_kvstore::Certificate_params]` | `{}` | Certificates to manage: `certid` => `acme_kvstore::certificate` parameters. See [Certificates in Hiera](#certificates-in-hiera). |

### Data types

The structured parameters use the module's own type aliases (in
[`types/`](../types)), so a typo in a key or a wrong value fails with a
clear message at compile time:

| Type | Used for | Content |
| --- | --- | --- |
| `Acme_kvstore::Area` | `areas` values | `secret`, `consul_token`, `redis_username`, `redis_password`, `consul_read_token`, `redis_read_username`, `redis_read_password` |
| `Acme_kvstore::Consul_config` | `consul` | `url`, `datacenter`, `ca_file`, `cert_file`, `key_file`, `insecure`, `read_timeout` |
| `Acme_kvstore::Redis_config` | `redis` | `host`, `port`, `db`, `tls`, `ca_file`, `cert_file`, `key_file`, `insecure` |
| `Acme_kvstore::Dns_profile` | `dns_profiles` values | `hook` (full acme.sh name, `dns_...`), `env`, `options`, `challenge_alias`, `domain_alias` |
| `Acme_kvstore::Dnsapi_script` | `dnsapi_scripts` values | exactly one of `source` (`Stdlib::Filesource`) or `content` |
| `Acme_kvstore::Ca_profile` | `ca_profiles` values | `directory_url` (https), `account_email`, `eab_kid`, `eab_hmac_key` |
| `Acme_kvstore::Certificate_params` | `certificates` values | the parameters of `acme_kvstore::certificate` (see [Certificates in Hiera](#certificates-in-hiera)) |
| `Acme_kvstore::Domain` | `domain`, `subject_alt_names` | FQDN or wildcard (`*.example.com`) |
| `Acme_kvstore::Certid` | `certificates` keys, `certid` | 1-120 letters, digits, `.`, `_`, `-` (as in CCI-UI) |
| `Acme_kvstore::Area_name` | `areas` keys, `area`, `default_area` | `[a-z][a-z0-9_]{0,47}` (as in CCI-UI) |
| `Acme_kvstore::Secret` | every secret | `String[1]` or `Sensitive[String[1]]` |
| `Acme_kvstore::Dh_param_size` | `dh_param_size` | `2048`, `3072` or `4096` |

### `areas`

```puppet
Hash[String[1], Acme_kvstore::Area]

type Acme_kvstore::Area = Struct[{
  secret                          => Acme_kvstore::Secret,
  # worker (read/write), required for the backend in use
  Optional['consul_token']        => Acme_kvstore::Secret,
  Optional['redis_username']      => String[1],
  Optional['redis_password']      => Acme_kvstore::Secret,
  # acme_kvstore::deploy (read only), required when deploy builds the connection from Hiera
  Optional['consul_read_token']   => Acme_kvstore::Secret,
  Optional['redis_read_username'] => String[1],
  Optional['redis_read_password'] => Acme_kvstore::Secret,
}]
```

```yaml
acme_kvstore::areas:
  web:
    secret: ENC[PKCS7,...]
    consul_token: ENC[PKCS7,...]       # ACME worker: write on acme/web/
    consul_read_token: ENC[PKCS7,...]  # acme_kvstore::deploy: read on acme/web/
```

Each area has its own 32-byte AES secret (base64, hex or raw) and
its own Consul ACL token and/or Redis ACL user
(`redis_username` + `redis_password`) - so a single
Consul/Redis cluster can be shared between areas whose ACL tokens are
scoped down to that area's own KV prefix: every key of an area lives
below `<prefix>/<area>/` (e.g. Consul `key_prefix "acme/web/"`, see
[consul.md](consul.md) and [redis.md](redis.md)). A per-area
`consul_token` is required with the Consul backend (`$consul` has no
`'token'` key at all), so Consul is always accessed with the area's own
token. Likewise, `redis_username` and `redis_password` are required with
the Redis backend (`$redis` has no `'username'`/`'password'` keys), so
Redis is always accessed as the area's own ACL user. These are the
**worker's** credentials (`acme_kvstore::certificate`, read/write).

`acme_kvstore::deploy` only reads, and uses separate **read-only**
credentials: `consul_read_token`, or `redis_read_username` and
`redis_read_password`. They are required when deploy builds the
connection from Hiera; deploy never falls back to the worker's
credentials. (A `backend_config` passed to deploy explicitly is used as
given.) Secrets may be given
as plain strings (e.g. already protected via Hiera-eyaml) or wrapped in
`Sensitive[String]` for redaction in Puppet's own logs and reports - both
are unwrapped internally before use. See [security.md](security.md).

### `dns_profiles` / `ca_profiles`

See [profiles.md](profiles.md) for the full structure, examples and how
`default_dns_profile`/`default_ca_profile`/`ca_whitelist` interact with
them.

## Class `acme_kvstore::worker`

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `install_method` | `Enum['git','archive','package']` | `'git'` | How acme.sh is installed: cloned from Git, from a tarball (`archive`), or as an OS package. |
| `acme_version` | `String[1]` | `'3.0.9'` | acme.sh version: the Git tag (or branch/commit) for `git`, the version in the default archive URL for `archive`. Pinned, so acme.sh is only updated deliberately; a changed version is installed on the next run. |
| `acme_git_url` | `String[1]` | the official GitHub repo | Git URL to clone acme.sh from. Override to use an internal mirror. |
| `acme_git_force` | `Boolean` | `false` | Force-recreate the cloned repository. Useful after changing `acme_git_url`. |
| `acme_archive_url` | `Optional[Stdlib::HTTPUrl]` | `undef` (GitHub archive of `acme_version`) | Tarball for `archive`, e.g. on an internal mirror. Unpacked into `/opt/acme.sh-<acme_version>`, whatever its top directory. |
| `acme_archive_sha256` | `Pattern[/\A\h{64}\z/]` | SHA-256 of the GitHub archive of 3.0.9 | Checksum of the tarball; Puppet discards a download that does not match. Change it together with `acme_version`/`acme_archive_url`. |
| `acme_package_ensure` | `String[1]` | `'installed'` | `ensure` of the `acme.sh` package for `package`, e.g. a fixed version such as `'3.0.9-1'`. |
| `manage_packages` | `Boolean` | `true` | Installs the `git` package needed by `install_method => 'git'`. |
| `manage_gems` | `Boolean` | `false` | Installs the `redis` gem, which the worker needs for the Redis backend only. |
| `manage_user` | `Boolean` | `false` | Whether to create the `user`/`group` accounts (`false` to reuse an existing account). |
| `manage_home` | `Boolean` | `true` | Whether to manage `home` (owned by `user`) and, with `manage_user`, the user's home directory. With `false`, `home` must exist and belong to `user`. |
| `user` | `String[1]` | `'root'` | Run acme.sh as this user. See [security.md](security.md#dedicated-worker-user). |
| `group` | `String[1]` | `'root'` | Group for `user` and for ownership of `home`/`webroot`. |
| `home` | `Stdlib::Absolutepath` | `/root/.acme.sh`, or `/home/<user>/.acme.sh` once `user` is non-root | acme.sh's `--home`. |
| `webroot` | `Stdlib::Absolutepath` | `/var/www/acme-challenge` | Webroot for HTTP-01 (acme.sh `--webroot`), unless a DNS profile/hook is used. |
| `acme_log_file` | `Variant[Stdlib::Absolutepath, Boolean[false]]` | `/var/log/acme.sh/acme.log` | acme.sh log file (acme.sh `--log`), writable by `user`. `false` disables it. Not rotated by this module. |
| `acme_log_level` | `Integer[1, 2]` | `1` | acme.sh `--log-level`: `1` (normal) or `2` (debug). |
| `manage_log_dir` | `Boolean` | `true` | Manage the directory of `acme_log_file` (owned by `user`). Set to `false` for a shared directory such as `/var/log`. |
| `config_dir` | `Stdlib::Absolutepath` | `/etc/acme_kvstore` | Directory for generated acme.sh files, e.g. nsupdate TSIG keys (see [profiles.md](profiles.md#nsupdate-bind-tsig-keys)). |

## Defined type `acme_kvstore::certificate`

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `domain` | `Acme_kvstore::Domain` | **required** | Primary domain (CN); a wildcard needs DNS-01. A change forces a reissue. |
| `subject_alt_names` | `Array[Acme_kvstore::Domain]` | `[]` | Further names on the certificate. A change forces a reissue (order does not matter). |
| `area` | `Optional[Acme_kvstore::Area_name]` | `undef` (-> `$default_area`) | Must be a key in `$acme_kvstore::areas`. |
| `certid` | `String[1]` | `$title` | Manually chosen, stable certificate ID. |
| `worker` | `Optional[String[1]]` | `undef` (-> `$default_worker`) | FQDN of the responsible worker host. |
| `backend` | `Optional[Enum['consul','redis']]` | `undef` (-> `$acme_kvstore::backend`) | Backend for this certificate. |
| `key_type` | `Enum['rsa','ec']` | `'rsa'` | Key algorithm. |
| `key_size` | `Integer[256]` | `2048` | RSA bit length, or EC curve (`256`/`384`). |
| `renew_before_days` | `Integer[1]` | `$acme_kvstore::renew_before_days` | Renewal window. |
| `purge_key_on_mismatch` | `Boolean` | `$acme_kvstore::purge_key_on_mismatch` | Whether a changed `key_type`/`key_size` forces an immediate reissue. |
| `store_issuers` | `Boolean` | `$acme_kvstore::store_issuers` | Whether the chain certificates acme.sh returns are stored as issuer entries; with `false`, readers search the area for them. |
| `tags` | `Array[String[1]]` | `[]` | Free-form tags. |
| `challenge_type` | `Optional[Enum['http-01','dns-01']]` | `undef` (auto-detected) | See [profiles.md](profiles.md#challenge_type). |
| `use_dns_profile` | `Optional[String[1]]` | `undef` (-> `$default_dns_profile`) | Name of a `$dns_profiles` entry. |
| `dns_provider` | `Optional[String[1]]` | `undef` | Low-level manual override: an acme.sh DNS hook name, bypassing any profile. |
| `dns_env` | `Hash[String[1], String[1]]` | `{}` | Low-level manual override for DNS API credentials. |
| `challenge_alias` | `Optional[String[1]]` | `undef` | DNS alias mode override, see [profiles.md](profiles.md#dns-alias-mode). |
| `domain_alias` | `Optional[String[1]]` | `undef` | DNS alias mode override, see [profiles.md](profiles.md#dns-alias-mode). |
| `dnssleep` | `Optional[Integer[1]]` | `undef` (-> profile's `options['dnssleep']`, then `$acme_kvstore::dnssleep`) | DNS-01 propagation wait, see [profiles.md](profiles.md#dnssleep). |
| `use_ca_profile` | `String[1]` | `$acme_kvstore::default_ca_profile` | Name of a `$ca_profiles` entry; must be in `$ca_whitelist`. |
| `posthook_cmd` | `Optional[String[1]]` | `$acme_kvstore::posthook_cmd` | Command run on the worker (only) after a successful issue/renew. |
| `proxy` | `Optional[String[1]]` | `$acme_kvstore::proxy` | HTTP(S) proxy for acme.sh's outbound connections. |
| `exec_timeout` | `Integer[1]` | `$acme_kvstore::exec_timeout` | Maximum time in seconds any single acme.sh invocation may run. |
| `renew_schedule` | `Optional[String[1]]` | `$acme_kvstore::renew_schedule` | Name of a `schedule` resource limiting when a due renewal runs. |

`run_as_user`, `run_as_group`, `run_as_home`, `acmesh_path`, `webroot`,
`log_file` and `log_level` are not exposed here - they are always resolved
automatically from `acme_kvstore::worker`'s parameters, since they
describe the worker host's setup rather than anything specific to one
certificate.

## Defined type `acme_kvstore::deploy`

A thin wrapper around `acme_kvstore::lookup_cert` that writes a
certificate (and, optionally, its key, chain, full chain, a combined file
and DH parameters) to disk and notifies a service. It is
independent of the `acme_kvstore` class and the worker (see
[Certificates in Hiera](#certificates-in-hiera)). See
[lookup_cert.md](lookup_cert.md#acme_kvstoredeploy) for the full parameter
reference and examples.

## Type `acme_kvstore_certificate` (providers `consul`/`redis`)

Usually **not** used directly, but via `acme_kvstore::certificate`. See
[`lib/puppet/type/acme_kvstore_certificate.rb`](../lib/puppet/type/acme_kvstore_certificate.rb)
for the full parameter list, including the lower-level `server`,
`account_email`, `eab_kid`, `eab_hmac_key`, `dns_options`, `dnssleep`,
`webroot`, `log_file`, `log_level`, `posthook_cmd`,
`proxy`, `exec_timeout`, `run_as_user`, `run_as_group` and `run_as_home`
parameters that `acme_kvstore::certificate` resolves from
CA/DNS profiles and from `acme_kvstore::worker` on your behalf.

## Type `acme_kvstore_cert_data` (providers `consul`/`redis`)

Read-only, for consumer systems, run during catalog application on the
target node. Parameters: `certid` (namevar), `area`, `prefix`,
`backend_config`, `area_secret`, `decrypt_key`. Properties: `status`,
`active_version`, `latest_version`, `updated_at`, `pem`, `has_key`,
`private_key`. See [architecture.md](architecture.md#status-values) for
how `status` gates `pem`/`has_key`/`private_key`.

## Function `acme_kvstore::lookup_cert`

Compile-time equivalent of `acme_kvstore_cert_data`, for use on the Puppet
server. See [lookup_cert.md](lookup_cert.md) for the full parameter
reference, return value and examples.

## Function `acme_kvstore::request_cert(Array[String[1]] $domains, Hash $options = {})`

Invokes acme.sh directly, **without** storing anything in the KV store -
intended for manual testing/debugging on the worker host. `$options`:
`key_type`, `key_size`, `server`, `dns_provider`, `dns_env`, `dns_options`,
`challenge_alias`, `domain_alias`, `account_email`, `eab_kid`,
`eab_hmac_key`, `proxy`, `exec_timeout`, `run_as_user`,
`run_as_group`, `run_as_home`, `acmesh_path`, `dnssleep` (default `60`),
`webroot`, `log_file`, `log_level`.

## Function `acme_kvstore::unwrap_if_sensitive(Value $value)`

`@api private` helper used internally to unwrap `Sensitive[String]` values
(area secrets, per-area Consul/Redis credentials, EAB credentials, DNS
profile `env`/`options` values) before they reach Ruby code; returns non-`Sensitive`
values unchanged.
