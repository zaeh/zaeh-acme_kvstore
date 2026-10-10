# Mock PKI - test material, never for production

Used by `acme_kvstore::deploy`'s mock mode and the function
`acme_kvstore::mock_cert` (see docs/lookup_cert.md#mock-mode): a root
(valid until 2099-12-31), an intermediate (until 2099-12-30) with its key,
and one leaf key. The private keys are public. The root key was not kept.

Regenerate with `bundle exec rake mock:pki` - this changes every mock
certificate, so do it only on purpose.
