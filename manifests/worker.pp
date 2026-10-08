# @summary Prepares an ACME worker: acme.sh, the redis gem and an optional dedicated user.
#
# Included automatically on the worker by acme_kvstore::certificate.
# Defaults: data/common.yaml.
#
# @param install_method Install acme.sh from 'git' or as a 'package'.
# @param acme_git_url acme.sh Git repository (e.g. an internal mirror).
# @param acme_git_force Recreate the clone, discarding local changes.
# @param acme_version acme.sh tag/branch/commit; pinned so updates are deliberate.
# @param manage_packages Install git (for install_method 'git').
# @param manage_gems Install the redis gem for the Redis provider.
# @param manage_user Create user/group (false: use an existing account).
# @param user User acme.sh runs as (a non-root user is recommended).
# @param group Group of user and owner group of home/webroot.
# @param webroot Webroot for HTTP-01.
# @param config_dir Directory for generated files such as nsupdate TSIG keys.
# @param acme_log_file acme.sh log file, or false for none; not rotated.
# @param acme_log_level acme.sh log level: 1 (normal) or 2 (debug).
# @param manage_log_dir Manage the log file's directory (false for shared ones like /var/log).
# @param home acme.sh home; derived from user by default.
class acme_kvstore::worker (
  # Installation of acme.sh
  Enum['git', 'package']                        $install_method,
  String[1]                                     $acme_git_url,
  Boolean                                       $acme_git_force,
  String[1]                                     $acme_version,
  Boolean                                       $manage_packages,
  Boolean                                       $manage_gems,

  # User and directories
  Boolean                                       $manage_user,
  String[1]                                     $user,
  String[1]                                     $group,
  Stdlib::Absolutepath                          $webroot,
  Stdlib::Absolutepath                          $config_dir,

  # Logging
  Variant[Stdlib::Absolutepath, Boolean[false]] $acme_log_file,
  Integer[1, 2]                                 $acme_log_level,
  Boolean                                       $manage_log_dir,

  # Derived from $user, so its default stays here, not in data/common.yaml
  Stdlib::Absolutepath                          $home = $user ? { 'root' => '/root/.acme.sh', default => "/home/${user}/.acme.sh" },
) {
  include acme_kvstore

  if $manage_user and $user != 'root' {
    group { $group:
      ensure => present,
    }

    user { $user:
      ensure     => present,
      gid        => $group,
      home       => $home,
      managehome => true,
      system     => true,
      shell      => '/usr/sbin/nologin',
      require    => Group[$group],
    }
  }

  if $manage_packages and $install_method == 'git' {
    package { 'acme_kvstore-git':
      ensure => installed,
      name   => 'git',
    }
  }

  # Also creates missing parents (e.g. /var/www on a worker without a web
  # server) without managing them, so a web server module still can.
  exec { 'acme_kvstore-webroot':
    command => ['mkdir', '-p', $webroot],
    creates => $webroot,
    path    => ['/usr/bin', '/bin'],
  }

  file { $webroot:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    require => Exec['acme_kvstore-webroot'],
  }

  if $install_method == 'git' {
    vcsrepo { '/opt/acme.sh-src':
      ensure   => present,
      provider => git,
      source   => $acme_git_url,
      revision => $acme_version,
      force    => $acme_git_force,
    }

    exec { 'acme_kvstore-install-acmesh':
      command => "/opt/acme.sh-src/acme.sh --install --home ${home} --nocron",
      creates => "${home}/acme.sh",
      cwd     => '/opt/acme.sh-src', # --install copies acme.sh from the working directory
      path    => ['/usr/bin', '/bin', '/opt/acme.sh-src'],
      require => Vcsrepo['/opt/acme.sh-src'],
    }

    file { $home:
      ensure  => directory,
      owner   => $user,
      group   => $group,
      recurse => false,
      require => Exec['acme_kvstore-install-acmesh'],
    }
  } else {
    package { 'acme.sh':
      ensure => installed,
    }
  }

  if $manage_gems {
    package { 'acme_kvstore-redis-gem':
      ensure   => installed,
      name     => 'redis',
      provider => puppet_gem,
    }
  }

  if $acme_log_file {
    if $manage_log_dir {
      file { $acme_log_file.regsubst('/[^/]+$', ''):
        ensure => directory,
        owner  => $user,
        group  => $group,
        mode   => '0750',
        before => File[$acme_log_file],
      }
    }

    # Written by acme.sh; Puppet only ensures ownership.
    file { $acme_log_file:
      ensure => file,
      owner  => $user,
      group  => $group,
      mode   => '0640',
    }
  }

  file { $config_dir:
    ensure => directory,
    owner  => 'root',
    group  => $group,
    mode   => '0750',
  }

  # Custom DNS API scripts: acme.sh looks in <home>/dnsapi/ first and only
  # sources the file, so read access suffices.
  unless empty($acme_kvstore::dnsapi_scripts) {
    $acmesh_installed = $install_method ? {
      'git'   => Exec['acme_kvstore-install-acmesh'],
      default => Package['acme.sh'],
    }

    file { "${home}/dnsapi":
      ensure  => directory,
      owner   => 'root',
      group   => $group,
      mode    => '0755',
      require => $acmesh_installed,
    }

    $acme_kvstore::dnsapi_scripts.each |$hook, $script| {
      file { "${home}/dnsapi/${hook}.sh":
        ensure  => file,
        owner   => 'root',
        group   => $group,
        mode    => '0640',
        source  => $script['source'],
        content => $script['content'],
      }
    }
  }

  # TSIG key files for dns_nsupdate profiles (NSUPDATE_KEY expects a path);
  # root-owned, the acme.sh user only reads them via its group.
  $nsupdate_profiles = $acme_kvstore::dns_profiles.filter |$profile_name, $profile| {
    $options = pick_default($profile['options'], {})
    $profile['hook'] == 'dns_nsupdate' and $options['nsupdate_id'] =~ NotUndef and $options['nsupdate_key'] =~ NotUndef and $options['nsupdate_type'] =~ NotUndef
  }
  $nsupdate_key_files = $nsupdate_profiles.reduce({}) |$memo, $entry| {
    $memo + { $entry[0] => "${config_dir}/nsupdate/${entry[0]}.key" }
  }

  unless empty($nsupdate_profiles) {
    file { "${config_dir}/nsupdate":
      ensure => directory,
      owner  => 'root',
      group  => $group,
      mode   => '0750',
    }

    $nsupdate_profiles.each |$profile_name, $profile| {
      file { $nsupdate_key_files[$profile_name]:
        ensure    => file,
        owner     => 'root',
        group     => $group,
        mode      => '0640',
        show_diff => false,
        content   => Sensitive(epp('acme_kvstore/nsupdate_key.epp', {
          'key_name'  => String(acme_kvstore::unwrap_if_sensitive($profile['options']['nsupdate_id'])),
          'algorithm' => String(acme_kvstore::unwrap_if_sensitive($profile['options']['nsupdate_type'])),
          'secret'    => String(acme_kvstore::unwrap_if_sensitive($profile['options']['nsupdate_key'])),
        })),
      }
    }
  }
}
