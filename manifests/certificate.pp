# @summary Declares an ACME certificate; issued and renewed only on its worker.
#
# Can be declared on every node (e.g. via $acme_kvstore::certificates); it
# is a no-op everywhere except on the responsible worker. Defaults: the
# acme_kvstore class. See docs/profiles.md.
#
# @param domain Primary domain (the certificate's CN); a wildcard needs DNS-01. A change forces a reissue.
# @param subject_alt_names Additional names on the certificate; a change forces a reissue.
# @param area Area (secret and KV namespace).
# @param certid Certificate ID.
# @param worker FQDN of the responsible worker.
# @param backend KV backend.
# @param key_type Key algorithm.
# @param key_size RSA bit length or EC curve (256/384).
# @param renew_before_days Renew when fewer days than this remain.
# @param purge_key_on_mismatch Whether a changed key_type/key_size forces an immediate reissue.
# @param store_issuers Whether the chain certificates acme.sh returns are stored as issuer entries.
# @param tags Free-form tags stored with the certificate.
# @param challenge_type Challenge type, 'http-01' or 'dns-01'; auto-detected if undef, a mismatch fails if set.
# @param use_dns_profile DNS profile for DNS-01.
# @param dns_provider acme.sh DNS hook used instead of a profile (manual override).
# @param dns_env Credentials for dns_provider.
# @param challenge_alias DNS alias mode, overrides the profile.
# @param domain_alias DNS alias mode, overrides the profile.
# @param dnssleep Seconds to wait for DNS-01 records; defaults to the profile's, then the class's.
# @param use_ca_profile CA profile; must be whitelisted.
# @param posthook_cmd Command run on the worker after issuing.
# @param proxy HTTP(S) proxy for acme.sh.
# @param exec_timeout Maximum run time of acme.sh in seconds.
# @param renew_schedule
#   Name of a 'schedule' resource whose range/weekday limit when a due
#   renewal may run; first issuance is never delayed. undef: any time.
define acme_kvstore::certificate (
  Acme_kvstore::Domain $domain,
  Array[Acme_kvstore::Domain] $subject_alt_names = [],
  Optional[Acme_kvstore::Area_name] $area = undef,
  Acme_kvstore::Certid $certid = $title,
  Optional[Stdlib::Fqdn] $worker = undef,
  Optional[Enum['consul', 'redis']] $backend = undef,
  Enum['rsa', 'ec'] $key_type = 'rsa',
  Integer[256] $key_size = 2048,
  Integer[1] $renew_before_days = $acme_kvstore::renew_before_days,
  Boolean $purge_key_on_mismatch = $acme_kvstore::purge_key_on_mismatch,
  Boolean $store_issuers = $acme_kvstore::store_issuers,
  Array[String[1]] $tags = [],
  Optional[Enum['http-01', 'dns-01']] $challenge_type = undef,
  Optional[String[1]] $use_dns_profile = undef,
  Optional[Pattern[/\Adns_[a-z0-9_]+\z/]] $dns_provider = undef,
  Hash[String[1], String[1]] $dns_env = {},
  Optional[Stdlib::Fqdn] $challenge_alias = undef,
  Optional[Stdlib::Fqdn] $domain_alias = undef,
  Optional[Integer[1]] $dnssleep = undef,
  String[1] $use_ca_profile = $acme_kvstore::default_ca_profile,
  Optional[String[1]] $posthook_cmd = $acme_kvstore::posthook_cmd,
  Optional[String[1]] $proxy = $acme_kvstore::proxy,
  Integer[1] $exec_timeout = $acme_kvstore::exec_timeout,
  Optional[String[1]] $renew_schedule = $acme_kvstore::renew_schedule,
) {
  include acme_kvstore

  # acme.sh's -d list: the primary domain first (CN), then the other names.
  $domains = [$domain] + ($subject_alt_names - [$domain]).unique

  # Selectors, not pick_default: that returns '' (truthy) if both are undef.
  $real_area = $area ? { undef => $acme_kvstore::default_area, default => $area }
  if !$real_area {
    fail("acme_kvstore::certificate[${title}]: no 'area' given and no \$default_area configured")
  }
  $area_config = $acme_kvstore::areas[$real_area]
  if !$area_config {
    fail("acme_kvstore::certificate[${title}]: unknown area '${real_area}' (see \$acme_kvstore::areas)")
  }

  $real_worker = $worker ? { undef => $acme_kvstore::default_worker, default => $worker }
  if !$real_worker {
    fail("acme_kvstore::certificate[${title}]: no 'worker' given and no \$default_worker configured")
  }

  $is_worker = $facts.dig('networking', 'fqdn') == $real_worker

  # Only realised on the responsible worker (instead of exported resources).
  if $is_worker {
    include acme_kvstore::worker

    $real_backend = pick_default($backend, $acme_kvstore::backend)

    $area_secret_plain = acme_kvstore::unwrap_if_sensitive($area_config['secret'])
    $consul_token_plain = acme_kvstore::unwrap_if_sensitive($area_config['consul_token'])
    $redis_password_plain = acme_kvstore::unwrap_if_sensitive($area_config['redis_password'])

    if $real_backend == 'consul' and !$consul_token_plain {
      fail("acme_kvstore::certificate[${title}]: area '${real_area}' has no 'consul_token' - with Consul, every area needs its own token")
    }
    $consul_overrides = $consul_token_plain ? {
      undef   => {},
      default => { 'token' => $consul_token_plain },
    }
    $redis_password_override = $redis_password_plain ? {
      undef   => {},
      default => { 'password' => $redis_password_plain },
    }
    $redis_username_override = $area_config['redis_username'] ? {
      undef   => {},
      default => { 'username' => $area_config['redis_username'] },
    }
    if $real_backend == 'redis' and !($redis_password_plain and $area_config['redis_username']) {
      fail("acme_kvstore::certificate[${title}]: area '${real_area}' has no 'redis_username'/'redis_password' - with Redis, every area needs its own ACL user")
    }
    $redis_overrides = $redis_password_override + $redis_username_override

    $backend_config = $real_backend ? {
      'consul' => $acme_kvstore::consul + { 'prefix' => $acme_kvstore::prefix } + $consul_overrides,
      'redis'  => $acme_kvstore::redis + { 'prefix' => $acme_kvstore::prefix } + $redis_overrides,
    }

    unless $use_ca_profile in $acme_kvstore::ca_whitelist {
      fail("acme_kvstore::certificate[${title}]: CA profile '${use_ca_profile}' is not in \$acme_kvstore::ca_whitelist")
    }
    $ca_profile = $acme_kvstore::ca_profiles[$use_ca_profile]
    if !$ca_profile {
      fail("acme_kvstore::certificate[${title}]: unknown CA profile '${use_ca_profile}' (see \$acme_kvstore::ca_profiles)")
    }
    # Without directory_url, the profile name is acme.sh's --server alias.
    $acme_server = pick_default($ca_profile['directory_url'], $use_ca_profile)
    $account_email = $ca_profile['account_email']
    $eab_kid = acme_kvstore::unwrap_if_sensitive($ca_profile['eab_kid'])
    $eab_hmac_key = acme_kvstore::unwrap_if_sensitive($ca_profile['eab_hmac_key'])

    # A manual dns_provider wins over any profile.
    $real_dns_profile_name = $use_dns_profile ? { undef => $acme_kvstore::default_dns_profile, default => $use_dns_profile }

    if $dns_provider {
      $resolved_hook = $dns_provider
      $resolved_env = $dns_env
      $resolved_options = {}
      $profile_dnssleep = undef
      $resolved_challenge_alias = $challenge_alias
      $resolved_domain_alias = $domain_alias
    } elsif $real_dns_profile_name {
      $dns_profile = $acme_kvstore::dns_profiles[$real_dns_profile_name]
      if !$dns_profile {
        fail("acme_kvstore::certificate[${title}]: unknown DNS profile '${real_dns_profile_name}' (see \$acme_kvstore::dns_profiles)")
      }
      $resolved_hook = $dns_profile['hook']
      $profile_env = pick_default($dns_profile['env'], {}).reduce({}) |$memo, $kv| {
        $memo + { $kv[0] => acme_kvstore::unwrap_if_sensitive($kv[1]) }
      }
      $profile_options = pick_default($dns_profile['options'], {}).reduce({}) |$memo, $kv| {
        $memo + { $kv[0] => acme_kvstore::unwrap_if_sensitive($kv[1]) }
      }
      $profile_dnssleep = $profile_options['dnssleep']

      # dns_nsupdate needs NSUPDATE_KEY as a key file path; the worker
      # writes that file, so these options are not passed on as variables.
      $nsupdate_key_file = $acme_kvstore::worker::nsupdate_key_files[$real_dns_profile_name]
      if $nsupdate_key_file {
        $resolved_env = { 'NSUPDATE_KEY' => $nsupdate_key_file } + $profile_env
        $option_filter = ['dnssleep', 'nsupdate_id', 'nsupdate_key', 'nsupdate_type']
      } else {
        $resolved_env = $profile_env
        $option_filter = ['dnssleep']
      }
      $resolved_options = $profile_options.filter |$key, $value| { !($key in $option_filter) }
      $resolved_challenge_alias = $challenge_alias ? { undef => $dns_profile['challenge_alias'], default => $challenge_alias }
      $resolved_domain_alias = $domain_alias ? { undef => $dns_profile['domain_alias'], default => $domain_alias }
    } else {
      $resolved_hook = undef
      $resolved_env = {}
      $resolved_options = {}
      $profile_dnssleep = undef
      $resolved_challenge_alias = $challenge_alias
      $resolved_domain_alias = $domain_alias
    }

    $real_dnssleep = [$dnssleep, $profile_dnssleep, $acme_kvstore::dnssleep].filter |$value| { $value =~ NotUndef }[0]
    if Integer($real_dnssleep) >= $exec_timeout {
      fail("acme_kvstore::certificate[${title}]: dnssleep (${real_dnssleep}) must be lower than exec_timeout (${exec_timeout})")
    }

    $real_challenge_type = $challenge_type ? {
      undef   => ($resolved_hook ? { undef => 'http-01', default => 'dns-01' }),
      default => $challenge_type,
    }
    if $real_challenge_type == 'dns-01' and !$resolved_hook {
      fail("acme_kvstore::certificate[${title}]: challenge_type is 'dns-01' but no DNS hook/profile is configured")
    }
    if $real_challenge_type == 'http-01' and $resolved_hook {
      fail("acme_kvstore::certificate[${title}]: challenge_type is 'http-01' but a DNS hook/profile was also given")
    }
    $wildcard_domains = $domains.filter |$name| { $name =~ /^\*\./ }
    if $real_challenge_type == 'http-01' and !empty($wildcard_domains) {
      fail("acme_kvstore::certificate[${title}]: wildcard domains (${wildcard_domains.join(', ')}) require DNS-01 validation - configure a DNS profile or dns_provider")
    }

    # Run acme.sh as acme_kvstore::worker's user (nothing to set for root).
    $run_as_user = $acme_kvstore::worker::user ? { 'root' => undef, default => $acme_kvstore::worker::user }
    $run_as_group = $acme_kvstore::worker::group ? { 'root' => undef, default => $acme_kvstore::worker::group }
    $run_as_home = $acme_kvstore::worker::user ? { 'root' => undef, default => $acme_kvstore::worker::home }
    $log_file = $acme_kvstore::worker::acme_log_file ? { false => undef, default => $acme_kvstore::worker::acme_log_file }

    acme_kvstore_certificate { $certid:
      ensure                => present,
      provider              => $real_backend,
      area                  => $real_area,
      domains               => $domains,
      key_type              => $key_type,
      key_size              => $key_size,
      renew_before_days     => $renew_before_days,
      purge_key_on_mismatch => $purge_key_on_mismatch,
      store_issuers         => $store_issuers,
      tags                  => $tags,
      server                => $acme_server,
      account_email         => $account_email,
      eab_kid               => $eab_kid,
      eab_hmac_key          => $eab_hmac_key,
      dns_provider          => $resolved_hook,
      dns_env               => $resolved_env,
      dns_options           => $resolved_options,
      dnssleep              => Integer($real_dnssleep),
      webroot               => $acme_kvstore::worker::webroot,
      log_file              => $log_file,
      log_level             => $acme_kvstore::worker::acme_log_level,
      challenge_alias       => $resolved_challenge_alias,
      domain_alias          => $resolved_domain_alias,
      posthook_cmd          => $posthook_cmd,
      proxy                 => $proxy,
      exec_timeout          => $exec_timeout,
      run_as_user           => $run_as_user,
      run_as_group          => $run_as_group,
      run_as_home           => $run_as_home,
      acmesh_path           => "${acme_kvstore::worker::home}/acme.sh",
      backend_config        => $backend_config,
      area_secret           => $area_secret_plain,
      client_id             => $acme_kvstore::kv_client,
      updated_by            => pick($acme_kvstore::kv_updated_by, $real_worker),
      renew_schedule        => $renew_schedule,
      require               => Class['acme_kvstore::worker'],
    }
  }
}
