# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Certificate_params' do
  it { is_expected.to allow_value({ 'domain' => 'shop.example.com' }) }

  it do
    is_expected.to allow_value(
      {
        'domain' => '*.example.com', 'subject_alt_names' => ['example.com'], 'use_dns_profile' => 'cloudflare',
        'key_type' => 'ec', 'key_size' => 384, 'renew_before_days' => 21, 'worker' => 'worker1.example.com',
      },
    )
  end

  it { is_expected.not_to allow_value({ 'subject_alt_names' => ['example.com'] }) }
  it { is_expected.not_to allow_value({ 'domains' => ['shop.example.com'] }) }
  it { is_expected.not_to allow_value({ 'domain' => 'shop.example.com', 'subject_alt_names' => 'www.shop.example.com' }) }
  it { is_expected.not_to allow_value({ 'domain' => 'shop.example.com', 'key_type' => 'dsa' }) }

  it 'has exactly the parameters of acme_kvstore::certificate (except certid, which is the key)' do
    root = File.expand_path('../..', __dir__)
    signature = File.read(File.join(root, 'manifests/certificate.pp'))[%r{^define acme_kvstore::certificate \((.*?)^\) \{}m, 1]
    define_params = signature.lines.filter_map { |line| line[%r{\$(\w+)\s*[=,]}, 1] } - ['certid']
    type_keys = File.read(File.join(root, 'types/certificate_params.pp')).scan(%r{^\s+(?:Optional\[')?(\w+)'?\]?\s+=>}).flatten

    expect(type_keys).to match_array(define_params)
  end
end
