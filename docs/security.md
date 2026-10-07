# Security

## Area secrets and per-area credentials

Each area has exactly one 32-byte secret (AES-256), used exclusively to
encrypt the private keys belonging to that area, and may optionally carry
its own Consul token and/or Redis password:

```puppet
areas => {
  'web'      => { 'secret' => Sensitive('<32 bytes>'), 'consul_token' => Sensitive('<write token for acme/web/>'), 'consul_read_token' => Sensitive('<read token for acme/web/>') },
  'internal' => { 'secret' => Sensitive('<a different 32 bytes>'), 'redis_username' => 'acme-internal', 'redis_password' => Sensitive('<Redis password>') },
}
```

Accepted formats for `secret`: raw (32 bytes), hex (64 characters) or
base64. Decoding and validation is handled by
`PuppetX::AcmeKvstore::Crypto.decode_area_secret`. A per-area
`consul_token` (required with Consul) or `redis_username`/`redis_password`
(required with Redis) is used for that area only - global credentials are
rejected for both backends - on top of the class's global `$consul`/`$redis` connection Hash, letting a single Consul/Redis cluster be shared
between areas whose ACL tokens are scoped down to that area's own KV
prefix, `<prefix>/<area>/` - see
[configuration.md](configuration.md#areas). Readers are separated from
the writer as well: `acme_kvstore::deploy` uses the area's read-only
credentials (`consul_read_token`, `redis_read_username`/`redis_read_password`)
and never the worker's read/write ones, so the Puppet server compiling
consumer catalogues only needs read access.

**Recommendation**: manage all of these via `Sensitive[String]` and
Hiera-eyaml/Vault, never commit them in plain text. `Sensitive[String]`
values are unwrapped internally (via the `@api private`
`acme_kvstore::unwrap_if_sensitive` function) only at the point they are
handed to Ruby code; a plain `String[1]` is equally accepted wherever
already protected some other way.

## ACME account credentials (EAB)

CA profiles' `account_email`, `eab_kid` and `eab_hmac_key` (see
[profiles.md](profiles.md)) follow the same `Variant[String[1],
Sensitive[String[1]]]` handling as area secrets and per-area credentials -
wrap `eab_kid`/`eab_hmac_key` in `Sensitive[String]` in your manifests.

## Private key encryption

- Algorithm: **AES-256-GCM**
- IV: 12 bytes, cryptographically random, freshly generated on every
  encryption (`OpenSSL::Random.random_bytes(12)`)
- Authentication tag: 16 bytes, stored alongside the ciphertext and
  verified on decryption (GCM AEAD - any tampering with the ciphertext,
  IV or tag causes decryption to fail)
- The format is stably versioned via a `"version": 1` field, to allow for
  future algorithm changes
- Associated data: `cci:<area>:<certid>/<version>`, as in
  [CCI-UI](cci-ui.md) - an envelope copied to another area, certificate or
  version no longer decrypts, and CCI-UI and this module can read each
  other's keys

## Transport encryption

Both the Consul and the Redis client require `https`/`tls` in their
configuration, or otherwise connect unencrypted (only sensible for
test/loopback environments). Both support **mTLS** via
`cert_file`/`key_file` in addition to `ca_file`.

## Write concurrency (compare-and-set)

Writes to the meta document are protected by compare-and-set (Consul:
`cas` verb on the `ModifyIndex`; Redis: `WATCH`/`MULTI`/`EXEC`), so two
concurrent renewals of the same certificate - e.g. from two workers, or
two overlapping Puppet runs - cannot silently overwrite one another. The
loser of the race fails for that run with a `CasConflictError` and is
retried cleanly on the next scheduled run. See
[architecture.md](architecture.md) for the full mechanism.

## Area secret rotation

Rotating an area secret requires re-encrypting all affected key documents
(old documents can no longer be decrypted otherwise). Recommended
approach:

1. Create a new, separately versioned area with the new secret (e.g.
   `web-v2`).
2. Route new certificates/renewals through the new area.
3. Existing certificates are automatically migrated to the new encryption
   on their next renewal (every `create` run encrypts with whichever
   `area_secret` is currently configured).

## CA whitelisting

