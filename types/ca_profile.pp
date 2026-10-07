# @summary One entry of $acme_kvstore::ca_profiles: an ACME CA with the account data needed to use it.
#
# directory_url is omitted for acme.sh's built-in CA aliases (the profile
# name is used instead). See docs/profiles.md.
type Acme_kvstore::Ca_profile = Struct[{
  Optional['directory_url'] => Stdlib::HTTPSUrl,
  Optional['account_email'] => String[1],
  Optional['eab_kid']       => Acme_kvstore::Secret,
  Optional['eab_hmac_key']  => Acme_kvstore::Secret,
}]
