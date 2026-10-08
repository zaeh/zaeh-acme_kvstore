# @summary Writes a certificate stored by acme_kvstore (and optionally key, chain, DH parameters) to files on this node.
#
# Fetches the certificate while the catalogue is compiled
# (acme_kvstore::lookup_cert), so the compiler needs access to Consul/Redis.
# Independent of the acme_kvstore class and the worker: pass backend,
# backend_config, area and area_secret, or leave them undef to use the
# acme_kvstore::* Hiera keys with the area's read-only credentials
# (consul_read_token, redis_read_username/redis_read_password - never the
# worker's read/write ones). The certificate's status decides: 'active'
# writes the files, 'delete' removes them, anything else (including
# 'norollout') leaves them alone. See docs/lookup_cert.md.
#
# @param cert_path Where to write the (leaf) certificate.
# @param key_path Where to write the private key.
# @param chain_path Where to write the issuer chain, without self-signed roots (skipped with a warning if the issuer is not stored).
# @param fullchain_path Where to write certificate + chain (skipped with a warning if the issuer is not stored).
# @param combined_path Where to write certificate + chain + key (e.g. for HAProxy), with key_mode.
# @param dh_path Where to write the DH parameters (RFC 7919 group).
# @param chain_include_root
#   Whether to append the self-signed root to chain_path, fullchain_path and
#   combined_path, for applications without a usable trust store. The root
#   must be stored in the area (CAs rarely deliver it; import it e.g. in CCI-UI).
# @param combined_include_dh Whether to append the DH parameters to combined_path.
# @param dh_param_size DH parameter size: 2048, 3072 or 4096.
# @param owner Owner of all files.
# @param group Group of all files.
# @param cert_mode Mode of files without the private key.
# @param key_mode Mode of key_path and combined_path.
# @param notify_services Services to notify when a file changes.
# @param certid Certificate ID.
# @param area Area of the certificate.
# @param area_secret The area's secret; only needed to write a key.
# @param backend KV backend.
# @param backend_config Connection details including 'prefix' and credentials; used as given.
define acme_kvstore::deploy (
  # Files to write
  Stdlib::Absolutepath                  $cert_path,
  Optional[Stdlib::Absolutepath]        $key_path            = undef,
  Optional[Stdlib::Absolutepath]        $chain_path          = undef,
  Optional[Stdlib::Absolutepath]        $fullchain_path      = undef,
  Optional[Stdlib::Absolutepath]        $combined_path       = undef,
  Optional[Stdlib::Absolutepath]        $dh_path             = undef,

  # File contents
  Boolean                               $chain_include_root  = false,
  Boolean                               $combined_include_dh = false,
  Optional[Acme_kvstore::Dh_param_size] $dh_param_size       = undef,

  # Ownership and notification
  String[1]                             $owner               = 'root',
  String[1]                             $group               = 'root',
  Stdlib::Filemode                      $cert_mode           = '0644',
  Stdlib::Filemode                      $key_mode            = '0600',
  Array[String[1]]                      $notify_services     = [],

  # Source (undef: the acme_kvstore::* Hiera keys)
  Acme_kvstore::Certid                  $certid              = $title,
  Optional[Acme_kvstore::Area_name]     $area                = undef,
  Optional[Acme_kvstore::Secret]        $area_secret         = undef,
  Optional[Enum['consul', 'redis']]     $backend             = undef,
  Optional[Hash]                        $backend_config      = undef,
) {
  # Deliberately no `include acme_kvstore` - see the description above.
  $real_area = $area ? {
    undef   => lookup('acme_kvstore::default_area', Optional[Acme_kvstore::Area_name], 'first', undef),
    default => $area,
  }
  if !$real_area {
    fail("acme_kvstore::deploy[${title}]: no 'area' given and no acme_kvstore::default_area in Hiera")
  }

  $decrypt_key = $key_path =~ NotUndef or $combined_path =~ NotUndef
  $needs_area_config = ($decrypt_key and $area_secret =~ Undef) or $backend_config =~ Undef
  $area_config = $needs_area_config ? {
    true    => lookup('acme_kvstore::areas', Hash[Acme_kvstore::Area_name, Acme_kvstore::Area], 'deep', {})[$real_area],
    default => undef,
  }

  if !$decrypt_key {
    $area_secret_plain = undef
  } elsif $area_secret =~ NotUndef {
    $area_secret_plain = acme_kvstore::unwrap_if_sensitive($area_secret)
  } elsif $area_config {
    $area_secret_plain = acme_kvstore::unwrap_if_sensitive($area_config['secret'])
  } else {
    fail("acme_kvstore::deploy[${title}]: no 'area_secret' given and area '${real_area}' not found in acme_kvstore::areas in Hiera")
  }

  $real_backend = $backend ? {
    undef   => lookup('acme_kvstore::backend', Enum['consul', 'redis']),
    default => $backend,
  }
  if $backend_config =~ NotUndef {
    $real_backend_config = $backend_config
  } else {
    # The area's read-only credentials; deploy never uses the worker's.
    if $real_backend == 'consul' {
      if !$area_config or !$area_config['consul_read_token'] {
        fail("acme_kvstore::deploy[${title}]: no 'backend_config' given and area '${real_area}' has no 'consul_read_token' in acme_kvstore::areas in Hiera")
      }
      $area_credentials = { 'token' => acme_kvstore::unwrap_if_sensitive($area_config['consul_read_token']) }
    } else {
      if !$area_config or !$area_config['redis_read_username'] or !$area_config['redis_read_password'] {
        fail("acme_kvstore::deploy[${title}]: no 'backend_config' given and area '${real_area}' has no 'redis_read_username'/'redis_read_password' in acme_kvstore::areas in Hiera")
      }
      $area_credentials = {
        'username' => $area_config['redis_read_username'],
        'password' => acme_kvstore::unwrap_if_sensitive($area_config['redis_read_password']),
      }
    }
    $backend_type = $real_backend ? { 'consul' => Acme_kvstore::Consul_config, default => Acme_kvstore::Redis_config }
    $backend_defaults = lookup("acme_kvstore::${real_backend}", $backend_type, 'deep', {})
    $set_area_credentials = $area_credentials.filter |$key, $value| { $value =~ NotUndef }
    $real_backend_config = $backend_defaults + $set_area_credentials + { 'prefix' => lookup('acme_kvstore::prefix', String[1]) }
  }

  # The chain is only searched for when a file needs it.
  $include_chain = $chain_path =~ NotUndef or $fullchain_path =~ NotUndef or $combined_path =~ NotUndef
  $cert = acme_kvstore::lookup_cert(
    $certid, $real_area, $real_backend, $real_backend_config, $area_secret_plain, $decrypt_key, $include_chain, $chain_include_root
  )

  $notify_resources = $notify_services.map |$service_name| { Service[$service_name] }

  case $cert['status'] {
    'active': {
      $real_dh_param_size = $dh_param_size ? {
        undef   => lookup('acme_kvstore::dh_param_size', Acme_kvstore::Dh_param_size),
        default => $dh_param_size,
      }
      $dh_params = file("acme_kvstore/dhparams/ffdhe${real_dh_param_size}.pem")

      File {
        owner  => $owner,
        group  => $group,
        notify => $notify_resources,
      }

      file { $cert_path:
        ensure  => file,
        mode    => $cert_mode,
        content => $cert['pem'],
      }

      if $key_path {
        file { $key_path:
          ensure    => file,
          mode      => $key_mode,
          content   => Sensitive($cert['private_key']),
          show_diff => false,
        }
      }

      # The chain is built from the issuer entries in the KV store.
      if $cert['chain_missing'] {
        $reason = $cert['chain_error'] ? { undef => '', default => " (search failed: ${cert['chain_error']})" }
        warning("acme_kvstore::deploy[${title}]: issuer of certificate '${certid}' not found in area '${real_area}'${reason}; not writing chain_path/fullchain_path, combined_path without chain")
      }

      # Optionally the self-signed root at the end, for applications without a trust store.
      if $chain_include_root and $include_chain and !$cert['chain_missing'] and $cert['root'] =~ Undef {
        warning("acme_kvstore::deploy[${title}]: root CA of certificate '${certid}' not stored in area '${real_area}'; writing the chain without it - import it, e.g. in CCI-UI")
      }
      $root = $chain_include_root ? {
        true    => $cert['root'],
        default => undef,
      }

      if $chain_path and !$cert['chain_missing'] {
        file { $chain_path:
          ensure  => file,
          mode    => $cert_mode,
          content => [$cert['chain'], $root].filter |$part| { $part =~ NotUndef }.join(''),
        }
      }

      if $fullchain_path and !$cert['chain_missing'] {
        file { $fullchain_path:
          ensure  => file,
          mode    => $cert_mode,
          content => [$cert['fullchain'], $root].filter |$part| { $part =~ NotUndef }.join(''),
        }
      }

      if $combined_path {
        $combined_certs = $cert['fullchain'] ? {
          undef   => [$cert['pem']],
          default => [$cert['fullchain'], $root],
        }
        $combined_parts = $combined_certs + [$cert['private_key']] + ($combined_include_dh ? { true => [$dh_params], default => [] })
        file { $combined_path:
          ensure    => file,
          mode      => $key_mode,
          content   => Sensitive($combined_parts.filter |$part| { $part =~ NotUndef }.map |$part| { $part.regsubst('\n*\z', "\n") }.join('')),
          show_diff => false,
        }
      }

      if $dh_path {
        file { $dh_path:
          ensure  => file,
          mode    => $cert_mode,
          content => $dh_params,
        }
      }
    }
    'delete': {
      $paths = [$cert_path, $key_path, $chain_path, $fullchain_path, $combined_path, $dh_path].filter |$path| { $path =~ NotUndef }
      file { $paths:
        ensure => absent,
        notify => $notify_resources,
      }
    }
    'norollout', undef: {}
    default: {
      warning("acme_kvstore::deploy[${title}]: unknown status '${cert['status']}' for certificate '${certid}'; leaving its files alone")
    }
  }
}
