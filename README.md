# zaeh-acme_kvstore

[![CI](https://github.com/zaeh/zaeh-acme_kvstore/actions/workflows/ci.yml/badge.svg)](https://github.com/zaeh/zaeh-acme_kvstore/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue.svg)](LICENSE)

A Puppet module for managing ACME/Let's Encrypt certificates, broadly
modelled on the functionality of
[`puppet-acme`](https://github.com/markt-de/puppet-acme) - including
predefined DNS and CA profiles with accounts, a default CA/area, a CA
whitelist, DNS alias mode and SAN support - but deliberately **without
exported resources or PuppetDB**. Certificates, chains and private keys
are instead stored in a **Consul** or **Redis** cluster, with writes
protected by **compare-and-set** so that concurrent renewals cannot
silently overwrite one another.

## Status

Version 0.1.0, **in development** and not yet used in production. The unit
tests cover Puppet/OpenVox 8 and OpenVox 9, and the
lookup code is checked under the Puppet server's JRuby; there are no
acceptance tests against real Consul/Redis clusters yet. Expect changes
before 1.0.0.

## Requirements

- Puppet or OpenVox 8 or 9, on Linux (RedHat, Debian, Ubuntu - see
  `metadata.json`)
- a **Consul** cluster (KV with ACLs) or **Redis** (6+, ACL users; a sharded
  Redis Cluster is not supported), reachable
  from the ACME worker and - for `acme_kvstore::deploy`/`lookup_cert` - from
  the Puppet server
- [acme.sh](https://github.com/acmesh-official/acme.sh) on the ACME worker,
  installed by `acme_kvstore::worker`
- with Redis: the `redis` gem on the worker (installed automatically) and in
  the Puppet server's JRuby (`puppetserver gem install redis`), see
  [docs/redis.md](docs/redis.md#prerequisite)
- modules [puppetlabs/stdlib](https://forge.puppet.com/modules/puppetlabs/stdlib)
  and [puppetlabs/vcsrepo](https://forge.puppet.com/modules/puppetlabs/vcsrepo)

## Documentation

- [REFERENCE.md](REFERENCE.md) - generated reference of all classes, defined types, types, functions and data types
- [docs/architecture.md](docs/architecture.md) - overall architecture, workflow, status values, comparison with `puppet-acme`
- [docs/configuration.md](docs/configuration.md) - reference for all class/type parameters
- [docs/profiles.md](docs/profiles.md) - DNS profiles, CA profiles, accounts, defaults, `ca_whitelist`, DNS alias mode, SANs
- [docs/consul.md](docs/consul.md) - Consul backend, KV layout, TLS/mTLS, CAS
- [docs/redis.md](docs/redis.md) - Redis backend, KV layout, TLS/mTLS, CAS
- [docs/lookup_cert.md](docs/lookup_cert.md) - delivering certificates to other nodes from the Puppet server
- [docs/security.md](docs/security.md) - encryption, area/CA secrets, key rotation, CA whitelisting
- [docs/migration.md](docs/migration.md) - migrating from `puppet-acme`
- [docs/cci-ui.md](docs/cci-ui.md) - storage format shared with CCI-UI, settings for using it

## Quick overview

```puppet
class { 'acme_kvstore':
  prefix         => 'acme',
  backend        => 'consul',
  default_worker => 'acme-worker1.example.com',
  default_area   => 'web',
  areas          => {
    # consul_token: the worker's (write) token, consul_read_token: acme_kvstore::deploy's (read) token
    'web'      => { 'secret' => Sensitive('<32-byte secret, base64 or hex>'), 'consul_token' => Sensitive('<write token for acme/web/>'), 'consul_read_token' => Sensitive('<read token for acme/web/>') },
    'internal' => { 'secret' => Sensitive('<another 32-byte secret>'), 'consul_token' => Sensitive('<write token for acme/internal/>'), 'consul_read_token' => Sensitive('<read token for acme/internal/>') },
  },
  consul => {
    'url'       => 'https://consul.example.com:8501',
    'ca_file'   => '/etc/ssl/certs/consul-ca.pem',
    'cert_file' => '/etc/ssl/certs/consul-client.pem',
    'key_file'  => '/etc/ssl/private/consul-client.key',
  },
  dns_profiles => {
    'route53' => {
      'hook' => 'dns_aws',
      'env'  => { 'AWS_ACCESS_KEY_ID' => Sensitive('...'), 'AWS_SECRET_ACCESS_KEY' => Sensitive('...') },
    },
  },
  default_dns_profile => 'route53',
  ca_profiles          => {
    'letsencrypt'      => {},
    'letsencrypt_test' => {},
    'zerossl'          => { 'account_email' => 'ssl@example.com', 'eab_kid' => Sensitive('...'), 'eab_hmac_key' => Sensitive('...') },
  },
  default_ca_profile => 'letsencrypt',
  ca_whitelist        => ['letsencrypt', 'letsencrypt_test', 'zerossl'],
  certificates        => {
    'shop-example-com'     => {
      'domain'            => 'shop.example.com',
      'subject_alt_names' => ['www.shop.example.com'],
      # 'area'            => 'web',                      # optional, otherwise $default_area
      # 'worker'          => 'acme-worker2.example.com', # optional, otherwise $default_worker
      # 'use_dns_profile' => 'route53',                  # optional, otherwise $default_dns_profile, then HTTP-01
      # 'use_ca_profile'  => 'zerossl',                  # optional, otherwise $default_ca_profile
    },
    'wildcard-example-com' => { 'domain' => '*.example.com', 'subject_alt_names' => ['example.com'] },
  },
}
```

Every parameter can also be set in Hiera, which is the usual way; then
`include acme_kvstore` is all the Puppet code needed:

```yaml
acme_kvstore::default_worker: 'acme-worker1.example.com'
acme_kvstore::default_area: 'web'
acme_kvstore::certificates:
  shop-example-com:
    domain: 'shop.example.com'           # primary domain (CN)
    subject_alt_names:                   # optional further names
      - 'www.shop.example.com'
  wildcard-example-com:
    domain: '*.example.com'              # wildcards need DNS-01
    subject_alt_names: ['example.com']
```

The same configuration can be given to **every** node: a certificate is
only issued and renewed on its responsible ACME worker. Each entry of
`certificates` takes the parameters of `acme_kvstore::certificate` (see
[docs/configuration.md](docs/configuration.md#certificates-in-hiera)); the
defined type can also be declared directly.

## KV data model (Consul/Redis)

```text
<prefix>/<area>/certids/<certid>          -> meta document (active version, status, ...)
<prefix>/<area>/certs/<certid>/<version>  -> exactly one certificate (PEM), metadata
<prefix>/<area>/keys/<certid>/<version>   -> AES-256-GCM encrypted private key
```

Everything belonging to an area lives below `<prefix>/<area>/`, so an
area's Consul/Redis ACL token can be restricted to exactly that path.
Intermediate, CA and root certificates are entries of their own (certid =
`<cn>_<expiry date>`, e.g. `r11_2027-03-12`, no key), from which chains are built. The format is
that of [CCI-UI](https://github.com/c8m6/cci-ui), a web UI for these
certificates - see [docs/cci-ui.md](docs/cci-ui.md).

Writes to the meta document use compare-and-set (Consul CAS on the
ModifyIndex; Redis WATCH/MULTI/EXEC) to guard against concurrent renewals.
Only certificates configured in `acme_kvstore::certificates` are issued
and renewed (marked by `acme_renewal` in the meta document); entries
written by other tools are never overwritten. A certificate's `status`
only controls distribution: `active` is delivered by `acme_kvstore::deploy`,
`norollout` is left alone, `delete` is removed from the node. Full details and the exact JSON formats are in
[docs/architecture.md](docs/architecture.md).

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to test and contribute, and
[SECURITY.md](SECURITY.md) for reporting vulnerabilities privately.

## Licence

[GNU Affero General Public License v3.0 only](LICENSE)
(`AGPL-3.0-only`). Contains no code from `puppet-acme`; only the broad
functional/parameter concept is modelled on that module.
