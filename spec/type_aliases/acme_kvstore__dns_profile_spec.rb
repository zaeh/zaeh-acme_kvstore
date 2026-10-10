# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Dns_profile' do
  it { is_expected.to allow_value({ 'hook' => 'dns_cf', 'env' => { 'CF_Token' => sensitive('x') } }) }
  it { is_expected.to allow_value({ 'hook' => 'dns_aws', 'options' => { 'dnssleep' => 15 }, 'challenge_alias' => 'validation.example.com' }) }

  it 'rejects puppet-acme style short hook names' do
    is_expected.not_to allow_value({ 'hook' => 'aws' })
  end

  it { is_expected.not_to allow_value({ 'hook' => 'dns_cf', 'challenge_alias' => 'not a domain' }) }

  it 'does not take a script itself (see Acme_kvstore::Dnsapi_script)' do
    is_expected.not_to allow_value({ 'hook' => 'dns_rockenstein', 'hook_source' => '/srv/acme/dns_rockenstein.sh' })
  end

  it 'accepts CA certificates as PEM or as a file' do
    is_expected.to allow_value({ 'hook' => 'dns_infoblox', 'ca_certificates' => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n" })
    is_expected.to allow_value({ 'hook' => 'dns_infoblox', 'ca_bundle' => '/etc/pki/infoblox-ca.pem' })
    is_expected.not_to allow_value({ 'hook' => 'dns_infoblox', 'ca_bundle' => 'infoblox-ca.pem' })
  end
end
