# Contributing

Contributions are welcome - bug reports, documentation and code. For
security problems, please follow [SECURITY.md](SECURITY.md) instead of
opening an issue. Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- Read [docs/architecture.md](docs/architecture.md); the storage format is
  shared with [CCI-UI](docs/cci-ui.md) and may only be **extended**, never
  changed in meaning.
- [CLAUDE.md](CLAUDE.md) collects the module's conventions and pitfalls
  (for people and AI assistants alike) - the binding rules for code, tests
  and the type/provider design are there.
- Keep changes focused; open an issue first for larger changes. Issues use
  forms for bug reports and feature requests, and pull requests come with a
  checklist - please fill them in.

## Development setup

```bash
bundle install
bundle exec rake spec_prep      # fixture modules from .fixtures.yml
```

## Tests

Every change ships with the tests that prove it. Before opening a pull
request, run:

```bash
bundle exec rake test                     # syntax, puppet-lint, all specs
bundle exec rake rubocop metadata_lint
bundle exec puppet strings generate --format markdown --out REFERENCE.md   # after interface changes
```

The module supports Puppet/OpenVox 8 (Ruby 3.2) and 9 (Ruby 4.0):

```bash
OPENVOX_GEM_VERSION='~> 9.0' bundle install          # under Ruby 4.0
OPENVOX_GEM_VERSION='~> 9.0' bundle exec rake test
```

`acme_kvstore::lookup_cert` and `acme_kvstore::deploy` run on the Puppet
server under JRuby. After changing `lib/puppet_x/acme_kvstore/cert_lookup.rb`,
`crypto.rb` or `kv_document.rb`, also run (needs `java`; JRuby 10 needs
Java 21):

```bash
bundle exec rake jruby:compat
JRUBY_COMPAT_VERSION=10.1.2.0 bundle exec rake jruby:compat
```

Acceptance tests run real Consul, Redis and acme.sh against Pebble (Let's
Encrypt's test CA) in containers; they need Docker with the compose plugin:

```bash
bundle exec rake acceptance       # fresh containers, all acceptance specs, cleanup
```

End-to-end tests compile the module on a real OpenVox 8 server and run the
agent on an ACME worker and a consumer node (container images are built
locally on the first run):

```bash
bundle exec rake acceptance:e2e                  # agents on Ubuntu 24.04
E2E_OS=rocky9 bundle exec rake acceptance:e2e    # agents on Rocky 9
```

If `archive.ubuntu.com` is slow for you, use another Ubuntu mirror, e.g.
`E2E_UBUNTU_MIRROR=http://azure.archive.ubuntu.com/ubuntu/`.

The CI (GitHub Actions) runs the static checks, the specs for both OpenVox
versions, the acceptance tests and the end-to-end tests on every pull
request.

`openvox-strings` is pinned exactly in the `Gemfile`, because `REFERENCE.md`
is committed and checked by CI. To update it, raise the pin, regenerate
`REFERENCE.md` and commit both together.

## Guidelines

- Never commit real secrets - private keys, tokens, passwords, area
  secrets, EAB credentials - not even in tests.
- Unit tests never contact acme.sh, Consul or Redis; mock at the
  `Open3`/KV-client boundary (see CLAUDE.md, "Testing conventions").
- Ruby style follows `.rubocop.yml`; Puppet code follows puppet-lint.
- Document new parameters in the code (`@param`) and in `docs/`, and add a
  line to [CHANGELOG.md](CHANGELOG.md).

## Licence

By contributing, you agree that your contribution is licensed under the
[GNU Affero General Public License v3.0 only](LICENSE), like the module.
