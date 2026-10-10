# frozen_string_literal: true

require 'puppet_x'
require 'open3'
require 'tmpdir'
require 'shellwords'
require 'etc'

module PuppetX::AcmeKvstore
  # Runs acme.sh for the acme_kvstore_certificate provider and the
  # acme_kvstore::request_cert function.
  class Acmesh
    class Error < StandardError; end

    # acme.sh exit code for "renewal not due yet".
    RENEW_NOT_DUE = 2

    DEFAULT_TIMEOUT = 300

    DEFAULT_WEBROOT = '/var/www/acme-challenge'

    # Seconds between TERM and KILL on timeout.
    TERM_GRACE_PERIOD = 5

    # dnssleep (DNS-01 only) also stops acme.sh from polling public DNS
    # resolvers itself. No log file is written without log_file. ca_bundles
    # (files of CA certificates, joined into one) replace the trust store for
    # all of acme.sh's HTTPS requests, the DNS hook's included.
    #
    # @return [Hash{Symbol=>String,nil}] :cert, :chain, :fullchain, :key (PEM or nil)
    def self.issue_or_renew(domains:, key_type:, key_size:, server:, dns_provider:, dns_env:, dns_options:,
                            challenge_alias:, domain_alias:, account_email:, eab_kid:, eab_hmac_key:, acmesh_path:,
                            proxy: nil, exec_timeout: nil,
                            run_as_user: nil, run_as_group: nil, run_as_home: nil,
                            dnssleep: nil, webroot: DEFAULT_WEBROOT, log_file: nil, log_level: nil, ca_bundles: [])
      domains = Array(domains)
      raise Error, 'at least one domain is required' if domains.empty?
      raise Error, "acme.sh not found or not executable: #{acmesh_path}" unless File.executable?(acmesh_path)
      raise Error, "wildcard domains require DNS-01 validation (a DNS hook), not HTTP-01: #{domains.join(', ')}" if (dns_provider.nil? || dns_provider.to_s.empty?) && domains.any? { |d| d.to_s.start_with?('*') }

      timeout = exec_timeout || DEFAULT_TIMEOUT

      Dir.mktmpdir('acme_kvstore') do |dir|
        paths = {
          cert:      File.join(dir, 'cert.pem'),
          key:       File.join(dir, 'key.pem'),
          chain:     File.join(dir, 'ca.pem'),
          fullchain: File.join(dir, 'fullchain.pem'),
        }
        ca_bundle = join_ca_bundles(ca_bundles, File.join(dir, 'ca-bundle.pem'))
        # acme.sh, running as run_as_user, must write into this directory.
        chown_to_run_as_user(dir, run_as_user, run_as_group) if run_as_user

        log_args = log_args(log_file, log_level) + ca_bundle_args(ca_bundle)
        ensure_account_registered(
          acmesh_path:, server:,
          account_email:, eab_kid:, eab_hmac_key:,
          proxy:, timeout:, run_as_user:, run_as_group:, run_as_home:, log_args:, ca_bundle:
        )

        cmd = build_command(
          acmesh_path, domains, key_type, key_size, server, dns_provider,
          challenge_alias, domain_alias, paths,
          dnssleep:, webroot:
        ) + log_args
        env = build_env(dns_env, dns_options, proxy, run_as_home)
        _out, err, status = run_acmesh(env, cmd, ca_bundle:, timeout:, run_as_user:, run_as_group:)

        raise Error, "acme.sh failed (exit #{status.exitstatus}):\n#{err}" unless status.success? || status.exitstatus == RENEW_NOT_DUE

        {
          cert:      read_if_present(paths[:cert]),
          chain:     read_if_present(paths[:chain]),
          fullchain: read_if_present(paths[:fullchain]),
          key:       read_if_present(paths[:key]),
        }
      end
    end

    # Raises Error on failure/timeout; the caller decides if that is fatal.
    def self.run_posthook(cmd, timeout: nil, run_as_user: nil, run_as_group: nil)
      _out, err, status = run_with_timeout({}, [cmd], timeout: timeout || DEFAULT_TIMEOUT,
                                                      run_as_user:, run_as_group:)
      raise Error, "posthook_cmd failed (exit #{status.exitstatus}): #{err}" unless status.success?
    end

    # --register-account is idempotent and not rate-limited, so it runs
    # before every issuance instead of relying on acme.sh's on-disk account
    # layout (which has changed between versions). No-op without account
    # data.
    def self.ensure_account_registered(acmesh_path:, server:, account_email:, eab_kid:, eab_hmac_key:,
                                       proxy: nil, timeout: DEFAULT_TIMEOUT,
                                       run_as_user: nil, run_as_group: nil, run_as_home: nil, log_args: [],
                                       ca_bundle: nil)
      return if account_email.nil? && eab_kid.nil?

      cmd = [acmesh_path, '--register-account', '--server', server]
      cmd += ['-m', account_email] if account_email && !account_email.to_s.empty?
      cmd += ['--eab-kid', eab_kid] if eab_kid && !eab_kid.to_s.empty?
      cmd += ['--eab-hmac-key', eab_hmac_key] if eab_hmac_key && !eab_hmac_key.to_s.empty?
      cmd += log_args

      env = build_env({}, {}, proxy, run_as_home)
      _out, err, status = run_acmesh(env, cmd, ca_bundle:, timeout:, run_as_user:, run_as_group:)
      raise Error, "acme.sh account registration failed (exit #{status.exitstatus}): #{err}" unless status.success?
    end

    def self.build_command(acmesh_path, domains, key_type, key_size, server, dns_provider,
                           challenge_alias, domain_alias, paths, dnssleep:, webroot:)
      # --force: this module decides when to issue (renewal window, drift);
      # without it acme.sh skips (exit 2) while its own renewal date is ahead.
      cmd = [acmesh_path, '--issue', '--force', '--server', server]
      domains.each { |d| cmd += ['-d', d] }

      if dns_provider && !dns_provider.to_s.empty?
        cmd += ['--dns', dns_provider]
        cmd += ['--challenge-alias', challenge_alias] if challenge_alias && !challenge_alias.to_s.empty?
        cmd += ['--domain-alias', domain_alias] if domain_alias && !domain_alias.to_s.empty?
        cmd += ['--dnssleep', dnssleep.to_s] if dnssleep && !dnssleep.to_s.empty?
      else
        cmd += ['--webroot', webroot || DEFAULT_WEBROOT]
      end

      cmd += key_length_args(key_type, key_size)
      cmd += [
        '--cert-file', paths[:cert],
        '--key-file', paths[:key],
        '--ca-file', paths[:chain],
        '--fullchain-file', paths[:fullchain],
      ]
      cmd
    end

    def self.log_args(log_file, log_level)
      return [] if log_file.nil? || log_file.to_s.empty?

      args = ['--log', log_file.to_s]
      args += ['--log-level', log_level.to_s] if log_level && !log_level.to_s.empty?
      args
    end

    def self.key_length_args(key_type, key_size)
      case key_type.to_s
      when 'ec'
        ['--keylength', "ec-#{key_size}"]
      else
        ['--keylength', key_size.to_s]
      end
    end

    # dns_env is passed as given, dns_options (except dnssleep) upper-cased
    # like most DNS hooks expect. acme.sh has no proxy flag, hence
    # HTTP(S)_PROXY; HOME makes acme.sh find its data as run_as_user.
    def self.build_env(dns_env, dns_options, proxy, run_as_home)
      env = {}
      (dns_env || {}).each { |k, v| env[k.to_s] = v.to_s }
      (dns_options || {}).each do |k, v|
        next if k.to_s == 'dnssleep'

        env[k.to_s.upcase] = v.to_s
      end

      if proxy && !proxy.to_s.empty?
        proxy_url = proxy.to_s.include?('://') ? proxy.to_s : "http://#{proxy}"
        %w[HTTP_PROXY HTTPS_PROXY http_proxy https_proxy].each { |var| env[var] = proxy_url }
      end

      env['HOME'] = run_as_home if run_as_home && !run_as_home.to_s.empty?

      env
    end

    # Runs cmd (argv array, or one shell command string in an array) as
    # run_as_user/run_as_group via Process.spawn's :uid/:gid - only the
    # child is affected. On timeout the child is terminated (TERM, then
    # KILL), so no orphaned acme.sh keeps running, and Error is raised.
    #
    # @return [Array(String, String, Process::Status)] stdout, stderr, status
    def self.run_with_timeout(env, cmd, timeout:, run_as_user: nil, run_as_group: nil)
      spawn_opts = {}
      spawn_opts[:uid] = run_as_user if run_as_user && !run_as_user.to_s.empty?
      spawn_opts[:gid] = run_as_group if run_as_group && !run_as_group.to_s.empty?

      stdout_str = +''
      stderr_str = +''
      status = nil

      Open3.popen3(env, *cmd, spawn_opts) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        if wait_thr.join(timeout)
          stdout_str = stdout.read
          stderr_str = stderr.read
          status = wait_thr.value
        else
          terminate(wait_thr.pid)
          raise Error, "acme.sh timed out after #{timeout} seconds and was terminated"
        end
      end

      [stdout_str, stderr_str, status]
    end

    def self.terminate(pid)
      Process.kill('TERM', pid)
      3.times do
        sleep(TERM_GRACE_PERIOD / 3.0)
        return unless process_alive?(pid)
      end
      Process.kill('KILL', pid)
    rescue Errno::ESRCH
      nil # already exited on its own between the timeout and our kill attempt
    end

    def self.process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    # One file for --ca-bundle: a single file as it is, several joined into
    # joined_path (in the run's temporary directory, so run_as_user can read
    # it and it disappears with the run). nil without any.
    def self.join_ca_bundles(files, joined_path)
      files = Array(files).map(&:to_s).reject(&:empty?).uniq
      return nil if files.empty?

      missing = files.reject { |file| File.file?(file) }
      raise Error, "CA bundle(s) not found: #{missing.join(', ')}" unless missing.empty?
      return files.first if files.size == 1

      File.write(joined_path, files.map { |file| File.read(file).sub(%r{\n*\z}, "\n") }.join)
      File.chmod(0o644, joined_path)
      joined_path
    end

    # acme.sh 3.0.9: --ca-bundle sets CA_BUNDLE (curl --cacert); acme.sh
    # saves it in account.conf, see run_acmesh.
    def self.ca_bundle_args(ca_bundle)
      (ca_bundle.nil? || ca_bundle.to_s.empty?) ? [] : ['--ca-bundle', ca_bundle.to_s]
    end

    # Runs acme.sh without the settings it saved earlier for the keys this
    # module passes: account.conf is sourced after the command line is read,
    # so a saved value would win over env and over --ca-bundle.
    def self.run_acmesh(env, cmd, ca_bundle:, **run_opts)
      account_conf = account_conf_path(env['HOME'])
      managed_keys = env.keys - ['HOME']
      managed_keys += %w[CA_BUNDLE CA_PATH] unless ca_bundle_args(ca_bundle).empty?

      forget_saved_settings(account_conf, managed_keys)
      begin
        run_with_timeout(env, cmd, **run_opts)
      ensure
        forget_saved_settings(account_conf, managed_keys)
      end
    end

    # Where acme.sh keeps account.conf: LE_CONFIG_HOME, else LE_WORKING_DIR,
    # else $HOME/.acme.sh (acme.sh 3.0.9, __initHome).
    def self.account_conf_path(home)
      config_home = %w[LE_CONFIG_HOME LE_WORKING_DIR].map { |var| ENV.fetch(var, nil) }.find { |dir| dir && !dir.empty? }
      config_home ||= File.join(home || Dir.home, '.acme.sh')
      File.join(config_home, 'account.conf')
    end

    # acme.sh sources account.conf on every start, so values a DNS hook saved
    # there (_saveaccountconf) would override the ones passed from Hiera, and
    # stay on disk in plain text. Removes them (and their SAVED_ variants)
    # for the keys this module passes; other settings stay.
    def self.forget_saved_settings(path, keys)
      return if keys.empty? || !File.file?(path)

      pattern = %r{\A(?:SAVED_)?(?:#{keys.map { |key| Regexp.escape(key) }.join('|')}) *=}
      lines = File.readlines(path)
      kept = lines.grep_v(pattern)
      File.write(path, kept.join) unless kept.size == lines.size
    end

    def self.read_if_present(path)
      File.exist?(path) ? File.read(path) : nil
    end

    # chown instead of a world-writable chmod. User/group may be names or IDs.
    def self.chown_to_run_as_user(dir, run_as_user, run_as_group)
      uid = run_as_user.is_a?(Integer) ? run_as_user : Etc.getpwnam(run_as_user).uid
      gid = if run_as_group.nil? || run_as_group.to_s.empty?
              nil
            else
              run_as_group.is_a?(Integer) ? run_as_group : Etc.getgrnam(run_as_group).gid
            end
      File.chown(uid, gid, dir)
    end

    private_class_method :build_command, :key_length_args, :log_args, :build_env, :read_if_present, :chown_to_run_as_user,
                         :ensure_account_registered, :run_with_timeout, :terminate, :process_alive?,
                         :account_conf_path, :forget_saved_settings, :ca_bundle_args, :run_acmesh,
                         :join_ca_bundles
  end
end
