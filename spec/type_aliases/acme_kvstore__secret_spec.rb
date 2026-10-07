# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Secret' do
  it { is_expected.to allow_values('plain-secret', sensitive('wrapped-secret')) }
  it { is_expected.not_to allow_values('', nil, 42) }
end
