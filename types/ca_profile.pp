# @summary One entry of $acme_kvstore::ca_profiles: an ACME CA with the account data needed to use it.
#
# directory_url is omitted for acme.sh's built-in CA aliases (the profile
# name is used instead). The CA certificates acme.sh trusts for this CA
# (instead of the system trust store) are given either as PEM text
# (ca_certificates, written to the worker) or as a file already on the
# worker (ca_bundle), not both. valid_days/acme_profile are defaults for the
# certificate lifetime; min_valid_days/max_valid_days declare that the CA
# accepts a requested lifetime (notAfter) and its limits. See docs/profiles.md.
type Acme_kvstore::Ca_profile = Struct[{
  Optional['directory_url']   => Stdlib::HTTPSUrl,
  Optional['account_email']   => String[1],
  Optional['eab_kid']         => Acme_kvstore::Secret,
  Optional['eab_hmac_key']    => Acme_kvstore::Secret,
  Optional['ca_certificates'] => Pattern[/-----BEGIN CERTIFICATE-----/],
  Optional['ca_bundle']       => Stdlib::Absolutepath,
  Optional['valid_days']      => Integer[1],
  Optional['min_valid_days']  => Integer[1],
  Optional['max_valid_days']  => Integer[1],
  Optional['acme_profile']    => String[1],
}]
