# CCI-UI

[CCI-UI](https://github.com/c8m6/cci-ui) is a web UI for X.509
certificates stored in Consul. Its storage contract
([`docs/consul-schema.md`](https://github.com/c8m6/cci-ui/blob/main/docs/consul-schema.md))
is the format this module writes: certificates issued by `acme_kvstore`
appear in CCI-UI like imported ones, and certificates managed in CCI-UI can
be delivered with `acme_kvstore::deploy`. This module only **adds** fields
CCI-UI keeps; it never changes the meaning of one of CCI-UI's fields.

## Configuration

```yaml
acme_kvstore::prefix: 'cci'           # CCI-UI's default prefix (CONSUL_PREFIX)
acme_kvstore::backend: 'consul'       # CCI-UI only reads Consul
acme_kvstore::areas:
  zone_a:                             # an area configured in CCI_AREAS
    secret: ENC[PKCS7,...]            # the same 32-byte secret, Base64 (CCI_AREA_KEYS / ZONE_A_KEY)
    consul_token: ENC[PKCS7,...]
    consul_read_token: ENC[PKCS7,...]
```

- **Area names** follow CCI-UI's rule `[a-z][a-z0-9_]{0,47}` (no `-`);
  certids have at most 120 characters. The module's types enforce both.
- **`kv_client`** stays `puppet` (the default): CCI-UI requires automated
  writers to identify as `puppet` and rejects client names referring to
  `acme`.
- **`kv_updated_by`** (default: the worker's FQDN) is the actor in
  `updated_by`/`created_by`; CCI-UI suggests a form such as
  `puppet:node.example.org`. At most 255 characters, never a secret.
- **Redis**: the module works with Redis too, but CCI-UI does not show
  those certificates.

## What the module writes

| Key | Content |
| --- | --- |
| `certids/<certid>` | CCI-UI's meta document, plus `acme_renewal` (see [architecture.md](architecture.md#meta-document-prefixareacertidscertid)) |
| `certs/<certid>/<version>` | `pem` (exactly one certificate), `tags` (always, possibly `[]`), `has_key`, `created_at`, `client`, `created_by` |
| `keys/<certid>/<version>` | CCI-UI's envelope: AES-256-GCM, associated data `cci:<area>:<certid>/<version>` |
| `certids/<cn>_<YYYY-MM-DD>`, `certs/<cn>_<YYYY-MM-DD>/1` | each chain certificate as its own entry without a key ([issuer entries](architecture.md#issuer-entries)) |

Versions are only created, never overwritten, and every meta write is a
compare-and-set on its ModifyIndex - the same rules CCI-UI follows, so
both can write to the same area.

## Working in CCI-UI

- **Status**: `active`, `norollout` and `delete` mean what CCI-UI
  describes, and `acme_kvstore::deploy` implements it: write, leave alone,
  remove. The status never affects issuance or renewal.
- **Archiving** (`archived: true`, `status: delete`): the worker no longer
  renews the certificate, even if it is still configured in
  `acme_kvstore::certificates`.
- **Activating another version or uploading one** for a certificate this
  module manages: the worker then checks that active certificate itself.
  It renews it when it is due, and reissues when its names or key no
  longer match the configuration - the configuration wins.
- **Root certificates**: CAs such as Let's Encrypt do not deliver their root
  with the chain. If an application needs it (`acme_kvstore::deploy`'s
  `chain_include_root`), import the root in CCI-UI once per area.
- **Intermediates maintained only in CCI-UI**: set
  `acme_kvstore::store_issuers: false`; the worker then stores no chain
  certificates, and readers find the ones imported in CCI-UI.
- **Chain certificates** are named `<cn>_<YYYY-MM-DD>` (CN and expiry date,
  see [architecture.md](architecture.md#issuer-entries)). CCI-UI should use
  the same rule as the default certid when it imports a bundle - instead of
  the SHA-256 fingerprint, which it then only shows as a computed value -
  so both name the same CA certificate the same way. Existing entries are
  never changed; readers find chain certificates for any certificate,
  including ones not issued by this module.
- **Tags** set in CCI-UI are kept with the version; new versions issued by
  the worker get the `tags` of `acme_kvstore::certificate`.

## Permissions

- Worker (`consul_token`): read/write on `<prefix>/<area>/` (it creates
  certificate, key and issuer entries).
- `acme_kvstore::deploy` (`consul_read_token`): read on `<prefix>/<area>/`;
  `keys/` only if keys are deployed. Consul's `read` includes the recursive
  read used to find issuers of certificates not issued by this module.
