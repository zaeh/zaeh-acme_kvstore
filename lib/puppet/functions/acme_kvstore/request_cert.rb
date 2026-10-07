# frozen_string_literal: true

require_relative '../../../puppet_x/acme_kvstore/acmesh'

# @summary Requests a certificate via acme.sh directly, without storing it in the KV store.
#
# For manual testing on the ACME worker, e.g.
# `puppet apply -e "notice(acme_kvstore::request_cert(['example.com']))"`.
Puppet::Functions.create_function(:'acme_kvstore::request_cert') do
  # @param domains Primary domain plus any SANs.
  # @param options Optional settings: key_type, key_size, server, dns_provider, dns_env, dns_options,
  #   challenge_alias, domain_alias, account_email, eab_kid, eab_hmac_key, proxy,
  #   exec_timeout, run_as_user, run_as_group, run_as_home, acmesh_path, dnssleep (default 60), webroot,
  #   log_file, log_level.
  # @return Hash with the keys 'cert', 'chain', 'fullchain', 'key' (PEM strings or undef).
  dispatch :request_cert do
    param 'Array[String[1]]', :domains
    optional_param 'Hash', :options
    return_type 'Hash'
  end

  def request_cert(domains, options = {})
    result = PuppetX::AcmeKvstore::Acmesh.issue_or_renew(
      domains:,
      key_type: options['key_type'] || 'rsa',
      key_size: options['key_size'] || 2048,
      server: options['server'] || 'letsencrypt',
      dns_provider: options['dns_provider'],
      dns_env: options['dns_env'] || {},
      dns_options: options['dns_options'] || {},
      challenge_alias: options['challenge_alias'],
      domain_alias: options['domain_alias'],
      account_email: options['account_email'],
      eab_kid: options['eab_kid'],
      eab_hmac_key: options['eab_hmac_key'],
      proxy: options['proxy'],
      exec_timeout: options['exec_timeout'],
      run_as_user: options['run_as_user'],
      run_as_group: options['run_as_group'],
      run_as_home: options['run_as_home'],
      acmesh_path: options['acmesh_path'] || '/root/.acme.sh/acme.sh',
      dnssleep: options['dnssleep'] || 60,
      webroot: options['webroot'] || PuppetX::AcmeKvstore::Acmesh::DEFAULT_WEBROOT,
      log_file: options['log_file'],
      log_level: options['log_level'],
    )
    result.transform_keys(&:to_s)
  end
end
