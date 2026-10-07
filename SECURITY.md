# Security policy

`acme_kvstore` stores certificates and **encrypted private keys** in Consul
or Redis and handles KV credentials, area secrets and ACME account data, so
security reports are welcome and taken seriously.

## Supported versions

The module is in development (0.1.x). Security fixes go into the latest
version on the `main` branch; there are no maintained older releases yet.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them
privately via GitHub's
[private vulnerability reporting](https://github.com/zaeh/zaeh-acme_kvstore/security/advisories/new)
(repository tab *Security* → *Report a vulnerability*).

Helpful details:

- the affected version or commit,
- the component (e.g. key encryption, KV credentials and ACLs, the worker
  running acme.sh, `acme_kvstore::deploy` on the Puppet server),
- steps to reproduce or a proof of concept,
- the impact you see.

Never include real private keys, tokens, passwords or area secrets in a
report; use test material instead.

Reports are handled on a best-effort basis: you get an acknowledgement, the
issue is assessed and fixed in a new version, and the fix is announced in a
GitHub security advisory, crediting you if you wish.

## Scope

In scope are the module's own code and documentation, in particular:

- AES-256-GCM encryption of private keys and its associated data
  (`lib/puppet_x/acme_kvstore/crypto.rb`),
- compare-and-set writes and KV access (`consul_client.rb`, `redis_client.rb`),
- the least-privilege design of credentials and file permissions
  (see [docs/security.md](docs/security.md)),
- how certificates and keys end up in compiled catalogues
  (see [docs/lookup_cert.md](docs/lookup_cert.md)).

Vulnerabilities in acme.sh, Consul, Redis, OpenVox/Puppet or Ruby itself
belong to those projects.