`$ca_whitelist` (see [profiles.md](profiles.md#ca_whitelist)) is a
deliberate, separate opt-in: defining a CA's connection details under
`$ca_profiles` does not, by itself, let any certificate use it. This
prevents a typo'd or malicious `use_ca_profile` value from silently
directing certificate issuance - and any DNS API credentials/EAB
credentials that come with it - at an unintended, unapproved CA.

## Dedicated worker user

`acme_kvstore::worker`'s `user`/`group` parameters (default `'root'`) let
acme.sh - and, by extension, this module's Ruby provider code - run as an
unprivileged, dedicated account instead of root. Certificate issuance and
renewal do not themselves require root privileges once acme.sh and its
home directory belong to that account; running as root is only the
default for zero-configuration setups.

The switch is enforced via `Process.spawn`'s `:uid`/`:gid` options (see
`PuppetX::AcmeKvstore::Acmesh.run_with_timeout`), which only affect the
spawned acme.sh/`posthook_cmd` child process - never the Puppet agent
process itself, which continues running as whichever user invoked
`puppet agent`/`puppet apply` (normally root, since Puppet itself
generally requires root to manage most other resource types).

```puppet
class { 'acme_kvstore::worker':
  manage_user => true,
  user        => 'acme',
  group       => 'acme',
}
```

## Where the private key lives

Unlike puppet-acme, where the private key is generated on the node that
uses the certificate and **never leaves it** (only the CSR travels to the
Puppet server), this module generates the key on the ACME worker and
distributes it:

- It is stored in Consul/Redis only encrypted with the area secret
  (AES-256-GCM), see above.
- `acme_kvstore::deploy`/`acme_kvstore::lookup_cert` decrypt it while
  compiling the consumer's catalogue, so it is part of that compiled
  catalogue (wrapped in `Sensitive`, so it is redacted from logs and
  reports, but present in the catalogue the Puppet server sends to the
  agent). Protect catalogue storage accordingly (e.g. PuppetDB catalogue
  storage, cached catalogues on agents).
- `acme_kvstore_cert_data` decrypts it on the consumer node itself
  instead, if the catalogue must not contain it.

This is the price of central issuance without exported resources; in
return, a certificate and its key can be used on any number of nodes, and
every reissue produces a new key.

## nsupdate TSIG key files

For DNS profiles using the `dns_nsupdate` hook, `acme_kvstore::worker`
writes the TSIG secret to `<config_dir>/nsupdate/<profile>.key` (see
[profiles.md](profiles.md#nsupdate-bind-tsig-keys)): owned by `root`,
group `<group>`, mode `0640` inside a `0750` directory - the acme.sh user
can read the key but not change it - and never shown in a diff.
Give the TSIG key update rights only for the `_acme-challenge` records it
needs (BIND `update-policy`).

## Custom DNS API scripts

A script from `dnsapi_scripts` (see
[profiles.md](profiles.md#custom-dns-api-scripts)) is sourced by acme.sh
and runs inside the acme.sh process, as the acme.sh user, with the
using profile's `env` - including its DNS API credentials. Treat it like
`posthook_cmd`: trusted code you review, not something fetched from
elsewhere at run time. It is installed `root:<group>` mode `0640`, so the
acme.sh user can read but never modify it.

## acme.sh log file

`acme_kvstore::worker`'s `acme_log_file` (default
`/var/log/acme.sh/acme.log`, mode `0640`) is written by acme.sh itself.
At `acme_log_level => 2` (debug) acme.sh logs considerably more detail
about its requests; keep level `1` unless debugging, and restrict access
to the log accordingly. This module does not rotate the file.

## `posthook_cmd` runs as trusted input

`posthook_cmd` (see [profiles.md](profiles.md#posthook_cmd)) is executed
as a shell command with no sanitisation - it is configuration you write,
not data from an external or untrusted source, and should be treated with
the same care as any other command embedded in a manifest. The same
applies to `dns_options` values that are not `dnssleep` (each becomes a
literal, upper-cased environment variable name and value - see
`PuppetX::AcmeKvstore::Acmesh.build_env`).

## What is deliberately NOT in this module

- No automatic deletion of old certificate/key versions (the audit trail
  is preserved; clean-up is the responsibility of a separate housekeeping
  process outside this module).
- No distribution/lookup of certificates on consumer nodes beyond the
  optional `acme_kvstore_cert_data` type and `acme_kvstore::lookup_cert`
  function, both of which withhold certificate/key data for any status
  but `active` - see [architecture.md](architecture.md#status-values).
