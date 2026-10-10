# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Ca_profile' do
  it { is_expected.to allow_values({}, { 'directory_url' => 'https://ca.example.com/acme/directory', 'account_email' => 'ssl@example.com' }) }
  it { is_expected.to allow_value({ 'eab_kid' => sensitive('kid'), 'eab_hmac_key' => sensitive('hmac') }) }

  it { is_expected.to allow_value({ 'ca_certificates' => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n" }) }
  it { is_expected.to allow_value({ 'ca_bundle' => '/etc/pki/tls/certs/internal-ca.pem' }) }
  it { is_expected.not_to allow_value({ 'ca_certificates' => 'not a certificate' }) }
  it { is_expected.not_to allow_value({ 'ca_bundle' => 'relative/ca.pem' }) }

  it 'requires an https directory URL' do
    is_expected.not_to allow_value({ 'directory_url' => 'http://ca.example.com/acme/directory' })
  end
end
