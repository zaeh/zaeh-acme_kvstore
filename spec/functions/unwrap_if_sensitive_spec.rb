# frozen_string_literal: true

require 'spec_helper'

describe 'acme_kvstore::unwrap_if_sensitive' do
  it 'returns a plain string unchanged' do
    is_expected.to run.with_params('plain-value').and_return('plain-value')
  end

  it 'unwraps a Sensitive[String] to its plain value' do
    is_expected.to run.with_params(Puppet::Pops::Types::PSensitiveType::Sensitive.new('secret-value'))
                      .and_return('secret-value')
  end

  it 'returns undef unchanged' do
    is_expected.to run.with_params(nil).and_return(nil)
  end
end
