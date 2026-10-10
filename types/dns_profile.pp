# @summary One entry of $acme_kvstore::dns_profiles: a DNS-01 challenge configuration.
#
# hook is the full acme.sh DNS API hook name ('dns_aws', 'dns_cf', ...);
# every hook shipped with acme.sh follows that naming. A hook acme.sh does
# not ship needs a script in $acme_kvstore::dnsapi_scripts. The CA
# certificates of the DNS API's TLS certificate go into ca_certificates
# (PEM) or ca_bundle (a file on the worker), not both. See docs/profiles.md.
type Acme_kvstore::Dns_profile = Struct[{
  hook                        => Pattern[/\Adns_[a-z0-9_]+\z/],
  Optional['env']             => Hash[String[1], Acme_kvstore::Secret],
  Optional['options']         => Hash[String[1], Variant[String[1], Integer, Sensitive[String[1]]]],
  Optional['challenge_alias'] => Stdlib::Fqdn,
  Optional['domain_alias']    => Stdlib::Fqdn,
  Optional['ca_certificates'] => Pattern[/-----BEGIN CERTIFICATE-----/],
  Optional['ca_bundle']       => Stdlib::Absolutepath,
}]
