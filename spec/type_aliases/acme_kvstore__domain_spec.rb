# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Domain' do
  it { is_expected.to allow_values('shop.example.com', '*.example.com', 'xn--mnchen-3ya.example.com') }
  it { is_expected.not_to allow_values('', 'not a domain', '*.', 'shop.*.example.com', '**.example.com', ['shop.example.com']) }
end
