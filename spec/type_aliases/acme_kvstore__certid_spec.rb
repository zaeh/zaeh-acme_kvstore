# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Certid' do
  it { is_expected.to allow_values('shop-example-com', 'shop.example.com', 'wildcard_example_com', 'a' * 120, 'f' * 64) }
  it { is_expected.not_to allow_values('shop/example', 'shop example', '*.example.com', '', 'a' * 121) }
end
