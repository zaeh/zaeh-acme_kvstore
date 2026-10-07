# frozen_string_literal: true

require 'puppet_x'
require 'time'
require 'openssl'
require 'puppet_x/acme_kvstore/acmesh'
require 'puppet_x/acme_kvstore/crypto'
require 'puppet_x/acme_kvstore/kv_document'

module PuppetX::AcmeKvstore
  # Workflow of the acme_kvstore_certificate providers (Consul and Redis
  # differ only in #kv_client). Per run: one read of the meta document
  # (#state); if needed, acme.sh and one compare-and-set write based on
  # that read - a concurrent change raises CasConflictError and the next
  # run retries. Only meta documents with 'acme_renewal' are renewed;
  # 'status' only controls distribution. See docs/architecture.md.
  module ProviderCommon
    def exists?
      meta = state[:value]
      return false if meta.nil?

      summary = meta['acme_renewal']
      if summary.nil?
        return false unless resource[:ensure] == :present

        Puppet.warning("acme_kvstore_certificate[#{resource[:certid]}]: #{current_prefix}/" \
                       "#{kv_doc.meta_path(resource[:area], resource[:certid])} exists but was not issued by " \
                       'acme_kvstore (no acme_renewal); not renewing or overwriting it')
        return true
      end

      # With ensure => absent, a soon-expiring certificate must still
      # "exist", or Puppet would never call #destroy.
      return true unless resource[:ensure] == :present

      if meta['archived'] == true
        Puppet.info("acme_kvstore_certificate[#{resource[:certid]}]: archived (CCI-UI); not renewing it")
        return true
      end

      summary = active_summary(meta, summary)
      return false if config_drifted?(summary)
      return true unless renewal_due?(summary['not_after'])
      return false if in_renew_window?

      Puppet.info("acme_kvstore_certificate[#{resource[:certid]}]: renewal due, outside schedule '#{resource[:renew_schedule]}'")
      true
    end

    def create
      certid = resource[:certid]
      area   = resource[:area]

      result = PuppetX::AcmeKvstore::Acmesh.issue_or_renew(
        dnssleep: resource[:dnssleep],
        webroot: resource[:webroot],
        log_file: resource[:log_file],
        log_level: resource[:log_level],
        domains: resource[:domains],
        key_type: resource[:key_type],
        key_size: resource[:key_size],
        server: resource[:server],
        dns_provider: resource[:dns_provider],
        dns_env: resource[:dns_env],
        dns_options: resource[:dns_options],
        challenge_alias: resource[:challenge_alias],
        domain_alias: resource[:domain_alias],
        account_email: resource[:account_email],
        eab_kid: resource[:eab_kid],
        eab_hmac_key: resource[:eab_hmac_key],
        proxy: resource[:proxy],
        exec_timeout: resource[:exec_timeout],
        run_as_user: resource[:run_as_user],
        run_as_group: resource[:run_as_group],
        run_as_home: resource[:run_as_home],
        acmesh_path: resource[:acmesh_path],
      )
      raise Puppet::Error, "acme.sh did not return a certificate for '#{certid}'" if result[:cert].nil?

      leaf = kv_doc.split_pem(result[:cert]).first
      # Before the certificate, so its chain is always stored when it is.
      issuers = resource[:store_issuers] ? store_issuers(area, result[:chain]) : nil

      write(area, certid) do |existing_meta|
        next_version = existing_meta ? existing_meta['latest_version'].to_i + 1 : 1
        now = kv_doc.now_iso8601
        summary = renewal_summary(leaf, next_version, issuers)

        cert_doc = kv_doc.certificate(
          pem:        leaf.to_pem,
          tags:       resource[:tags],
          has_key:    !result[:key].nil?,
          created_at: now,
          client:     resource[:client_id],
          created_by: resource[:updated_by],
        )

        writes = { kv_doc.cert_path(area, certid, next_version) => cert_doc }

        if result[:key]
          secret = PuppetX::AcmeKvstore::Crypto.decode_area_secret(resource[:area_secret])
          writes[kv_doc.key_path(area, certid, next_version)] = PuppetX::AcmeKvstore::Crypto.encrypt(
            result[:key], secret, aad: PuppetX::AcmeKvstore::Crypto.aad(area, certid, next_version)
          )
        end

        # A new entry starts as 'active'; an existing status is never changed here.
        writes[kv_doc.meta_path(area, certid)] = (existing_meta || {}).merge(
          kv_doc.meta(
            active_version: next_version,
            latest_version: next_version,
            status:         existing_meta ? existing_meta['status'] : 'active',
            updated_at:     now,
            client:         resource[:client_id],
            updated_by:     resource[:updated_by],
            acme_renewal:   summary,
          ),
        )

        writes
      end

      run_posthook

      true
    end

    # Only stops renewal by removing 'acme_renewal'; status and versions stay.
    def destroy
      certid = resource[:certid]
      area   = resource[:area]

      write(area, certid) do |existing_meta|
        next nil if existing_meta.nil?

        updated_meta = existing_meta.except('acme_renewal').merge(
          'updated_at' => kv_doc.now_iso8601,
          'updated_by' => resource[:updated_by],
        )
        { kv_doc.meta_path(area, certid) => updated_meta }
      end

      true
    end

    private

    # The meta document with its CAS token ({ value:, index: }), read once per run.
    def state
      @state ||= begin
        key = "#{current_prefix}/#{kv_doc.meta_path(resource[:area], resource[:certid])}"
        kv_client.read_multi_with_index([key])[key]
      end
    end

    # CAS write based on #state, so the meta document is not read again.
    def write(area, certid, &)
      kv_client.transactional_update(current_prefix, kv_doc.meta_path(area, certid), expected: @state, &)
    ensure
      @state = nil
    end

    def renewal_summary(leaf, version, issuers)
      kv_doc.renewal_summary(
        not_after: leaf.not_after,
        domains:   resource[:domains],
        key_type:  resource[:key_type],
        key_size:  resource[:key_size],
        version:,
        issuers:,
      )
    end

    # acme_renewal describes the version this module issued; if another one
    # was activated meanwhile (e.g. in CCI-UI), the decision uses that
    # certificate itself (one extra read, until the next issuance).
    def active_summary(meta, summary)
      return summary if summary['version'].nil? || summary['version'] == meta['active_version']

      key = "#{current_prefix}/#{kv_doc.cert_path(resource[:area], resource[:certid], meta['active_version'])}"
      doc = kv_client.read_multi([key])[key]
      return summary.merge('not_after' => nil) if doc.nil?

      kv_doc.summary_of(OpenSSL::X509::Certificate.new(doc['pem']), version: meta['active_version'])
    end

    # Stores each chain certificate as its own entry, named
    # <cn>_<expiry date> (see KvDocument.issuer_certid), unless it is
    # already stored; existing entries are never touched.
    #
    # @return [Array<String>] the chain's certids, issuer of the leaf first
    def store_issuers(area, chain_pem)
      certs = kv_doc.split_pem(chain_pem)
      return [] if certs.empty?

      candidates = certs.map { |cert| [kv_doc.issuer_certid(cert), kv_doc.issuer_certid_alternative(cert)] }
      metas = kv_client.read_multi_with_index(candidates.flatten.uniq.map { |certid| issuer_key(kv_doc.meta_path(area, certid)) })
      stored = stored_fingerprints(area, metas)

      certs.zip(candidates).map do |cert, names|
        fingerprint = kv_doc.fingerprint(cert)
        reuse = names.find { |certid| stored[certid] == fingerprint }
        next reuse if reuse

        free = names.find { |certid| metas[issuer_key(kv_doc.meta_path(area, certid))][:value].nil? }
        raise Puppet::Error, "acme_kvstore_certificate[#{resource[:certid]}]: #{names.join(' and ')} hold other certificates" if free.nil?

        store_issuer(area, free, cert, metas[issuer_key(kv_doc.meta_path(area, free))])
        free
      end
    end

    # certid => SHA-256 fingerprint of the active version, for the existing entries.
    def stored_fingerprints(area, metas)
      active = metas.filter_map do |key, entry|
        next if entry[:value].nil?

        certid = key.split('/').last
        [certid, issuer_key(kv_doc.cert_path(area, certid, entry[:value]['active_version']))]
      end.to_h
      return {} if active.empty?

      docs = kv_client.read_multi(active.values)
      active.to_h do |certid, cert_key|
        pem = docs[cert_key]&.fetch('pem', nil)
        [certid, pem && kv_doc.fingerprint(OpenSSL::X509::Certificate.new(pem))]
      end
    end

    def issuer_key(suffix)
      "#{current_prefix}/#{suffix}"
    end

    def store_issuer(area, certid, cert, expected)
      now = kv_doc.now_iso8601
      kv_client.transactional_update(current_prefix, kv_doc.meta_path(area, certid), expected:) do |current|
        next nil unless current.nil?

        {
          kv_doc.meta_path(area, certid) => kv_doc.meta(
            active_version: 1, latest_version: 1, status: 'active', updated_at: now,
            client: resource[:client_id], updated_by: resource[:updated_by]
          ),
          kv_doc.cert_path(area, certid, 1) => kv_doc.certificate(
            pem: cert.to_pem, has_key: false, created_at: now, client: resource[:client_id], created_by: resource[:updated_by],
          ),
        }
      end
    rescue StandardError => e
      # Stored concurrently by another worker or CCI-UI: just as good.
      raise unless e.class.name.to_s.end_with?('::CasConflictError')
    end

    # Only the schedule's range and weekday count: a due renewal happens
    # once, so period/repeat have no meaning here.
    def in_renew_window?
      name = resource[:renew_schedule]
      return true if name.nil?

      schedule = resource.catalog&.resource(:schedule, name)
      raise Puppet::Error, "acme_kvstore_certificate[#{resource[:certid]}]: schedule '#{name}' not found" if schedule.nil?

      now = Time.now
      %i[range weekday].all? do |param|
        value = schedule.parameter(param)
        value.nil? || value.match?(nil, now)
      end
    end

    def kv_doc
      PuppetX::AcmeKvstore::KvDocument
    end

    def current_prefix
      resource[:prefix] || resource[:backend_config]['prefix']
    end

    def renewal_due?(not_after)
      return true if not_after.nil?

      (Time.parse(not_after) - Time.now) < (resource[:renew_before_days].to_i * 86_400)
    rescue ArgumentError
      true
    end

    # A changed primary domain (the first entry) or set of names always
    # forces a reissue; a changed key_type/key_size only with
    # purge_key_on_mismatch. Without stored domains nothing is compared.
    def config_drifted?(summary)
      return false if summary['domains'].nil?

      stored = Array(summary['domains'])
      wanted = Array(resource[:domains])
      return true unless stored.first == wanted.first && stored.sort == wanted.sort
      return false unless resource[:purge_key_on_mismatch]
      return true unless summary['key_type'].to_s == resource[:key_type].to_s
      return true unless summary['key_size'].to_i == resource[:key_size].to_i

      false
    end

    # Only logged on failure: the certificate is already issued and stored.
    def run_posthook
      cmd = resource[:posthook_cmd]
      return if cmd.nil? || cmd.to_s.empty?

      PuppetX::AcmeKvstore::Acmesh.run_posthook(
        cmd, timeout: resource[:exec_timeout], run_as_user: resource[:run_as_user], run_as_group: resource[:run_as_group]
      )
    rescue PuppetX::AcmeKvstore::Acmesh::Error => e
      Puppet.warning("acme_kvstore_certificate[#{resource[:certid]}]: posthook_cmd failed: #{e.message}")
    end
  end
end
