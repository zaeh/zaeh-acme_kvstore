# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'puppet_x/acme_kvstore/acmesh'

# A minimal stand-in for the Thread-like object Open3.popen3 yields as its
# fourth block argument, faithfully emulating just enough of #join/#value
# for Acmesh.run_with_timeout: #join(timeout) returns nil exactly once when
# `hang` is set (simulating a call that doesn't finish within the timeout),
# then truthy afterwards (simulating the process having since exited, e.g.
# after being sent TERM/KILL).
class FakeWaitThr
  attr_reader :pid

  def initialize(pid:, status:, hang: false)
    @pid = pid
    @status = status
    @hang = hang
    @joins = 0
  end

  def join(_timeout = nil)
    @joins += 1
    return nil if @hang && @joins == 1

    self
  end

  def value
    @status
  end
end

describe PuppetX::AcmeKvstore::Acmesh do
  let(:acmesh_path) { '/root/.acme.sh/acme.sh' }
  let(:base_args) do
    {
      domains: ['shop.example.com'], key_type: 'rsa', key_size: 2048, server: 'letsencrypt',
      dns_provider: nil, dns_env: {}, dns_options: {}, challenge_alias: nil, domain_alias: nil,
      account_email: nil, eab_kid: nil, eab_hmac_key: nil, acmesh_path:,
    }
  end
  let(:success) { instance_double(Process::Status, success?: true, exitstatus: 0) }

  before do
    allow(File).to receive(:executable?).with(acmesh_path).and_return(true)
  end

  # Stubs every Open3.popen3 call: records (env, *cmd) in `calls`, writes a
  # fake certificate to any requested --cert-file path (acme.sh's real side
  # effect that .issue_or_renew reads back afterwards), and yields fake
  # stdin/stdout/stderr/wait_thr to the block - exactly what
  # Acmesh.run_with_timeout expects from Open3.popen3.
  def stub_popen3(calls, status: success, hang: false, pid: 4242)
    allow(Open3).to receive(:popen3) do |*args, &block|
      # Open3.popen3(env, *cmd, opts) - opts (a Hash) is always the last
      # positional argument; strip it back off for the recorded call so
      # tests can assert on (env, cmd...) the same way regardless of it.
      spawn_opts = (args.last.is_a?(Hash) && args.length > 1) ? args.pop : {}
      calls << ({ args:, spawn_opts: })

      if args.include?('--cert-file')
        cert_file = args[args.index('--cert-file') + 1]
        File.write(cert_file, "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n")
      end

      stdin = instance_double(IO, close: nil)
      wait_thr = FakeWaitThr.new(pid:, status:, hang:)
      block.call(stdin, StringIO.new(''), StringIO.new(''), wait_thr)
    end
  end

  describe '.issue_or_renew' do
    it 'raises when no domains are given' do
      expect { described_class.issue_or_renew(**base_args, domains: []) }
        .to raise_error(described_class::Error, %r{at least one domain})
    end

    it 'raises when acme.sh is not executable' do
      allow(File).to receive(:executable?).with(acmesh_path).and_return(false)
      expect { described_class.issue_or_renew(**base_args) }
        .to raise_error(described_class::Error, %r{not found or not executable})
    end

    it 'does not attempt account registration when no account details are given' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args)

      expect(calls.size).to eq(1)
      expect(calls.first[:args]).to include('--issue')
    end

    it 'registers the account before issuing when account_email is given' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, account_email: 'ssl@example.com', server: 'zerossl')

      expect(calls.size).to eq(2)
      expect(calls[0][:args]).to include('--register-account', '-m', 'ssl@example.com', '--server', 'zerossl')
      expect(calls[1][:args]).to include('--issue', '--server', 'zerossl')
    end

    it 'passes EAB credentials to --register-account' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, server: 'zerossl', eab_kid: 'KID123', eab_hmac_key: 'HMAC456')

      expect(calls.first[:args]).to include('--register-account', '--eab-kid', 'KID123', '--eab-hmac-key', 'HMAC456')
    end

    it 'raises when account registration fails' do
      failure = instance_double(Process::Status, success?: false, exitstatus: 1)
      stub_popen3([], status: failure)

      expect { described_class.issue_or_renew(**base_args, account_email: 'ssl@example.com') }
        .to raise_error(described_class::Error, %r{account registration failed})
    end

    it 'adds --challenge-alias and --domain-alias when a DNS provider and aliases are given' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, dns_provider: 'dns_cf', challenge_alias: 'alias.example.com', domain_alias: 'domain-alias.example.com')

      issue_call = calls.find { |c| c[:args].include?('--issue') }
      expect(issue_call[:args]).to include('--challenge-alias', 'alias.example.com')
      expect(issue_call[:args]).to include('--domain-alias', 'domain-alias.example.com')
    end

    it 'passes dnssleep as a CLI flag and dns_options (except dnssleep) as upper-cased env vars' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, dns_provider: 'dns_nsupdate', dnssleep: 15,
                                                  dns_options: { 'dnssleep' => 99, 'nsupdate_zone' => 'example.com' })

      issue_call = calls.find { |c| c[:args].include?('--issue') }
      expect(issue_call[:args]).to include('--dnssleep', '15')
      expect(issue_call[:args]).not_to include('99')
      env = issue_call[:args].first
      expect(env['NSUPDATE_ZONE']).to eq('example.com')
      expect(env).not_to have_key('DNSSLEEP')
    end

    describe 'DNS-01 and wildcard certificates' do
      it 'issues a wildcard + apex certificate via DNS-01 with --dnssleep, so acme.sh does not poll public DNS itself' do
        calls = []
        stub_popen3(calls)

        described_class.issue_or_renew(**base_args, domains: ['*.example.com', 'example.com'], dns_provider: 'dns_cf',
                                                    dns_env: { 'CF_Token' => 'secret-token' }, dnssleep: 60)

        issue_call = calls.find { |c| c[:args].include?('--issue') }
        args = issue_call[:args]
        expect(args.each_cons(2).to_a).to include(['-d', '*.example.com'], ['-d', 'example.com'], ['--dns', 'dns_cf'], ['--dnssleep', '60'])
        expect(args).not_to include('--webroot')
        expect(args.first['CF_Token']).to eq('secret-token')
      end

      it 'rejects wildcard domains without a DNS hook before contacting the CA at all' do
        calls = []
        stub_popen3(calls)

        expect { described_class.issue_or_renew(**base_args, domains: ['*.example.com'], account_email: 'ssl@example.com') }
          .to raise_error(described_class::Error, %r{wildcard domains require DNS-01})
        expect(calls).to be_empty
      end

      it 'does not pass --dnssleep for HTTP-01' do
        calls = []
        stub_popen3(calls)

        described_class.issue_or_renew(**base_args, dnssleep: 60)

        expect(calls.first[:args]).not_to include('--dnssleep')
      end
    end

    it 'passes --log/--log-level to both account registration and issuance when log_file is given' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, account_email: 'ssl@example.com',
                                                  log_file: '/var/log/acme.sh/acme.log', log_level: 2)

      expect(calls.size).to eq(2)
      calls.each do |call|
        expect(call[:args].each_cons(2).to_a).to include(['--log', '/var/log/acme.sh/acme.log'], ['--log-level', '2'])
      end
    end

    it 'passes no --log arguments without a log_file' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, log_level: 2)

      expect(calls.first[:args]).not_to include('--log', '--log-level')
    end

    it 'sets HTTP(S)_PROXY env vars from proxy, defaulting to the http:// scheme' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, proxy: 'proxy.example.com:3128')

      env = calls.first[:args].first
      expect(env['HTTPS_PROXY']).to eq('http://proxy.example.com:3128')
      expect(env['http_proxy']).to eq('http://proxy.example.com:3128')
    end

    it 'keeps an explicit scheme in proxy unchanged' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, proxy: 'https://proxy.example.com:3128')

      expect(calls.first[:args].first['HTTPS_PROXY']).to eq('https://proxy.example.com:3128')
    end

    it 'runs as run_as_user/run_as_group via Process.spawn options, not affecting the calling process' do
      calls = []
      stub_popen3(calls)
      allow(Etc).to receive(:getpwnam).with('acme').and_return(instance_double(Etc::Passwd, uid: 1500))
      allow(Etc).to receive(:getgrnam).with('acme').and_return(instance_double(Etc::Group, gid: 1500))
      allow(File).to receive(:chown)

      described_class.issue_or_renew(**base_args, run_as_user: 'acme', run_as_group: 'acme')

      expect(calls.first[:spawn_opts]).to eq(uid: 'acme', gid: 'acme')
    end

    it 'sets HOME to run_as_home' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, run_as_home: '/home/acme/.acme.sh')

      expect(calls.first[:args].first['HOME']).to eq('/home/acme/.acme.sh')
    end

    it 'uses --webroot with the default webroot when no dns_provider is given' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args)

      expect(calls.first[:args].each_cons(2).to_a).to include(['--webroot', '/var/www/acme-challenge'])
    end

    it 'uses the configured webroot for HTTP-01' do
      calls = []
      stub_popen3(calls)

      described_class.issue_or_renew(**base_args, webroot: '/srv/acme-challenge')

      expect(calls.first[:args].each_cons(2).to_a).to include(['--webroot', '/srv/acme-challenge'])
    end

    it 'treats exit code 2 (renewal not yet due) as success' do
      not_due = instance_double(Process::Status, success?: false, exitstatus: 2)
      stub_popen3([], status: not_due)

      expect { described_class.issue_or_renew(**base_args) }.not_to raise_error
    end

    it 'raises with the captured output on any other failure' do
      failure = instance_double(Process::Status, success?: false, exitstatus: 1)
      allow(Open3).to receive(:popen3) do |*args, &block|
        args.pop if args.last.is_a?(Hash)
        block.call(instance_double(IO, close: nil), StringIO.new('out'), StringIO.new('err'),
                   FakeWaitThr.new(pid: 1, status: failure))
      end

      expect { described_class.issue_or_renew(**base_args) }.to raise_error(described_class::Error, %r{acme\.sh failed})
    end

    it 'terminates and raises when acme.sh does not finish within exec_timeout' do
      allow(described_class).to receive(:sleep)
      allow(Process).to receive(:kill)
      expect(Process).to receive(:kill).with('TERM', 9999)

      allow(Open3).to receive(:popen3) do |*args, &block|
        args.pop if args.last.is_a?(Hash)
        block.call(instance_double(IO, close: nil), StringIO.new(''), StringIO.new(''),
                   FakeWaitThr.new(pid: 9999, status: success, hang: true))
      end

      expect { described_class.issue_or_renew(**base_args, exec_timeout: 1) }
        .to raise_error(described_class::Error, %r{timed out after 1 seconds})
    end
  end

  describe '.run_posthook' do
    it 'runs the given command and raises on failure' do
      failure = instance_double(Process::Status, success?: false, exitstatus: 1)
      allow(Open3).to receive(:popen3) do |*args, &block|
        args.pop if args.last.is_a?(Hash)
        expect(args).to include('/usr/bin/notify-deploy')
        block.call(instance_double(IO, close: nil), StringIO.new(''), StringIO.new('boom'),
                   FakeWaitThr.new(pid: 1, status: failure))
      end

      expect { described_class.run_posthook('/usr/bin/notify-deploy') }
        .to raise_error(described_class::Error, %r{posthook_cmd failed})
    end

    it 'does not raise on success' do
      allow(Open3).to receive(:popen3) do |*args, &block|
        args.pop if args.last.is_a?(Hash)
        block.call(instance_double(IO, close: nil), StringIO.new(''), StringIO.new(''),
                   FakeWaitThr.new(pid: 1, status: success))
      end

      expect { described_class.run_posthook('/usr/bin/notify-deploy') }.not_to raise_error
    end
  end
end
