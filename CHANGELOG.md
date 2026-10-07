# Changelog

All notable changes to this module will be documented here. See
`metadata.json`'s `version` field for the current version.

## 0.1.0 (in development)

Initial development version, not released yet.

- ACME certificates via acme.sh on central ACME worker(s), stored in
  Consul or Redis instead of exported resources/PuppetDB; every write is
  compare-and-set protected, with one KV read per worker run.
- KV layout below `<prefix>/<area>/` per area; private keys encrypted with
  AES-256-GCM using the area secret.
- Least-privilege KV access per area: the worker's read/write credentials
  (`consul_token`, `redis_username`/`redis_password`) and separate
  read-only ones for `acme_kvstore::deploy` (`consul_read_token`,
  `redis_read_username`/`redis_read_password`); no global credentials.
- DNS and CA profiles (accounts, EAB, CA whitelist), DNS alias mode,
  `dnssleep`, nsupdate TSIG key files, custom DNS API scripts
  (`dnsapi_scripts`, used by profiles via `hook`), HTTP-01 webroot, wildcard certificates
  via DNS-01.
- Certificates defined in Hiera (`acme_kvstore::certificates`) with
  `domain` and `subject_alt_names`: issued at once, renewed within
  `renew_before_days` (optionally only inside a `renew_schedule` time
  window), configuration drift detection (`purge_key_on_mismatch`); only
  entries marked with `acme_renewal` are ever renewed, others are never
  overwritten.
- Storage format of [CCI-UI](https://github.com/c8m6/cci-ui), only extended
  by `acme_renewal`: one certificate per document, `tags` always present,
  immutable versions, keys encrypted with CCI-UI's associated data;
  intermediate, CA and root certificates as entries of their own (certid =
  `<cn>_<expiry date>`, e.g. `isrg-root-x1_2035-06-04`; `store_issuers`),
  chains built from them only when
  requested; archived entries are not
  renewed; CCI-UI's naming rules for areas, certids and `kv_client`.
- `acme_kvstore::deploy`, independent of the worker: certificate, key,
  chain, full chain, combined file and RFC 7919 DH parameters on any node,
  controlled by the certificate's `status` (`active` writes, `norollout`
  leaves alone, `delete` removes); optionally with the root CA
  (`chain_include_root`) for applications without a trust store;
  `acme_kvstore::lookup_cert` and `acme_kvstore_cert_data` for custom use.
- Typed parameters (`types/`), defaults in module Hiera data with
  deep-merged hashes.
- Tests: rspec-puppet/RuboCop/puppet-lint via voxpupuli-test on OpenVox 8
  (and OpenVox 9 under Ruby 4.0), PDK 3.8 compatible; `rake jruby:compat`
  checks the lookup code under the Puppet server's JRuby; `rake acceptance`
  issues with acme.sh against Pebble into real Consul and Redis (ACLs
  included), also in CI. Licence:
  AGPL-3.0-only.
