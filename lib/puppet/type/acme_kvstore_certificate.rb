# frozen_string_literal: true

Puppet::Type.newtype(:acme_kvstore_certificate) do
  @doc = <<-EOT
    Requests an ACME/Let's Encrypt certificate via acme.sh, renews it when
    required, and stores the certificate, chain and (optionally
    AES-256-GCM encrypted) private key in a Consul or Redis KV store.

    NO exported resources and NO PuppetDB are used. The type is ensurable,
    with `exists?` taking into account not only existence but also the
    renewal window: a certificate missing from the KV store is issued at
    once; one this module issued (its meta document has `acme_renewal`) is
    renewed when fewer than `renew_before_days` remain, within the time
    window of `renew_schedule`. An entry without `acme_renewal` (written by
    another tool) is never overwritten, only reported with a warning. The
    meta document's `status` only controls distribution, never renewal.

    Writes are protected against concurrent updates via compare-and-set
    (Consul: CAS on the ModifyIndex of the meta document; Redis:
    WATCH/MULTI/EXEC). If a concurrent write is detected, this run fails
    and the next scheduled run retries cleanly.

    @example Issue and renew a certificate in Consul (usually declared by acme_kvstore::certificate)
      acme_kvstore_certificate { 'shop-example-com':
        ensure            => present,
        provider          => 'consul',
        area              => 'web',
        domains           => ['shop.example.com', 'www.shop.example.com'],
        backend_config    => { 'url' => 'https://consul.example.com:8501', 'prefix' => 'acme' },
        area_secret       => $area_secret,
        renew_schedule    => 'nightly',
      }
  EOT

  ensurable do
    desc <<-EOT
      Whether the certificate is kept issued and renewed (`present`), or no longer renewed
      (`absent`: removes `acme_renewal` from the meta document; `status` and all versions stay).
    EOT
    defaultvalues
    defaultto :present
  end

  newparam(:certid, namevar: true) do
    desc 'Manually chosen, unique certificate ID (KV path segment).'
    validate do |value|
      raise ArgumentError, "certid may only contain letters, digits, '.', '_' and '-': #{value}" \
        unless value =~ %r{\A[\w.-]+\z}
    end
  end

  newparam(:area) do
    desc 'Logical area for the certificate (determines the KV namespace and area secret).'
    validate do |value|
      raise ArgumentError, 'area must not be empty' if value.to_s.empty?
    end
  end

  newparam(:domains, array_matching: :all) do
    desc <<-EOT
      The primary domain (CN) first, then any further names. Usually built by
      acme_kvstore::certificate from its domain and subject_alt_names.
    EOT
    validate do |value|
      domains = Array(value)
      raise ArgumentError, 'domains must not be empty' if domains.empty?

      domains.each do |domain|
        raise ArgumentError, "invalid domain name: #{domain}" unless domain =~ %r{\A\*?[\w.-]+\z}
      end
    end
  end

  newparam(:prefix) do
    desc 'Overrides the global KV prefix ($acme_kvstore::prefix) for this certificate.'
  end

  newparam(:backend_config) do
    desc <<-EOT
      Fully resolved backend connection details (Hash), including "prefix". Usually assembled by
      acme_kvstore::certificate.
    EOT
    validate do |value|
      raise ArgumentError, 'backend_config must be a Hash' unless value.is_a?(Hash)
    end
  end

  newparam(:area_secret) do
    desc '32-byte area secret (raw, hex or base64) for AES-256-GCM encryption of the private key.'
  end

  newparam(:key_type) do
    desc 'Private key algorithm, passed through to acme.sh.'
    newvalues(:rsa, :ec)
    defaultto :rsa
  end

  newparam(:key_size) do
    desc 'RSA key length in bits, or EC curve (256/384) when key_type = ec.'
    defaultto 2048
    validate do |value|
      raise ArgumentError, 'key_size must be numeric' unless value.to_s =~ %r{\A\d+\z}
    end
  end

  newparam(:purge_key_on_mismatch, boolean: true) do
    desc <<-EOT
      Whether a changed key_type/key_size forces an immediate reissue with a new key (true, the
      default). With false, the new key settings only take effect at the next regular renewal. A
      changed domains list always forces an immediate reissue.
    EOT
    newvalues(:true, :false)
    defaultto :true
    # newvalues stores :true/:false symbols; munge to real booleans.
    munge { |value| [:true, true].include?(value) }
  end

  newparam(:store_issuers, boolean: true) do
    desc <<-EOT
      Whether to store each certificate of the chain acme.sh returns as an issuer entry of its own
      (certid = <cn>_<expiry date>, e.g. r11_2027-03-12) and record them in acme_renewal. With false, readers find the
      chain among the certificates already in the area (e.g. maintained in CCI-UI).
    EOT
    newvalues(:true, :false)
    defaultto :true
    munge { |value| [:true, true].include?(value) }
  end

  newparam(:renew_schedule) do
    desc <<-EOT
      Name of a `schedule` resource whose `range` and `weekday` limit when a due renewal may run
      (`period`/`repeat` are ignored). First issuance and configuration changes are not limited.
      Unset: any time.
    EOT
  end

  newparam(:renew_before_days) do
    desc 'The certificate is considered due for renewal when fewer than this many days remain until expiry.'
    defaultto 30
    validate do |value|
      raise ArgumentError, 'renew_before_days must be numeric' unless value.to_s =~ %r{\A\d+\z}
    end
  end

  newparam(:tags, array_matching: :all) do
    desc 'Free-form tags stored in the certificate document.'
    defaultto []
  end

  newparam(:dns_provider) do
    desc <<-EOT
      acme.sh DNS API hook name (e.g. 'dns_cf') for DNS-01 validation. If unset, --webroot is used.
      Usually resolved from a DNS profile by acme_kvstore::certificate.
    EOT
  end

  newparam(:dns_env) do
    desc 'Environment variables (Hash of NAME => value), set before invoking acme.sh (DNS API credentials).'
    defaultto({})
    validate do |value|
      raise ArgumentError, 'dns_env must be a Hash' unless value.is_a?(Hash)
    end
  end

  newparam(:dns_options) do
    desc <<-EOT
      Additional hook-specific options (Hash). The 'dnssleep' key becomes the --dnssleep CLI flag;
      every other key becomes an upper-cased environment variable for the DNS hook.
    EOT
    defaultto({})
    validate do |value|
      raise ArgumentError, 'dns_options must be a Hash' unless value.is_a?(Hash)
    end
  end

  newparam(:dnssleep) do
    desc <<-EOT
      DNS-01 only: seconds acme.sh waits for the TXT records to propagate (acme.sh --dnssleep).
      Always passed, so acme.sh never polls public DNS-over-HTTPS resolvers itself.
    EOT
    defaultto 60
    validate do |value|
      raise ArgumentError, 'dnssleep must be a positive number of seconds' unless value.to_s =~ %r{\A[1-9]\d*\z}
    end
  end

  newparam(:webroot) do
    desc <<-EOT
      HTTP-01 only: webroot directory acme.sh writes the challenge files to (acme.sh --webroot).
      Usually resolved from acme_kvstore::worker's webroot by acme_kvstore::certificate.
    EOT
    defaultto '/var/www/acme-challenge'
  end

  newparam(:log_file) do
    desc <<-EOT
      acme.sh log file (acme.sh --log). No log file is written when unset. Usually resolved from
      acme_kvstore::worker's acme_log_file by acme_kvstore::certificate.
    EOT
  end

  newparam(:log_level) do
    desc 'acme.sh log level (acme.sh --log-level): 1 (normal) or 2 (debug). Only used together with log_file.'
    defaultto 1
    newvalues(1, 2, '1', '2')
    munge(&:to_i)
  end

  newparam(:challenge_alias) do
    desc <<-EOT
      DNS alias mode: the domain whose DNS is actually queried for the _acme-challenge TXT record
      (acme.sh --challenge-alias). See docs/profiles.md.
    EOT
  end

  newparam(:domain_alias) do
    desc 'DNS alias mode: the domain alias used for validation (acme.sh --domain-alias). See docs/profiles.md.'
  end

  newparam(:acmesh_path) do
    desc 'Path to the acme.sh executable on the worker host.'
    defaultto '/root/.acme.sh/acme.sh'
  end

  newparam(:server) do
    desc <<-EOT
      ACME server/CA, passed through to acme.sh --server (e.g. 'letsencrypt', 'zerossl', or a URL).
      Usually resolved from a CA profile by acme_kvstore::certificate.
    EOT
    defaultto 'letsencrypt'
  end

  newparam(:account_email) do
    desc <<-EOT
      ACME account email registered with the CA (acme.sh --register-account -m). Usually resolved
      from a CA profile by acme_kvstore::certificate.
    EOT
  end

  newparam(:eab_kid) do
    desc 'External Account Binding key ID, required by some CAs (e.g. ZeroSSL, SSL.com, Google Public CA).'
  end

  newparam(:eab_hmac_key) do
    desc 'External Account Binding HMAC key, paired with eab_kid.'
  end

  newparam(:posthook_cmd) do
    desc <<-EOT
      An optional command run after a certificate has been successfully issued/renewed and stored.
      Runs on the ACME worker, which does not necessarily serve the certificate itself in this
      module's architecture - typical uses are notifying an external system or triggering
      redistribution to consumer nodes. Failure is logged but never fails the resource, since the
      certificate has already been issued and stored successfully by that point. See
      docs/profiles.md.
    EOT
  end

  newparam(:proxy) do
    desc <<-EOT
      HTTP(S) proxy used for all of acme.sh's outbound connections (to the ACME CA and any DNS API),
      e.g. 'proxy.example.com:3128' or a full URL. acme.sh has no dedicated CLI flag for this; it is
      implemented via the standard HTTP_PROXY/HTTPS_PROXY environment variables.
    EOT
  end

  newparam(:exec_timeout) do
    desc <<-EOT
      Maximum time in seconds any single acme.sh invocation (including account registration and any
      posthook_cmd) may run before being terminated. Should be higher than any configured dnssleep.
    EOT
    defaultto 300
    validate do |value|
      raise ArgumentError, 'exec_timeout must be a positive number of seconds' unless value.to_s =~ %r{\A[1-9]\d*\z}
    end
  end

  newparam(:run_as_user) do
    desc <<-EOT
      Run acme.sh (and posthook_cmd) as this user instead of the Puppet agent's own user (usually
      root). Accepts a username or a numeric UID. Usually resolved from acme_kvstore::worker by
      acme_kvstore::certificate.
    EOT
  end

  newparam(:run_as_group) do
    desc <<-EOT
      Run acme.sh (and posthook_cmd) as this group. Accepts a group name or a numeric GID. Usually
      resolved from acme_kvstore::worker by acme_kvstore::certificate.
    EOT
  end

  newparam(:run_as_home) do
    desc <<-EOT
      The HOME directory to use for the run_as_user account, so acme.sh finds its own account/config
      data. Usually resolved from acme_kvstore::worker by acme_kvstore::certificate.
    EOT
  end

  newparam(:client_id) do
    desc <<-EOT
      Value of the 'client' field in the stored JSON documents. Usually resolved from
      $acme_kvstore::kv_client by acme_kvstore::certificate.
    EOT
    defaultto 'puppet'
  end

  newparam(:updated_by) do
    desc <<-EOT
      Value of the 'updated_by' / 'created_by' fields. Defaults to this node's certname; usually
      resolved from $acme_kvstore::kv_updated_by or the worker's FQDN by acme_kvstore::certificate.
    EOT
    defaultto { Puppet[:certname] }
  end

  autorequire(:file) do
    [self[:acmesh_path]]
  end

  validate do
    raise Puppet::Error, "acme_kvstore_certificate[#{self[:certid]}]: 'domains' must not be empty" \
      if self[:domains].nil? || Array(self[:domains]).empty?
    raise Puppet::Error, "acme_kvstore_certificate[#{self[:certid]}]: 'area' is required" if self[:area].nil?

    if self[:dns_provider].to_s.empty? && Array(self[:domains]).any? { |d| d.to_s.start_with?('*') }
      raise Puppet::Error, "acme_kvstore_certificate[#{self[:certid]}]: wildcard domains require DNS-01 validation " \
                           '(set dns_provider), HTTP-01 cannot validate them'
    end
  end
end
