<!-- markdownlint-disable-file MD041 -->
## Summary

<!-- What does this change, and why? Link the issue, if any. -->

## Type of change

- [ ] Bug fix
- [ ] New feature or parameter
- [ ] Documentation only
- [ ] Tests, CI or tooling

## Checklist

- [ ] `bundle exec rake test` and `bundle exec rake rubocop metadata_lint` pass
- [ ] Specs added or updated for the change
- [ ] For changes to the lookup code (`cert_lookup.rb`, `crypto.rb`, `kv_document.rb`):
      `bundle exec rake jruby:compat` passes
- [ ] `REFERENCE.md` regenerated if a public interface changed
- [ ] Docs in `docs/` and `CHANGELOG.md` updated
- [ ] The KV storage format is only extended, not changed (see `docs/cci-ui.md`)
- [ ] No secrets (keys, tokens, passwords, area secrets, EAB credentials)
      in code, tests or logs
