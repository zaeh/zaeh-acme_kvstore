# @summary A domain name for a certificate: an FQDN or a wildcard name ('*.example.com').
type Acme_kvstore::Domain = Variant[
  Stdlib::Fqdn,
  Pattern[/\A\*\.(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])\.)*([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])\z/],
]
