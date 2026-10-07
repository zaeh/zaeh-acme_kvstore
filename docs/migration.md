# Migrating from `puppet-acme`

This module is **not a drop-in replacement** for `puppet-acme` (different
type names, a different storage format, a different distribution
mechanism). Recommended migration path:

1. **Decide on worker host(s).** In `puppet-acme`, each node generates its
   own private key and CSR, and a single `$acme_host` (usually the Puppet
   server) signs the CSRs collected via PuppetDB. Here, one or more
   dedicated ACME worker hosts do everything - key generation, issuance,
   renewal - and store the results in the KV store. Workers need network
   access to the ACME server, to the DNS API (DNS-01), and to the
   Consul/Redis cluster.

2. **Create areas and secrets.** For each previous `puppet-acme` "group"
   of certificates, create an area with its own 32-byte secret (see
   [security.md](security.md)).

3. **Recreate `accounts`/`profiles`/`ca_config`/`default_ca`/`ca_whitelist`
   as DNS and CA profiles.** `puppet-acme`'s `accounts` (a plain list of
   emails) and `profiles` (DNS-01 challenge configs) map onto this
   module's `$dns_profiles` for the DNS side, while a `profiles` entry's
   `use_account`/CA pairing and `ca_config`/`default_ca`/`ca_whitelist`
   map onto `$ca_profiles`/`default_ca_profile`/`ca_whitelist` here, with
   the account email (and any EAB credentials) living directly on the CA
   profile that needs it rather than as a separately cross-referenced
   list. Hook names need the full acme.sh name (`aws` -> `dns_aws`,
   `nsupdate` -> `dns_nsupdate`); `options` such as `dnssleep` and the
   nsupdate TSIG settings (`nsupdate_id`/`nsupdate_type`/`nsupdate_key`)
   keep their names. See [profiles.md](profiles.md) for the full mapping
   and examples, including `challenge_alias`/`domain_alias` for DNS alias
   mode, and the [parameter mapping](#parameter-mapping) below.

4. **Import existing certificates once (optional).** If existing
   certificates managed by `puppet-acme` should be taken over, their PEM
   files and keys can be transferred into the new KV format once (e.g. via
   `puppet apply` with `acme_kvstore_certificate { ... ensure => present }`
   after a prior manual KV write, or via a small one-off script using
   `PuppetX::AcmeKvstore::Crypto` and `ConsulClient`/`RedisClient`
   directly). This module deliberately does not ship an automatic import
   tool, since the structure of certificate groups varies widely across
   `puppet-acme` installations. An imported meta document needs an
   `acme_renewal` summary (at least `not_after`; see
   [architecture.md](architecture.md#kv-data-formats)) for this module to
   take over its renewal - without it, the worker only warns and never
   touches the entry.

5. **Create `acme_kvstore::certificate` declarations**, analogous to the
   previous `acme::certificate` declarations, but with `area`, `certid`
   and an optional `worker` instead of exported resources, and
   `use_dns_profile`/`use_ca_profile` instead of `use_profile`/`use_account`/`ca`.

6. **Update consumer nodes.** Use `acme_kvstore::deploy` (which can write
   the same files puppet-acme provides - certificate, chain, full chain, a
   combined file with the key and DH parameters), the
   `acme_kvstore_cert_data` type or the `acme_kvstore::lookup_cert`
   function (see [lookup_cert.md](lookup_cert.md)) instead of
   `puppet-acme`'s files under `/etc/acme.sh`, or build custom tooling
   integration using `PuppetX::AcmeKvstore::ConsulClient` or `RedisClient`
   directly in your own facts/functions.

7. **Remove the old `puppet-acme` declarations** once every certificate
   has been successfully renewed via `acme_kvstore`.

## Key conceptual differences

| Aspect | `puppet-acme` | `acme_kvstore` |
| --- | --- | --- |
| Private key | generated on the node that uses the certificate and never leaves it; only the CSR travels | generated on the ACME worker, stored AES-256-GCM encrypted in the KV store and distributed to consumers (see [security.md](security.md#where-the-private-key-lives)) |
| Storage location | PuppetDB (exported resources) | Consul or Redis |
| Key encryption | not needed - the key is never transferred | always AES-256-GCM with an area secret |
| Concurrency control | not applicable (PuppetDB collection) | compare-and-set (Consul CAS / Redis WATCH) |
| Distribution mechanism | export/collect via PuppetDB | direct, synchronous KV write |
| Where does the request run? | the node creates key and CSR; `$acme_host` (usually the Puppet server) signs the CSR with acme.sh | everything centrally on ACME worker host(s) |
| Renewal trigger | regular Puppet runs on `$acme_host`, checking expiry with `openssl x509 -checkend` | regular Puppet runs on the worker; a due renewal optionally limited to the time window of `renew_schedule` |
| Time to a new certificate | several Puppet runs on node and server | one Puppet run on the worker, then the consumer's next run |
| Accounts/CAs | separate `accounts`/`profiles`/`ca_config` lists | `$ca_profiles` bundle CA + account (+ EAB) together |
| Status values | not applicable | `active` / `norollout` / `delete`, controlling distribution only, see [architecture.md](architecture.md#status-values) |

## Parameter mapping

| `puppet-acme` | `acme_kvstore` |
| --- | --- |
| `acme::certificate` / `$certificates` | `acme_kvstore::certificate` / `$certificates` (e.g. entirely in Hiera) |
| resource title or `domain` (space-separated or Array) | `certid` + `domain` (primary) + `subject_alt_names` |
| `acme_host` | `worker` / `$default_worker` |
| `accounts`, `use_account`, `default_account` | `$ca_profiles[...]['account_email']`, `use_ca_profile`, `$default_ca_profile` |
| `profiles`, `use_profile`, `default_profile` | `$dns_profiles`, `use_dns_profile`, `$default_dns_profile` |
| `ca`, `default_ca`, `ca_config`, `ca_whitelist` | `use_ca_profile`, `$default_ca_profile`, `directory_url`, `$ca_whitelist` |
| `challenge_alias`, `domain_alias` | same names, on the DNS profile or the certificate |
| `key_size` | `key_size` (+ `key_type` for EC keys) |
| `renew_days` | `renew_before_days` / `$renew_before_days` |
| `purge_key_on_mismatch` | `purge_key_on_mismatch` / `$purge_key_on_mismatch` |
| `ocsp_must_staple`, OCSP response file (`cert.ocsp`) | not supported (OCSP is outdated, see [profiles.md](profiles.md#ocsp)) |
| `dh_param_size` / `params.dh` | `$dh_param_size` + `acme_kvstore::deploy`'s `dh_path` (RFC 7919 groups) |
| `cert.pem`, `chain.pem`, `fullchain.pem`, `fullchain_with_key.pem` | `acme_kvstore::deploy`'s `cert_path`, `chain_path`, `fullchain_path`, `combined_path` |
| `dnssleep` | `$dnssleep` / DNS profile `options['dnssleep']` / `dnssleep` |
| `posthook_cmd` | `posthook_cmd` (runs on the worker only); on consumers use `acme_kvstore::deploy`'s `notify_services` |
| `proxy`, `exec_timeout` | same names |
| `acme_git_url`, `acme_git_force`, `acme_revision` | `acme_kvstore::worker`'s `acme_git_url`, `acme_git_force`, `acme_version` (pinned by default) |
| `acmelog`, `log_dir` | `acme_kvstore::worker`'s `acme_log_file`, `acme_log_level` |
| `user`, `group`, `manage_packages` | `acme_kvstore::worker`'s `user`, `group`, `manage_packages` |
