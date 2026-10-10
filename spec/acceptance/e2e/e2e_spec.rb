# frozen_string_literal: true

require_relative 'e2e_helper'

# One scenario in order: each example builds on the state the previous ones left.
describe 'acme_kvstore end to end (OpenVox server, ACME worker, consumer)', order: :defined do
  let(:doc) { PuppetX::AcmeKvstore::KvDocument }

  before(:all) { E2eEnv.configure }

  def run_agent(node, expected)
    code, output = E2eEnv.agent(node)
    expect(code).to eq(expected), "puppet agent on #{node} exited #{code}, expected #{expected}:\n#{output}"
    expect(output).not_to match(%r{^Warning:}), "puppet agent on #{node} warned:\n#{output}"
    output
  end

  def kv(backend)
    AcceptanceEnv.kv_client(backend, 'web', 'write')
  end

  def read(backend, suffix)
    kv(backend).read_multi(["#{AcceptanceEnv::PREFIX}/web/#{suffix}"]).values.first
  end

  def meta(backend)
    read(backend, "certids/#{E2eEnv::CERTIDS.fetch(backend)}")
  end

  def active_pem(backend)
    read(backend, "certs/#{E2eEnv::CERTIDS.fetch(backend)}/#{meta(backend).fetch('active_version')}").fetch('pem')
  end

  def deployed(backend, name)
    E2eEnv.node_exec('consumer', 'cat', "#{E2eEnv.deploy_dir(backend)}/#{name}")
  end

  def certs(pem)
    doc.split_pem(pem).map { |part| OpenSSL::X509::Certificate.new(part) }
  end

  def change_status(backend, status)
    suffix = "web/certids/#{E2eEnv::CERTIDS.fetch(backend)}"
    kv(backend).transactional_update(AcceptanceEnv::PREFIX, suffix) { |current| { suffix => current.merge('status' => status) } }
  end

  it 'issues both certificates on the first worker run, as the dedicated acme user' do
    run_agent('worker', 2)

    expect(E2eEnv.node_exec('worker', 'stat', '-c', '%U', '/home/acme/.acme.sh').strip).to eq('acme')
    E2eEnv::CERTIDS.each do |backend, certid|
      renewal = meta(backend).fetch('acme_renewal')
      expect(meta(backend)).to include('status' => 'active', 'active_version' => 1, 'updated_by' => E2eEnv::WORKER)
      expect(renewal).to include('domains' => ["#{certid}.example.test"], 'key_type' => 'ec', 'key_size' => 256)
      expect(read(backend, "certids/#{renewal.fetch('issuers').first}")).to include('status' => 'active')
    end
  end

  it 'changes nothing on the second worker run' do
    run_agent('worker', 0)
    expect(E2eEnv::CERTIDS.keys.map { |backend| meta(backend)['active_version'] }).to eq([1, 1])
  end

  it 'deploys certificate, key, chain, combined file and DH parameters on the consumer' do
    run_agent('consumer', 2)

    dh = File.read(File.expand_path('../../../files/dhparams/ffdhe2048.pem', __dir__))
    E2eEnv::CERTIDS.each_key do |backend|
      cert = deployed(backend, 'cert.pem')
      expect(cert).to eq(active_pem(backend))
      leaf = OpenSSL::X509::Certificate.new(cert)
      key = deployed(backend, 'key.pem')
      expect(leaf.check_private_key(OpenSSL::PKey.read(key))).to be(true)
      expect(E2eEnv.node_exec('consumer', 'stat', '-c', '%a', "#{E2eEnv.deploy_dir(backend)}/key.pem").strip).to eq('600')

      chain = certs(deployed(backend, 'chain.pem'))
      expect(chain.size).to eq(1)
      expect(leaf.verify(chain.first.public_key)).to be(true)
      expect(deployed(backend, 'fullchain.pem')).to eq(cert + deployed(backend, 'chain.pem'))
      expect(deployed(backend, 'combined.pem')).to eq(deployed(backend, 'fullchain.pem') + key)
      expect(deployed(backend, 'dh.pem')).to eq(dh)
    end
  end

  it "writes deploy's mock certificate, compiled under the server's JRuby" do
    cert = OpenSSL::X509::Certificate.new(E2eEnv.node_exec('consumer', 'cat', "#{E2eEnv::MOCK_DIR}/cert.pem"))
    fullchain = certs(E2eEnv.node_exec('consumer', 'cat', "#{E2eEnv::MOCK_DIR}/fullchain.pem"))
    root = OpenSSL::X509::Certificate.new(File.read(File.expand_path('../../../files/mock/root.pem', __dir__)))
    store = OpenSSL::X509::Store.new
    store.add_cert(root)

    expect(cert.subject.to_a.assoc('CN')[1]).to eq('e2e-mock')
    expect(store.verify(cert, fullchain.drop(1))).to be(true)
    expect(cert.check_private_key(OpenSSL::PKey.read(E2eEnv.node_exec('consumer', 'cat', "#{E2eEnv::MOCK_DIR}/key.pem")))).to be(true)
    # The same certificate as MRI builds: deterministic on the server too.
    expect(cert.to_pem).to eq(PuppetX::AcmeKvstore::MockCert.leaf_pem('e2e-mock'))
  end

  it 'changes nothing on the second consumer run' do
    run_agent('consumer', 0)
  end

  it 'renews when the configuration asks for it, and the consumer follows' do
    old_cert = deployed(:consul, 'cert.pem')
    certificates = E2eEnv.default_certificates
    certificates['e2e-consul']['renew_before_days'] = 3650
    E2eEnv.configure(certificates)
    run_agent('worker', 2)
    E2eEnv.configure
    expect(meta(:consul)).to include('active_version' => 2)
    expect(meta(:redis)).to include('active_version' => 1)

    run_agent('consumer', 2)
    expect(deployed(:consul, 'cert.pem')).to eq(active_pem(:consul))
    expect(deployed(:consul, 'cert.pem')).not_to eq(old_cert)
    run_agent('worker', 0)
  end

  it "leaves the files alone for status 'norollout' and removes them for 'delete'" do
    change_status(:consul, 'norollout')
    run_agent('consumer', 0)
    expect(deployed(:consul, 'cert.pem')).to eq(active_pem(:consul))

    change_status(:redis, 'delete')
    run_agent('consumer', 2)
    expect(E2eEnv.node_exec('consumer', 'ls', E2eEnv.deploy_dir(:redis)).split).to be_empty
    expect(deployed(:consul, 'cert.pem')).to eq(active_pem(:consul))
  end
end
