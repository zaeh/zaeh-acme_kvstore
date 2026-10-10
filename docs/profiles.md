# DNS profiles, CA profiles and accounts

`acme_kvstore` lets you predefine, once, on the `acme_kvstore` class:

- **DNS profiles** (`$dns_profiles`) - reusable DNS-01 challenge
  configurations (which acme.sh DNS hook to use, its API credentials, and
  optionally DNS alias mode settings).
- **CA profiles** (`$ca_profiles`) - reusable ACME certificate authority
  configurations, each bundling the CA's directory URL together with the
  ACME account data needed to use it (account email and/or External
  Account Binding credentials).

Both have a configurable default, so most `acme_kvstore::certificate`
declarations need only name a `certid`, `area` and `domain` - see
[configuration.md](configuration.md) for the full parameter reference.

This intentionally consolidates what upstream
[`puppet-acme`](https://github.com/markt-de/puppet-acme) splits into three
separate structures (`accounts`, `profiles`, `ca_config`) into two: since a
CA account is only ever meaningful together with a specific CA, its
account data lives directly on the CA profile that needs it, rather than
being a third, independently cross-referenced list.

## DNS profiles

```puppet
class { 'acme_kvstore':
  # ...
  dns_profiles => {
    'route53' => {
      'hook' => 'dns_aws',
      'env'  => {
        'AWS_ACCESS_KEY_ID'     => Sensitive('AKIA...'),
        'AWS_SECRET_ACCESS_KEY' => Sensitive('...'),
      },
    },
    'bind' => {
      'hook'    => 'dns_nsupdate',
      'env'     => { 'NSUPDATE_SERVER' => 'bind.example.com' },
      'options' => {
        'nsupdate_id'   => 'acme-key',
        'nsupdate_type' => 'hmac-sha256',
        'nsupdate_key'  => Sensitive('<base64 TSIG secret>'),
        'dnssleep'      => 15,
      },
    },
  },
  default_dns_profile => 'route53',
}
```

| Key | Required | Description |
| --- | --- | --- |
| `hook` | yes | The acme.sh DNS API hook name, e.g. `dns_aws`, `dns_cf`, `dns_nsupdate` - the **full** name as documented on the [acme.sh DNS API wiki page](https://github.com/acmesh-official/acme.sh/wiki/dnsapi), not an abbreviation - or the name of a [custom DNS API script](#custom-dns-api-scripts). |
| `env` | no | Environment variables passed to acme.sh exactly as given (their casing matters to the hook script) - this is where DNS API credentials go. |
| `options` | no | Extra, hook-specific settings (values may be `Sensitive`). `dnssleep` overrides `$acme_kvstore::dnssleep` for this profile (see [`dnssleep`](#dnssleep)); for `dns_nsupdate`, `nsupdate_id`/`nsupdate_type`/`nsupdate_key` become a TSIG key file (see [nsupdate](#nsupdate-bind-tsig-keys)); every other key is upper-cased into an environment variable (e.g. `nsupdate_zone` becomes `NSUPDATE_ZONE`), matching the convention most acme.sh DNS hooks use. |
| `challenge_alias` | no | See [DNS alias mode](#dns-alias-mode) below. |
| `domain_alias` | no | See [DNS alias mode](#dns-alias-mode) below. |
| `ca_certificates` | no | CA certificates (PEM, one or more) of the DNS API's TLS certificate, e.g. of an internal Infoblox. Not together with `ca_bundle`. See [CA certificates](#ca-certificates-for-private-cas-and-dns-apis). |
| `ca_bundle` | no | The same as a file that is already on the worker (absolute path). Not together with `ca_certificates`. |

Many acme.sh hooks save their settings in acme.sh's `account.conf`
(`_saveaccountconf`), and acme.sh reads that file on every start, so a
saved value would override the one from the profile - a changed view,
server or rotated credential would never take effect. The worker therefore
removes the keys it passes (from `env`/`options`, also as `SAVED_<key>`)
from `account.conf` before and after every acme.sh run; the profile always
wins, and the values do not stay on disk. acme.sh's own settings in that
file are left alone.

A certificate picks a profile with `use_dns_profile`, falls back to
`$acme_kvstore::default_dns_profile` if it does not name one, or falls
back further still to HTTP-01 via webroot if neither resolves:

```puppet
acme_kvstore::certificate { 'shop-example-com':
  area    => 'web',
  domain  => 'shop.example.com',
  # use_dns_profile => 'route53', # optional - otherwise $default_dns_profile, then HTTP-01
}
```

For a one-off certificate that needs a DNS hook not worth turning into a
reusable profile, `dns_provider`/`dns_env` on `acme_kvstore::certificate`
remain available as a manual, low-level override - it always takes
precedence over any profile.

### `dnssleep`

For DNS-01, acme.sh normally checks itself whether the new
`_acme-challenge` TXT records are visible, by polling public
DNS-over-HTTPS resolvers (Cloudflare/Google). This module always passes
`--dnssleep <seconds>` instead, so acme.sh simply waits that long and never
contacts those resolvers - useful for internal/split-horizon DNS and for
workers without general internet access. The value is resolved in this
order:

1. `dnssleep` on `acme_kvstore::certificate`
2. `options['dnssleep']` of the resolved DNS profile
3. `$acme_kvstore::dnssleep` (default `60`)

It must be lower than `exec_timeout`; compilation fails otherwise.

### nsupdate (BIND TSIG keys)

acme.sh's `dns_nsupdate` hook expects `NSUPDATE_KEY` to be the **path** of
a TSIG key file, not the secret itself. As in puppet-acme, a DNS profile
using `'hook' => 'dns_nsupdate'` with `nsupdate_id`, `nsupdate_type` and
`nsupdate_key` options (see the `bind` example above) is handled like this:

- `acme_kvstore::worker` writes the key in BIND TSIG key format to
  `<config_dir>/nsupdate/<profile>.key` (default
  `/etc/acme_kvstore/nsupdate/bind.key`), owned by `root`, group
  `<group>`, mode `0640` (read-only for the acme.sh user), without ever
  showing its content in a diff.
- `acme_kvstore::certificate` sets `NSUPDATE_KEY` to that path and does
  **not** pass the three options on as environment variables. An explicit
  `NSUPDATE_KEY` in the profile's `env` still wins.

Other `dns_nsupdate` settings (`NSUPDATE_SERVER`, `NSUPDATE_SERVER_PORT`,
`NSUPDATE_ZONE`, `NSUPDATE_OPT`) go into `env` as usual, or as lower-case
`options` keys.

### Custom DNS API scripts

For a DNS API acme.sh does not ship a hook for, define your own script
once in `dnsapi_scripts` - keyed by its hook name, with either `source`
(`puppet:///...` URL or absolute path) or inline `content` - and use it
from any number of DNS profiles via their `hook`:

```puppet
class { 'acme_kvstore':
  # ...
  dnsapi_scripts => {
    'dns_rockenstein' => { 'source' => 'puppet:///modules/profile/acme/dns_rockenstein.sh' },
  },
  dns_profiles   => {
    'rockenstein'       => {
      'hook' => 'dns_rockenstein',
      'env'  => { 'ROX_Token' => Sensitive('...') },
    },
    'rockenstein_alias' => {
      'hook'            => 'dns_rockenstein',
      'env'             => { 'ROX_Token' => Sensitive('...') },
      'challenge_alias' => 'validation.example.com',
    },
  },
}
```

The same in Hiera:

```yaml
acme_kvstore::dnsapi_scripts:
  dns_rockenstein:
    source: 'puppet:///modules/profile/acme/dns_rockenstein.sh'
acme_kvstore::dns_profiles:
  rockenstein:
    hook: 'dns_rockenstein'
    env:
      ROX_Token: >
        ENC[PKCS7,...]
```

The script must follow the acme.sh DNS API convention: it is named after
the hook (`dns_rockenstein.sh`) and defines the shell functions
`<hook>_add` and `<hook>_rm` (here `dns_rockenstein_add`/
`dns_rockenstein_rm`). Credentials go into `env`/`options` as with any
other hook, never into the script itself.

`acme_kvstore::worker` installs it as `<home>/dnsapi/<hook>.sh` (e.g.
`/home/acme/.acme.sh/dnsapi/dns_rockenstein.sh`), owned by `root`, group
`<group>`, mode `0640`, after acme.sh itself: acme.sh 3.0.9 looks in its
own `dnsapi/` directory first and only sources the file, so read access
is all the acme.sh user gets.

- Use a hook name acme.sh does **not** ship (see the
  [DNS API list](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)):
  the script would otherwise replace acme.sh's own file, and acme.sh's
  next upgrade would replace it again.
- Script names must be full hook names (`dns_...`), and each script has
  exactly one of `source` or `content`; compilation fails otherwise.
- Every script in `dnsapi_scripts` is installed, whether a profile uses it
  or not - but only on the ACME worker; consumer nodes never need them.

## CA profiles

```puppet
class { 'acme_kvstore':
  # ...
  ca_profiles => {
    'letsencrypt'      => {},                    # acme.sh's built-in alias, no account needed
    'letsencrypt_test' => {},                     # ditto, staging
    'zerossl'          => {
      'account_email' => 'ssl@example.com',
      'eab_kid'       => Sensitive('...'),
      'eab_hmac_key'  => Sensitive('...'),
    },
    'privateca' => {
      'directory_url' => 'https://ca.example.com/acme/directory',
      'account_email' => 'certmaster@example.com',
    },
  },
  default_ca_profile => 'letsencrypt',
  ca_whitelist        => ['letsencrypt', 'letsencrypt_test', 'zerossl', 'privateca'],
}
```

| Key | Required | Description |
| --- | --- | --- |
| `directory_url` | no | The CA's ACME directory URL. Omit it for any of acme.sh's built-in aliases (`letsencrypt`, `letsencrypt_test`, `zerossl`, `buypass`, `sslcom`, `google`, `googletest`, `acmeca`, `actalis`) - the profile's own name is then used as that alias, so name a custom profile exactly as you'd pass it to `acme.sh --server`. Set it for a private/internal CA such as [step-ca](https://smallstep.com/docs/step-ca/). |
| `account_email` | no | Registered once per CA via `acme.sh --register-account -m <email>` before the first certificate under that profile is issued. |
| `eab_kid` / `eab_hmac_key` | no | External Account Binding credentials, required by some CAs (ZeroSSL, SSL.com, Google Public CA) - see each CA's page on the [acme.sh wiki](https://github.com/acmesh-official/acme.sh/wiki) for how to obtain them. |
| `ca_certificates` | no | CA certificates (PEM, one or more) of the CA's TLS certificate, e.g. the root of a private [step-ca](https://smallstep.com/docs/step-ca/). Not together with `ca_bundle`. See [CA certificates](#ca-certificates-for-private-cas-and-dns-apis). |
| `ca_bundle` | no | The same as a file that is already on the worker (absolute path), e.g. a company CA bundle. Not together with `ca_certificates`. |

A certificate picks a CA profile with `use_ca_profile`, defaulting to
`$acme_kvstore::default_ca_profile`:

```puppet
acme_kvstore::certificate { 'shop-example-com':
  area           => 'web',
  domain         => 'shop.example.com',
  use_ca_profile => 'zerossl', # optional - otherwise $default_ca_profile
}
```

### CA certificates for private CAs and DNS APIs

acme.sh trusts the system trust store of the worker. For a private CA or
an internal DNS API, give their CA certificates in the CA profile and the
DNS profile instead - as PEM (`ca_certificates`, written by the worker to
`<config_dir>/ca/ca-<profile>.pem` or `dns-<profile>.pem`) or as a file
already on the worker (`ca_bundle`).

For each certificate, the worker joins the CA certificates of its CA
profile and of its DNS profile into **one** bundle and passes it to acme.sh
(`--ca-bundle`) for the account registration and the issuance. That bundle
**replaces** the system trust store for every HTTPS request acme.sh makes,
the DNS hook's included. If one side uses a public certificate - e.g. a
private step-ca with Cloudflare's DNS API - set
`acme_kvstore::ca_bundle_include_system: true` (default `false`) to add the
system trust store (`acme_kvstore::worker::system_ca_bundle`, by OS family).
Without any profile CA certificates, acme.sh keeps using the system store as
it is.

acme.sh saves the bundle in its `account.conf`; the worker removes it again
around each run, so it never affects certificates of other profiles.

```yaml
acme_kvstore::ca_profiles:
  stepca:
    directory_url: 'https://stepca.example.com:9000/acme/acme/directory'
    ca_certificates: |
      -----BEGIN CERTIFICATE-----
      ...root of step-ca...
      -----END CERTIFICATE-----
acme_kvstore::dns_profiles:
  infoblox:
    hook: 'dns_infoblox'
    env:
      Infoblox_Server: 'infoblox.example.com'
    ca_bundle: '/etc/pki/infoblox-ca.pem'   # a file already on the worker
```

### `ca_whitelist`

`$ca_whitelist` is deliberately a separate list from `$ca_profiles`: adding
a CA's connection details to `$ca_profiles` does not, by itself, authorise
any certificate to actually use it. A certificate naming a `use_ca_profile`
that is not in `$ca_whitelist` fails to compile. `$default_ca_profile`
must itself be both a `$ca_profiles` key and a `$ca_whitelist` entry, and
every `$ca_whitelist` entry must have a matching `$ca_profiles` entry -
`acme_kvstore` validates all of this itself and fails with a clear message
otherwise.

## Account registration

Whenever a CA profile has an `account_email` or EAB credentials
configured, `acme_kvstore_certificate`'s provider runs
`acme.sh --register-account` for that account/CA combination immediately
before issuing or renewing a certificate under it. This call is itself
idempotent and cheap (a single request to the CA's account endpoint, not
counted against certificate issuance rate limits), so it is made
unconditionally on every actual issue/renew rather than relying on
acme.sh's internal on-disk account layout, which has changed between
versions.

## `challenge_type`

`acme_kvstore::certificate`'s `challenge_type` parameter (`'http-01'` or
`'dns-01'`) is optional and, left unset, is inferred automatically: `dns-01`
if a DNS profile or manual `dns_provider` resolves, otherwise `http-01`.
Setting it explicitly turns a mismatch into a hard compile-time failure -
useful for catching a certificate that was meant to use DNS-01 but has a
typo in its `use_dns_profile` name, or one that should definitely stay on
HTTP-01 but accidentally also received a DNS profile.

## DNS alias mode

If your DNS provider has no API access, or you would rather not grant API
access to your certificates' real domains, acme.sh's
[DNS alias mode](https://github.com/acmesh-official/acme.sh/wiki/DNS-alias-mode)
lets the `_acme-challenge` TXT record be created on a separate domain
instead, reached via a CNAME:

```text
_acme-challenge.shop.example.com   CNAME   _acme-challenge.validation-only.example.com
```

Set `challenge_alias` (and/or `domain_alias`) on a DNS profile - or, for a
one-off certificate, directly on `acme_kvstore::certificate` where it
overrides the profile's value:

```puppet
dns_profiles => {
  'route53_aliased' => {
    'hook'            => 'dns_aws',
    'env'             => { 'AWS_ACCESS_KEY_ID' => Sensitive('...'), 'AWS_SECRET_ACCESS_KEY' => Sensitive('...') },
    'challenge_alias' => 'validation-only.example.com',
  },
},
```

This maps directly to acme.sh's `--challenge-alias`/`--domain-alias` CLI
flags; only the DNS API credentials for the *alias* zone ever need to
reach the ACME worker.

## DNS-01 and wildcard certificates

DNS-01 is used whenever a DNS profile (or a manual `dns_provider`)
resolves for a certificate - see [DNS profiles](#dns-profiles). It is the
only challenge type that can validate **wildcard** names, and it does not
need the domain to point at the ACME worker at all, which makes it the
usual choice for this module's central-worker architecture.

A wildcard certificate has the wildcard name as its `domain`; to also
cover the bare domain, add it to `subject_alt_names`:

```puppet
class { 'acme_kvstore':
  # ...
  dns_profiles        => {
    'cloudflare' => { 'hook' => 'dns_cf', 'env' => { 'CF_Token' => Sensitive('<API token>') } },
  },
  default_dns_profile => 'cloudflare',
}

acme_kvstore::certificate { 'wildcard-example-com':
  area              => 'web',
  domain            => '*.example.com',
  subject_alt_names => ['example.com'],
}
```

This runs `acme.sh --issue -d '*.example.com' -d example.com --dns dns_cf
--dnssleep 60 ...` on the worker. Things to keep in mind:

- A wildcard only covers one label: `*.example.com` matches
  `shop.example.com`, but neither `example.com` itself nor
  `a.shop.example.com`.
- Both names above need an `_acme-challenge.example.com` TXT record; acme.sh
  handles that, but the DNS API credentials must allow it.
- A wildcard name without any resolvable DNS hook fails to compile (and is
  rejected by `acme_kvstore_certificate` itself), since HTTP-01 cannot
  validate it.
- Consumers use the certificate exactly like any other, e.g. via
  `acme_kvstore::deploy { 'wildcard-example-com': ... }` on every node that
  serves a matching name.

## Subject Alternative Names (SANs)

`acme_kvstore::certificate` separates the primary domain from the other
names:

```puppet
acme_kvstore::certificate { 'shop-example-com':
  area              => 'web',
  domain            => 'shop.example.com',
  subject_alt_names => ['www.shop.example.com', 'checkout.shop.example.com'],
}
```

- `domain` is the primary domain: the certificate's CN, and the name
  acme.sh files the certificate under.
- `subject_alt_names` are further names on the same certificate. As usual,
  the primary domain is also included in the certificate's SAN extension;
  listing it in `subject_alt_names` as well does no harm.

This maps to acme.sh's `-d shop.example.com -d www.shop.example.com ...`,
primary domain first. Changing `domain` or `subject_alt_names` forces a
reissue on the worker's next run, even if the certificate is not yet due
for renewal - see [Configuration drift](#configuration-drift). Merely
reordering `subject_alt_names` does not.

## Configuration drift

The meta document's `acme_renewal` summary stores the names (primary
domain first), `key_type` and `key_size` the active certificate was issued
with. On each run, the worker compares these against what
`acme_kvstore::certificate` currently asks for; a mismatch forces an
immediate reissue - not limited by `renew_schedule` - rather than waiting
for the certificate to merely approach its expiry date:

- **Names** changed: a different `domain`, or a name added to or removed
  from `subject_alt_names` (their order does not matter).
- **`key_type`** changed (`rsa` <-> `ec`).
- **`key_size`** changed (e.g. `2048` -> `4096`, or `256` -> `384` for EC).

Since every reissue always writes a brand new certificate **and** key
version (see [architecture.md](architecture.md)), there is never an old,
stale private key file to purge, unlike with file-based ACME clients.

`purge_key_on_mismatch` (per certificate, or the class-wide
`$acme_kvstore::purge_key_on_mismatch`, default `true`) decides what a
changed `key_type`/`key_size` does:

- `true`: it forces an immediate reissue with a new key, as described
  above.
- `false`: the existing certificate and key stay in use until the next
  regular renewal, which then uses the new key settings. This avoids an
  unplanned reissue (and a key change on every consumer) just because the
  key settings were changed.

Changed names always force an immediate reissue, since the existing
certificate no longer covers what was asked for.

An `acme_renewal` summary without `domains` (e.g. written by hand during
an import, see [migration.md](migration.md)) counts as "nothing to compare
against", not as drift.

## OCSP

OCSP is not supported: this module neither requests the OCSP Must-Staple
extension nor fetches or stores OCSP responses. OCSP is being phased out
in favour of certificate revocation lists - Let's Encrypt, for example,
rejects Must-Staple requests since May 2025 and shut its OCSP service down
in August 2025 (see Let's Encrypt's
[announcement](https://letsencrypt.org/2024/12/05/ending-ocsp)).

## `posthook_cmd`

An optional command (per certificate, or as the class-wide
`$acme_kvstore::posthook_cmd` default) run once a certificate has been
successfully issued/renewed **and** stored in the KV store. Failure is
logged but never fails the Puppet resource, since the certificate itself
has already been issued and stored successfully by that point.

This runs **only on the ACME worker** - never on the nodes the certificate
is distributed to - which does not necessarily serve the
certificate itself in this module's architecture (see
[architecture.md](architecture.md)) - so, unlike upstream puppet-acme's
`posthook_cmd`, reloading a local web server is usually not the right use
for it here unless the worker happens to also be that server. Typical uses
instead: notifying an external system, triggering a CI/CD pipeline, or
kicking off redistribution to consumer nodes (e.g. by triggering the
Puppet runs that apply their own `acme_kvstore::deploy` resources). To
reload a service on a consumer node when its certificate changes, use
`acme_kvstore::deploy`'s `notify_services` instead.

## `proxy`

An optional HTTP(S) proxy (per certificate, or as the class-wide
`$acme_kvstore::proxy` default), e.g. `'proxy.example.com:3128'` or a full
URL, used for all of acme.sh's outbound connections - to the ACME CA and
to any DNS API. acme.sh has no dedicated CLI flag for this; it is
implemented via the standard `HTTP_PROXY`/`HTTPS_PROXY` environment
variables, which its underlying curl/wget calls honour.

## `exec_timeout`

The maximum time in seconds (per certificate, or as the class-wide
`$acme_kvstore::exec_timeout` default, `300` by default) that any single
acme.sh invocation - including account registration and `posthook_cmd` -
may run before being terminated. Must be higher than the resolved
`dnssleep` (compilation fails otherwise). If exceeded, the process is sent `TERM`, given a short grace
period, then `KILL`ed, and the run fails cleanly rather than leaving
Puppet (or an orphaned acme.sh process) hanging indefinitely.
