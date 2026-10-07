# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Area_name' do
  it { is_expected.to allow_values('web', 'zone_a', 'a', "a#{'b' * 47}") }

  it 'rejects what CCI-UI rejects' do
    is_expected.not_to allow_values('web-public', 'Web', '1web', '_web', '', "a#{'b' * 48}")
  end
end
