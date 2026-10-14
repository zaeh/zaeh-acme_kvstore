# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'puppet_x/acme_kvstore/tls_files'

describe PuppetX::AcmeKvstore::TlsFiles do
  let(:dir) { Dir.mktmpdir('acme_kvstore-tls') }
  let(:error_class) { Class.new(StandardError) }
  let(:options) { { setting: 'ca_file', backend: 'Consul', error_class: } }

  after { FileUtils.rm_rf(dir) }

  it 'returns the path of a readable file, and reads it' do
    path = File.join(dir, 'ca.pem').tap { |file| File.write(file, 'PEM') }
    expect(described_class.check(path, **options)).to eq(path)
    expect(described_class.read(path, **options)).to eq('PEM')
  end

  it "names the setting, the path, this host's user and where the file is read" do
    path = File.join(dir, 'missing.pem')
    expect { described_class.check(path, **options) }.to raise_error(error_class) do |error|
      expect(error.message).to include("Consul ca_file '#{path}' cannot be read on this host as user '#{described_class.user}' (ENOENT)")
      expect(error.message).to include('on the Puppet server', 'docs/consul.md#tls-files')
    end
  end
end
