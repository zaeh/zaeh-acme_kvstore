# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Consul_config' do
  it { is_expected.to allow_values({}, { 'url' => 'https://consul.example.com:8501', 'ca_file' => '/etc/ssl/ca.pem', 'insecure' => false }) }
  it { is_expected.not_to allow_value({ 'url' => 'https://consul.example.com:8501', 'token' => 'global' }) }
  it { is_expected.not_to allow_value({ 'url' => 'consul.example.com' }) }
  it { is_expected.not_to allow_value({ 'ca_file' => 'relative/ca.pem' }) }
end
