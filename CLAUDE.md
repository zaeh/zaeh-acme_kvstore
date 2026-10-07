# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) and human contributors when
working with code in this repository.

> **Starting point, not a straitjacket.** This file's structure follows the baseline shipped by
> [puppetlabs/pdk-templates](https://github.com/puppetlabs/pdk-templates)' `moduleroot_init/CLAUDE.md.erb`,
> filled in with this module's own specifics. PDK adds a file like this when a module is first
> created and then leaves it alone - it is not re-synced on `pdk update`. It is yours to edit
> freely; keep it current as the module grows.
>
> This module also follows [Voxpupuli](https://voxpupuli.org/) testing conventions
> (`voxpupuli-test`, matching real modules such as
> [voxpupuli/puppet-archive](https://github.com/voxpupuli/puppet-archive)) rather than PDK's raw,
> separately-pinned gem list - see "Gemfile, gem sources and version pinning" below for how the two
> are reconciled here.

For generic Puppet/PDK workflow that *is* derivable from the files themselves (the full PDK command
reference, CI matrix mechanics, README badges), see the PDK docs and the README. The notes below are
the conventions Claude should treat as binding before touching code, plus the things that are not
obvious from a single file.

---

## Repository purpose

`acme_kvstore` manages ACME/Let's Encrypt certificates via `acme.sh`, modelled on the functionality
of [`puppet-acme`](https://github.com/markt-de/puppet-acme) - DNS/CA profiles, accounts, a CA
whitelist, DNS alias mode, SANs - but deliberately without exported resources or PuppetDB.
Certificates and private keys are instead stored directly in a Consul or Redis cluster, with writes
protected by compare-and-set. Read `docs/architecture.md` (including its two Mermaid diagrams) before
making any non-trivial change.

The storage format is **[CCI-UI](https://github.com/c8m6/cci-ui)'s** (`docs/consul-schema.md` there),
the planned UI for these certificates - see `docs/cci-ui.md`. Treat it as a binding contract: only
*add* fields CCI-UI keeps (like `acme_renewal`), never change the meaning of one of its fields, and
re-check CCI-UI's schema before changing a document format.

## Project layout

This is a **manifest + type/provider module** for Linux targets only (no Bolt tasks/plans, no
Windows support).

```text
manifests/                     # init.pp (global config), worker.pp, certificate.pp, deploy.pp
functions/                     # Puppet-language functions (unwrap_if_sensitive.pp)
types/                         # type aliases for structured parameters (Area, Consul_config, Redis_config,
                               # Dns_profile, Dnsapi_script, Ca_profile, Certid, Area_name, Secret, Dh_param_size) - use them, don't inline Structs
templates/                     # nsupdate_key.epp (TSIG key file for the dns_nsupdate hook)
files/dhparams/                # RFC 7919 ffdhe groups, generated with `openssl genpkey -genparam`
lib/puppet/type/               # acme_kvstore_certificate, acme_kvstore_cert_data
lib/puppet/provider/<type>/    # consul/redis providers per type
lib/puppet/functions/          # lookup_cert.rb, request_cert.rb (Ruby 4.x function API)
lib/puppet_x/acme_kvstore/     # the actual implementation - see below
data/ + hiera.yaml             # module Hiera: all non-undef class parameter defaults (data/common.yaml)
spec/                          # see Testing conventions below
docs/                          # architecture.md, profiles.md, security.md, consul.md, redis.md, lookup_cert.md, migration.md
metadata.json                  # module metadata, dependencies, supported OS matrix
```

`lib/puppet_x/acme_kvstore/` is where the real work lives: `crypto.rb` (AES-256-GCM), `kv_document.rb`,
`acmesh.rb` (all `acme.sh` invocation, with a `Process.spawn`-based timeout/dedicated-user wrapper),
`consul_client.rb`/`redis_client.rb` (compare-and-set KV access), `provider_common.rb` (shared
type/provider workflow), `cert_lookup.rb` (shared by `acme_kvstore_cert_data` and the `lookup_cert`
function). Manifests orchestrate and resolve configuration (profiles, defaults, validation); the Ruby
mechanics live in `lib/puppet_x/`. Don't move logic across that boundary without good reason.

Regenerate reference docs after a public interface change and commit them (CI fails when
`REFERENCE.md` is out of date): `bundle exec puppet strings generate --format markdown --out REFERENCE.md`.

---

## Common commands

```bash
bundle install                       # Install dependencies
bundle exec rake spec_prep           # Install fixture modules from .fixtures.yml (before specs)
bundle exec rake spec                # Run all unit tests
bundle exec rake lint                # puppet-lint
bundle exec rake rubocop             # Ruby style checks
bundle exec rake validate            # Syntax-check Ruby, Puppet manifests, and metadata
bundle exec rake metadata_lint       # Validate metadata.json
bundle exec rake test                # validate + lint + spec (voxpupuli-test's combined gate)
bundle exec rake jruby:compat        # lookup-side code under JRuby, as on the Puppet server (needs java)
JRUBY_COMPAT_VERSION=10.1.2.0 bundle exec rake jruby:compat   # OpenVox Server 9's JRuby (needs Java 21)

# Run a single spec file / example
bundle exec rspec spec/unit/puppet_x/acme_kvstore/acmesh_spec.rb
bundle exec rspec spec/unit/puppet/type/acme_kvstore_certificate_spec.rb:42   # by line number
bundle exec rspec spec/.../foo_spec.rb -e "some example description"          # by description
```

This module supports both **Puppet 8** (Ruby 3.2) and **Puppet 9** (Ruby 4.0). The unit tests run
on **OpenVox** (the community fork of Puppet): OpenVox 8 by default, OpenVox 9 via
`OPENVOX_GEM_VERSION` under Ruby 4.0 - see "Gemfile, gem sources and version pinning" below:

```bash
RBENV_VERSION=4.0.7 OPENVOX_GEM_VERSION='~> 9.0' bundle install
RBENV_VERSION=4.0.7 OPENVOX_GEM_VERSION='~> 9.0' bundle exec rake test
```

CI (`.github/workflows/ci.yml`, GitHub Actions) runs on pushes to `main` and on pull requests:
`rake validate lint rubocop metadata_lint` plus a warning-free, up-to-date `REFERENCE.md`, and
`rake spec` for OpenVox 8 / Ruby 3.2 and OpenVox 9 (`~> 9.0`) / Ruby 4.0, `rake acceptance`, and
`rake acceptance:e2e` for Ubuntu 24.04 and Rocky 9. Actions are pinned
to commit SHAs (Dependabot updates them weekly) and the token is read-only. `rake jruby:compat` and
PDK are deliberately not part of CI. Keep the matrix in step with the lanes above.

Acceptance tests (`spec/acceptance/`, not Litmus) run against real services in containers from
`spec/acceptance/compose.yml` - Consul with ACLs, Redis with ACL users, and Pebble (Let's Encrypt's
test CA, `PEBBLE_VA_ALWAYS_VALID`) - with the real providers, KV clients and acme.sh 3.0.9 (tarball,
SHA-256 pinned in `acceptance_helper.rb`): `bundle exec rake acceptance` (up, run, down; needs Docker
with compose). They are deliberately outside `rake spec`'s pattern (which includes `spec/integration/`).
Rules: pin image versions; credentials are generated per run or throwaway test values; each run
needs fresh containers (the helper creates ACL policies/users once). Pebble's default profile issues
6-day certificates, so the specs use `renew_before_days: 1`. Consul hides keys a token may not read
(reads return nothing), while Redis refuses them with `NOPERM`.

End-to-end tests (`spec/acceptance/e2e/`, compose profile `e2e`, `bundle exec rake acceptance:e2e`,
agent OS via `E2E_OS=ubuntu24.04|rocky9`) add an OpenVox 8 server (official image plus the `redis`
gem in its JRuby), an ACME worker and a consumer node (images built from the Vox Pupuli packages,
Pebble's TLS CA in the system trust store). `archive.ubuntu.com` can be extremely slow (minutes per
`apt-get update`), so the Ubuntu image takes its mirror from `E2E_UBUNTU_MIRROR`; CI uses
`azure.archive.ubuntu.com`, next to GitHub's runners. The fixture mounts refuse to start without
`spec_prep` instead of letting Docker create empty root-owned directories. The helper writes `site.pp` and Hiera data with the
per-run credentials into the server and runs `puppet agent --test`, checking issuance as a dedicated
user, deployment, renewal, `status` gating, idempotence (exit 0 on the second run) and that no run
warns. OpenVox 9 is deliberately not covered there (build time); its server JRuby is checked only by
`rake jruby:compat`. The `:system_tests` Gemfile group (`voxpupuli-acceptance`) stays unused.

---

## Testing conventions

### rspec-puppet (unit, for manifests)

- Every class/defined type should have `it { is_expected.to compile.with_all_deps }` across the
  supported OS matrix - see `spec/classes/init_spec.rb` and `spec/classes/worker_spec.rb`.
- Drive OS variants with `on_supported_os` (reads `metadata.json`) rather than hand-listing facts.
- Use `let(:params)` / `let(:pre_condition)` for class params and dependencies - see
  `spec/defines/certificate_spec.rb` for the established pattern of testing profile/area/worker
  resolution this way.
- Fixture modules are declared in `.fixtures.yml` and installed by `rake spec_prep`.

### Type/provider and Ruby-helper unit specs

- `spec/unit/puppet/type/` - attribute validation.
- `spec/unit/puppet/provider/<type>/` - CRUD behaviour. **Never invoke real `acme.sh`, Consul or
  Redis.** Stub `Open3.popen3` (see `spec/unit/puppet_x/acme_kvstore/acmesh_spec.rb`'s `FakeWaitThr`/
  `stub_popen3` helpers) and the KV clients (`instance_double(PuppetX::AcmeKvstore::ConsulClient)`
  etc.), and assert the *commands generated* / *writes composed*, not real side effects.
- `spec/unit/puppet_x/acme_kvstore/` - the Ruby helpers, tested directly (they are plain Ruby
  classes, loadable without a full Puppet catalogue via the `$LOAD_PATH` addition in
  `spec/spec_helper_local.rb`).
- Mocking framework: **rspec-mocks** (`allow`, `expect`, `receive`) throughout - do not introduce
  Mocha.
- Prefer `expect(x).to receive(:y).with(...)` (a hard, argument-verifying expectation with a
  stubbed return value) over the `allow` + `have_received` spy pattern for anything where the
  exact arguments matter - it catches wrong-arguments regressions that a looser spy would miss,
  and several real bugs during this module's development were only caught this way (e.g. the
  rspec-puppet catalogue cache issue in `spec/defines/deploy_spec.rb`, where a stray shared title
  made an example's own `expect` never fire at all). `RSpec/StubbedMock`/`RSpec/MessageSpies` are
  disabled in `.rubocop.yml` for exactly this reason - don't re-enable them and rewrite this
  pattern module-wide without a way to actually re-run the suite and confirm nothing regressed.

### Spec helpers

- `spec/spec_helper.rb` mirrors the Voxpupuli-managed template (`require 'voxpupuli/test/spec_helper'`)
  and should be treated as **do not hand-edit** - a future resync could overwrite module-specific
  additions placed there.
- Put anything module-specific in `spec/spec_helper_local.rb` (already used here for the `lib/`
  `$LOAD_PATH` addition) - safe to edit freely, and it is loaded automatically.

---

## Ruby code style

- Style is enforced by `.rubocop.yml`, which inherits `voxpupuli-test`'s bundled RuboCop
  configuration via `inherit_gem`. Run `bundle exec rake rubocop` (or `bundle exec rubocop -A` to
  autocorrect) - always under `bundle exec` so you get the module's pinned RuboCop version.
- `TargetRubyVersion: 3.2` in `.rubocop.yml` is the **floor** the code must run on (Puppet 8), not
  the ceiling - the code must still run correctly under Ruby 4.0 (Puppet 9). Do not use Ruby
  4-only syntax.
- `# frozen_string_literal: true` at the top of every `.rb` file; single-quote strings unless they
  need interpolation, contain an apostrophe, or need a `\n`/`\t` escape.
- The few module-specific exceptions to the inherited cop set are in `.rubocop.yml`, each with a
  one-line reason. `Gemfile` and `Rakefile` are added to `AllCops: Include` (Voxpupuli's config only
  covers `**/*.rb`), so `rake rubocop` checks them like an editor does.
- Helper classes live in the `PuppetX::AcmeKvstore` namespace (`PuppetX` is defined by Puppet's own
  `lib/puppet_x.rb`, loaded with `require 'puppet_x'`), written compactly as
  `module PuppetX::AcmeKvstore`, like Voxpupuli modules such as puppet-consul.
- Keep comments short: say *why*, not what the code already shows; details belong in `docs/`.
- `.rubocop_todo.yml` is currently empty (no grandfathered offenses); regenerate with
  `bundle exec rubocop --auto-gen-config` only if a gem update introduces new offenses not worth
  fixing immediately, and prefer a scoped disable over leaving a broad exemption there for long.

---

## Gemfile, gem sources and version pinning

- `source ENV['GEM_SOURCE'] || 'https://rubygems.org'` - override with an internal mirror if needed
  (matches both the PDK and Voxpupuli convention).
- `gem 'openvox', <OPENVOX_GEM_VERSION, if set and non-empty, else '~> 8.0'>` - the runtime gem is **OpenVox**, not
  `puppet`: voxpupuli-test >= 11 (via `puppet-syntax`/`openvox-strings`) depends on `openvox`, and
  adding the `puppet` gem as well would install two gems shipping the same `lib/puppet` files. Do
  not re-add `gem 'puppet'`.
- OpenVox 9 is final since 9.0.0 (2026-10-02); the OpenVox 9 lane uses `OPENVOX_GEM_VERSION='~> 9.0'`
  under Ruby 4.0. It needs `puppet-syntax` >= 7.3 (earlier versions require `openvox < 9`).
- `openvox-strings` is **pinned exactly** in the `Gemfile`: `REFERENCE.md` is committed and checked by
  CI (and by voxpupuli-test's `rake validate`), and CI resolves without `Gemfile.lock`, so an
  unpinned strings release could change the format and break CI. To update: raise the pin,
  `bundle update --conservative openvox-strings`, regenerate `REFERENCE.md`, commit both together.
- `:test` holds `voxpupuli-test` (bundles puppet_fixtures, rspec-puppet, rspec-puppet-facts,
  openvox-strings and the RuboCop config), plus `metadata-json-lint`.
- `:system_tests` holds `voxpupuli-acceptance` (Litmus-based); `:release` holds `voxpupuli-release`.
- In code and specs, depend on the public Puppet API (`Puppet::Type`, `Puppet::Provider`,
  `Puppet::Functions`), never on a specific gem name, so the module works whichever runtime gem is
  resolved.

---

## Type & provider DSL gotchas specific to this module

- **`exists?` conflates several concerns on purpose**: plain existence (no meta document: issue
  at once), ownership (a meta document without `acme_renewal` was written by another tool: warn,
  never overwrite), configuration drift (SAN/key-type/key-size mismatch: reissue at once) and
  renewal-due timing (only inside `renew_schedule`'s `range`/`weekday` window) - but only when
  `resource[:ensure] == :present`. For `ensure => absent`, `exists?` must ignore timing/drift and
  reflect whether `acme_renewal` exists, or `destroy` never gets called for a soon-expiring
  certificate. This was a real bug caught during development; re-check this specific interaction
  if you touch `exists?`.
- **`status` controls distribution only** (`acme_kvstore::deploy`: `active` writes files,
  `delete` removes them, anything else leaves them alone; `CertLookup` returns data only for
  `active`). The worker never reads it for decisions and never changes it after first issuance
  (`create` keeps the existing value). Do not reintroduce status checks into `exists?`.
- **`renew_schedule` is a type parameter, not the `schedule` metaparameter**: the metaparameter
  would also delay first issuance and drift reissues, and on the defined type it would be
  inherited by every contained resource.
- **Never write a meta document directly** with `write_atomic`; always go through
  `kv_client.transactional_update(prefix, watch_suffix) { |current| ... }`, which implements
  compare-and-set per backend (Consul `cas` on the meta key's `ModifyIndex`, or `check-index`/
  `check-not-exists` when the meta key itself is not written; Redis `WATCH`/`MULTI`/`EXEC`) and
  raises `CasConflictError` on a concurrent write. Let that propagate - Puppet fails the resource
  for this run and retries cleanly next time.
- **A custom type's live property cannot feed another resource's parameter** within one catalogue
  compilation - this is why `acme_kvstore::deploy` (which writes `file` resources) is built on the
  compile-time `acme_kvstore::lookup_cert` function, not on the apply-time `acme_kvstore_cert_data`
  type. Do not try to "simplify" this by wiring the type into a `file` resource's `content`.
- **Every reissue writes a brand-new certificate *and* key version** - there is never a stale local
  key file to separately purge the way file-based ACME clients need to. `purge_key_on_mismatch`
  therefore only decides whether a `key_type`/`key_size` change forces that reissue *now* (true,
  the default) or waits for the next regular renewal; a changed primary domain or set of names
  always does.
- **`domain` + `subject_alt_names`** are the user-facing parameters; `acme_kvstore::certificate`
  turns them into the type's internal `domains` list (primary domain first). The
  `Acme_kvstore::Certificate_params` type must list exactly the defined type's parameters (except
  `certid`); a spec enforces this.
- **One KV read per worker run**: `ProviderCommon#state` reads the meta document (with its CAS
  token) once; `exists?` decides from its `acme_renewal` summary, and every write
  passes that read as `expected:` to `transactional_update` (Consul: its ModifyIndex, no second
  read; Redis: WATCH plus comparison with it). Keep the `acme_renewal` summary in sync whenever the
  active version changes; there is no fallback read of the certificate document.
- **Each area has its own KV credentials**: `consul_token` with Consul, `redis_username` +
  `redis_password` with Redis (the worker's, read/write); global credentials in `$consul`/`$redis`
  are rejected. `acme_kvstore::deploy` (Hiera path) uses only the area's separate read-only ones -
  `consul_read_token`, `redis_read_username`/`redis_read_password` - and never falls back to the
  worker's.
- **Consul reads use the txn verb `get-or-empty`, never `get`**: `get` rolls back the whole
  transaction (HTTP 409) when a key is missing, which is the normal case on first issuance and
  for optional documents.
- **Every KV key lives below `<prefix>/<area>/`** (`certids/<certid>`, `certs/`, `keys/`),
  so area ACL tokens can be limited to their own area. Build keys only via
  `PuppetX::AcmeKvstore::KvDocument`'s `*_path` helpers, never by hand.
- **CCI-UI compatibility details**: certificate documents hold exactly one certificate and always
  `pem`, `tags` (also `[]`), `has_key`, `created_at`, `client` - CCI-UI's indexer fails without
  them. Versions (`certs/`, `keys/`) are create-only: `transactional_update` writes every key except
  the watched meta key with Consul `cas` index 0 / Redis `WATCH` + `EXISTS`. Key envelopes use the
  AES-GCM associated data `cci:<area>:<certid>/<version>` (`Crypto.aad`). Chain certificates are
  entries of their own with certid = `<cn>_<YYYY-MM-DD>` (`KvDocument.issuer_certid`; an occupied
  name gets `_<fp8>`), written before the leaf (only with
  `store_issuers`, the default) and never changed once they exist; chains are only built on request
  (`include_chain`, default false; `deploy` asks only for chain/fullchain/combined files), and a
  failed search must degrade to `chain_missing`/`chain_error`, never fail the compilation; readers build chains from `acme_renewal.issuers`, or by CCI-UI's search
  (subject/issuer, `CA:TRUE`, signature). Area names, certids and `kv_client` follow CCI-UI's rules.
- **`lookup_cert`/`deploy` run on the Puppet/OpenVox server, under JRuby** (OpenVox Server 8:
  JRuby 9.4.15.0, 9: JRuby 10.1.2.0), not MRI - the specs only cover MRI. After touching
  `cert_lookup.rb`, `crypto.rb` or `kv_document.rb`, run `bundle exec rake jruby:compat`
  (`rakelib/`; downloads a SHA-256-verified jruby-complete jar to `vendor/jruby/`). Only use
  OpenSSL features jruby-openssl supports; that is why the DH groups are static files and PEM
  bundles are split with a regex. Mind the differences: `X509::Name#to_a` returns raw bytes under
  MRI but already decoded UTF-8 under JRuby (see `KvDocument.name_text`). With Redis, the server needs `puppetserver gem install redis`.
- **`posthook_cmd` runs on the ACME worker only**, never on consumer nodes; consumers react to
  changed files via `acme_kvstore::deploy`'s `notify_services`.
- **`acme_kvstore::deploy` must stay independent** of the `acme_kvstore` class, the worker and
  `acme_kvstore::certificates`: it is called by other code, fetches on the compiler and writes on
  any node. Never add `include acme_kvstore` there or read `$acme_kvstore::*` variables; take
  parameters and fall back to `lookup('acme_kvstore::...')` in the body (puppet-lint forbids
  `lookup()` as a parameter default).
- **Module-internal Ruby requires use `require_relative`** (`lib/puppet/...` -> `puppet_x/...`): a
  Puppet server does not put module `lib/` directories on `$LOAD_PATH`, so `require 'puppet_x/...'`
  works on agents (pluginsync libdir) and in specs but fails to compile there. Only Puppet's own
  `require 'puppet_x'` stays a plain require. The E2E tests catch a regression.
- **The `redis` gem may arrive mid-run**: `acme_kvstore::worker` installs it with `puppet_gem`, so
  `RedisClient.load_gem` retries the `require` (after `Gem.clear_paths`) instead of trusting the
  load-time attempt.
- **`run_as_user`/`run_as_group`** are `Process.spawn` options, not shell `sudo`/`su` wrapping - they
  affect only the spawned `acme.sh`/`posthook_cmd` child, never the Puppet agent process itself.
- **Never guess an `acme.sh` CLI flag or environment-variable convention.** Every flag currently in
  `acmesh.rb` (`--challenge-alias`, `--domain-alias`, `--eab-kid`, `--eab-hmac-key`,
  `--register-account`, the `HTTP(S)_PROXY` convention) was individually verified against
  acme.sh's own documentation before being added; `--dnssleep` (which also disables acme.sh's own
  public DNS polling), `--log`, `--log-level` (1 or 2 only), `--webroot` and `--force` (which `--issue`
  needs: without it acme.sh skips with exit 2 while its own renewal date is ahead) were verified against
  the acme.sh 3.0.9 source, as was `dns_nsupdate` expecting `NSUPDATE_KEY` to be a key *file path*,
  and `_findHook` looking in `<home>/dnsapi/<hook>.sh` first, then sourcing it (read access
  suffices) and calling `<hook>_add`/`<hook>_rm` (basis of `acme_kvstore::dnsapi_scripts`).
  Verify before adding another, and say so.
- **Puppet parameter default ordering**: a parameter's default expression may only reference
  *earlier* parameters in the same list - this caused a real bug here before
  (`acme_kvstore::worker`'s `home` depending on `user`, which had to move earlier).
- **Class parameter defaults live in `data/common.yaml`**, not in the manifests. Only `undef`
  defaults and `acme_kvstore::worker::home` (derived from `user`) stay in code; puppet-lint then
  requires those parameters to come after all parameters without a default. A new class parameter
  needs its default added to `data/common.yaml`, or the class stops compiling.
- Use `$facts['networking']['fqdn']` and similar structured facts; never a legacy flat fact or
  `$::fact` top-scope syntax.

---

## metadata.json conventions

- `metadata.json` is the source of truth for the supported OS matrix (RedHat, Rocky, Debian, Ubuntu); `on_supported_os` in specs derives from it. Update it when adding/removing platform support.
- Bump `version` per [SemVer](https://semver.org): breaking change -> major, feature -> minor, fix -> patch.
- `requirements` allows Puppet 8 and 9 (`>= 8.0.0 < 10.0.0`); keep code and specs in step with both lanes.
- `license` is `AGPL-3.0-only` (SPDX), matching the verbatim GNU text in `LICENSE`.
- The `pdk-version`/`template-url`/`template-ref` fields were written by a real `pdk convert`
  (PDK 3.8.0). Only ever let `pdk convert`/`pdk update` change them; never hand-edit them.
- The Voxpupuli-based files (`Gemfile`, `Rakefile`, `.rubocop.yml`, `.gitignore`,
  `spec/spec_helper.rb`, `spec/default_facts.yml`) are marked `unmanaged: true` in `.sync.yml`, so
  `pdk update` does not replace them with PDK's template versions. Keep it that way.
- PDK works with the OpenVox-based Gemfile: it still reports "Using Puppet 8.20.0" (its bundled
  Perforce Puppet), but since the Gemfile has no `puppet` gem, OpenVox is what actually runs.
- A packaged PDK resolves gems offline only: run `pdk bundle install` once so the Voxpupuli gems land
  in `~/.pdk/cache`. PDK and plain Bundler share the (gitignored) `Gemfile.lock`, and PDK may pin
  gem versions that exist only in its local cache. If `bundle exec` then reports missing gems, run
  `bundle update --conservative <those gems>`. The `spec_prep`/`spec_clean`/`spec_standalone`/
  `spec_list_json` aliases in the Rakefile exist only so `pdk test unit` works with voxpupuli-test
  >= 10.

---

## Linux specifics

- **Package providers**: `apt`/`dpkg` (Debian/Ubuntu), `yum`/`dnf`/`rpm` (RedHat family). The only
  package this module manages directly is `git` (for `install_method => 'git'` in
  `acme_kvstore::worker`) and the `redis` Ruby gem via `puppet_gem`.
- **Service management**: not applicable - this module manages certificates, not a running service
  on the worker.
- **Paths**: acme.sh installs under `/root/.acme.sh` by default, or `/home/<user>/.acme.sh` once
  `acme_kvstore::worker`'s `user` is set to a non-root account.

---

## Review policy (outcome-based)

- **A clean compile across the supported OS matrix and idempotent Puppet resources are mandatory.**
- New behaviour ships with the unit test that proves it (mocked at the `Open3`/KV-client boundary,
  per "Testing conventions" above).
- Don't reduce test coverage of the CAS/drift-detection/status-gating logic to make a change land faster.
- Keep changes scoped; flag unrelated cleanup separately.

---

## Project rules

- At the start of a session, review the repository structure and the relevant files under `docs/`
  before making a change.
- Always read the files relevant to the task before suggesting or making a change.
- Never merge a pull request.
- Never work directly on `main` or `master`.
- Never push a branch without explicit instruction.
- Never delete a file without permission - this applies even after a blanket "yes to all".
- Never output, log, save, or hardcode security-sensitive values - passwords, tokens, API keys,
  private keys, area secrets, EAB credentials, or any other kind of secret. Do not write them to
  files, commit messages, or responses.
- Never claim a file was written or a tool was run without actually doing so in the same turn - say
  so plainly if something was only described but not yet saved.

> These are guidance, not enforcement. For anything that must hold every run (secret hygiene, no
> direct pushes to `main`), back it with a runtime hook in the repo's `.claude/` settings if one
> exists - prose alone can be treated as a suggestion and skipped.
