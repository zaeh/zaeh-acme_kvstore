# @summary One entry of $acme_kvstore::certificates: the parameters of acme_kvstore::certificate.
#
# The key of the entry is the certid. Only domain is required; everything
# else defaults as in acme_kvstore::certificate. Keep in sync with that
# defined type (spec/type_aliases/acme_kvstore__certificate_params_spec.rb checks).
type Acme_kvstore::Certificate_params = Struct[{
  domain                            => Acme_kvstore::Domain,
  Optional['subject_alt_names']     => Array[Acme_kvstore::Domain],
  Optional['area']                  => String[1],
  Optional['worker']                => Stdlib::Fqdn,
  Optional['backend']               => Enum['consul', 'redis'],
  Optional['key_type']              => Enum['rsa', 'ec'],
  Optional['key_size']              => Integer[256],
  Optional['renew_before_days']     => Integer[1],
  Optional['purge_key_on_mismatch'] => Boolean,
  Optional['store_issuers']         => Boolean,
  Optional['tags']                  => Array[String[1]],
  Optional['challenge_type']        => Enum['http-01', 'dns-01'],
  Optional['use_dns_profile']       => String[1],
  Optional['dns_provider']          => Pattern[/\Adns_[a-z0-9_]+\z/],
  Optional['dns_env']               => Hash[String[1], String[1]],
  Optional['challenge_alias']       => Stdlib::Fqdn,
  Optional['domain_alias']          => Stdlib::Fqdn,
  Optional['dnssleep']              => Integer[1],
  Optional['use_ca_profile']        => String[1],
  Optional['posthook_cmd']          => String[1],
  Optional['proxy']                 => String[1],
  Optional['exec_timeout']          => Integer[1],
  Optional['renew_schedule']        => String[1],
}]
