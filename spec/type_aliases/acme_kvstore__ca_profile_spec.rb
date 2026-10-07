# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Ca_profile' do
  it { is_expected.to allow_values({}, { 'directory_url' => 'https://ca.example.com/acme/directory', 'account_email' => 'ssl@example.com' }) }
  it { is_expected.to allow_value({ 'eab_kid' => sensitive('kid'), 'eab_hmac_key' => sensitive('hmac') }) }

  it 'requires an https directory URL' do
    is_expected.not_to allow_value({ 'directory_url' => 'http://ca.example.com/acme/directory' })
  end
end
