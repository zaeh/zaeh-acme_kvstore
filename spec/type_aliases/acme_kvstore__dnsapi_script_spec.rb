# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Dnsapi_script' do
  it 'accepts a file source or inline content' do
    is_expected.to allow_values(
      { 'source' => 'puppet:///modules/profile/acme/dns_rockenstein.sh' },
      { 'source' => '/srv/acme/dns_rockenstein.sh' },
      { 'content' => "dns_rockenstein_add() { :; }\n" },
    )
  end

  it 'requires exactly one of source and content' do
    is_expected.not_to allow_values(
      {},
      { 'source' => '/srv/acme/dns_rockenstein.sh', 'content' => 'x' },
    )
  end

  it { is_expected.not_to allow_value({ 'source' => 'relative/dns_rockenstein.sh' }) }
  it { is_expected.not_to allow_value({ 'content' => '' }) }
end
