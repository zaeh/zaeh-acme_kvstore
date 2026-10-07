# @summary Global configuration of acme_kvstore: backend, areas, profiles and defaults.
#
# Requests no certificates itself, except those in $certificates. Defaults
# of most parameters: data/common.yaml. See docs/configuration.md.
#
# @param prefix KV path prefix; all keys live below <prefix>/<area>/.
# @param backend Default KV backend.
# @param workers Known worker hosts (informational only).
# @param areas
#   Area name => secret and the area's own KV credentials (consul_token
#   with Consul, redis_username/redis_password with Redis).
# @param consul Consul connection details (no token, see $areas). See docs/consul.md.
# @param redis Redis connection details (no username/password, see $areas). See docs/redis.md.
# @param dns_profiles DNS-01 configurations (hook, credentials, options, alias mode). See docs/profiles.md.
# @param dnsapi_scripts
#   Hook name (dns_...) => custom acme.sh DNS API script, installed on the
#   workers; DNS profiles use it via their hook. See docs/profiles.md.
# @param ca_profiles CAs with their account data; includes 'letsencrypt' and 'letsencrypt_test'. See docs/profiles.md.
# @param default_ca_profile CA profile used when a certificate names none; must be whitelisted.
# @param ca_whitelist CA profiles certificates may actually use.
# @param exec_timeout Default maximum run time of acme.sh in seconds; must exceed $dnssleep.
# @param renew_before_days Default: renew when fewer days than this remain.
# @param purge_key_on_mismatch Default: whether a changed key_type/key_size forces an immediate reissue.
# @param store_issuers Default: whether the chain certificates acme.sh returns are stored as issuer entries.
# @param dnssleep Default seconds to wait for DNS-01 records (acme.sh --dnssleep).
# @param dh_param_size Default size of the DH parameters written by acme_kvstore::deploy.
# @param kv_client Value of the 'client' field in the KV documents the workers write.
# @param certificates
#   certid => acme_kvstore::certificate parameters, e.g. from Hiera. Each
#   takes effect only on its worker. See docs/configuration.md#certificates-in-hiera.
# @param default_worker Default worker FQDN.
# @param default_area Default area.
# @param default_dns_profile DNS profile used when a certificate names none.
# @param posthook_cmd Default command run on the worker after issuing.
# @param proxy Default HTTP(S) proxy for acme.sh.
# @param renew_schedule
#   Default name of a 'schedule' resource (built-in or your own) whose
#   range/weekday limit when due renewals run. undef: any time.
# @param kv_updated_by
#   Value of the 'updated_by'/'created_by' fields in the KV documents;
#   undef: the FQDN of the writing worker.
class acme_kvstore (
  String[1] $prefix,
  Enum['consul', 'redis'] $backend,
  Hash[Stdlib::Fqdn, Hash] $workers,
  Hash[Acme_kvstore::Area_name, Acme_kvstore::Area] $areas,
  Acme_kvstore::Consul_config $consul,
  Acme_kvstore::Redis_config $redis,
  Hash[String[1], Acme_kvstore::Dns_profile] $dns_profiles,
  Hash[Pattern[/\Adns_[a-z0-9_]+\z/], Acme_kvstore::Dnsapi_script] $dnsapi_scripts,
  Hash[String[1], Acme_kvstore::Ca_profile] $ca_profiles,
  String[1] $default_ca_profile,
  Array[String[1]] $ca_whitelist,
  Integer[1] $exec_timeout,
  Integer[1] $renew_before_days,
  Boolean $purge_key_on_mismatch,
  Boolean $store_issuers,
  Integer[1] $dnssleep,
  Acme_kvstore::Dh_param_size $dh_param_size,
  Pattern[/\A[a-zA-Z0-9_.-]{1,120}\z/] $kv_client,
  Hash[Acme_kvstore::Certid, Acme_kvstore::Certificate_params] $certificates,
  Optional[Stdlib::Fqdn] $default_worker = undef,
  Optional[Acme_kvstore::Area_name] $default_area = undef,
  Optional[String[1]] $default_dns_profile = undef,
  Optional[String[1]] $posthook_cmd = undef,
  Optional[String[1]] $proxy = undef,
  Optional[String[1]] $renew_schedule = undef,
  Optional[String[1, 255]] $kv_updated_by = undef,
) {
  if $backend == 'consul' and empty($consul) {
    fail('acme_kvstore: $backend = \'consul\', but $consul has not been configured')
  }
  # CCI-UI rejects client names referring to ACME; automated writers are 'puppet'.
  if $kv_client =~ /(?i:(\A|[_.-])acme([_.-]|\z))/ {
    fail("acme_kvstore: \$kv_client '${kv_client}' is not accepted by CCI-UI (it refers to 'acme'); use e.g. 'puppet'")
  }
  # Each area needs its own credentials (global ones are not possible).
  if $backend == 'redis' {
    $areas_without_redis_user = $areas.filter |$area_name, $area_config| {
      $area_config['redis_username'] =~ Undef or $area_config['redis_password'] =~ Undef
    }.keys
    unless empty($areas_without_redis_user) {
      fail("acme_kvstore: with the Redis backend every area needs its own 'redis_username' and 'redis_password'; missing for: ${areas_without_redis_user.join(', ')}")
    }
  }
  if $backend == 'consul' {
    $areas_without_consul_token = $areas.filter |$area_name, $area_config| { $area_config['consul_token'] =~ Undef }.keys
    unless empty($areas_without_consul_token) {
      fail("acme_kvstore: with the Consul backend every area needs its own 'consul_token'; missing for: ${areas_without_consul_token.join(', ')}")
    }
  }
  if $backend == 'redis' and empty($redis) {
    fail('acme_kvstore: $backend = \'redis\', but $redis has not been configured')
  }
  if empty($areas) {
    fail('acme_kvstore: at least one area must be configured under $areas')
  }
  if $default_area and !$areas[$default_area] {
    fail("acme_kvstore: \$default_area '${default_area}' is not a key in \$areas")
  }

  unless $default_ca_profile in $ca_whitelist {
    fail("acme_kvstore: \$default_ca_profile '${default_ca_profile}' is not in \$ca_whitelist")
  }
  unless $ca_profiles[$default_ca_profile] {
    fail("acme_kvstore: \$default_ca_profile '${default_ca_profile}' is not a key in \$ca_profiles")
  }

  # A whitelisted CA without profile could never be used - fail early.
  $unconfigured_whitelisted_cas = $ca_whitelist.filter |$ca_name| { !$ca_profiles[$ca_name] }
  unless empty($unconfigured_whitelisted_cas) {
    fail("acme_kvstore: \$ca_whitelist mentions CA(s) with no matching \$ca_profiles entry: ${unconfigured_whitelisted_cas.join(', ')}")
  }

  if $dnssleep >= $exec_timeout {
    fail("acme_kvstore: \$dnssleep (${dnssleep}) must be lower than \$exec_timeout (${exec_timeout})")
  }

  if $default_dns_profile and !$dns_profiles[$default_dns_profile] {
    fail("acme_kvstore: \$default_dns_profile '${default_dns_profile}' is not a key in \$dns_profiles")
  }

  $certificates.each |$certid, $certificate_params| {
    acme_kvstore::certificate { $certid:
      * => $certificate_params,
    }
  }
}
