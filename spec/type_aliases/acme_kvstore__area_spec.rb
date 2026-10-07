# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Area' do
  it { is_expected.to allow_value({ 'secret' => sensitive('S' * 32), 'consul_token' => sensitive('token') }) }
  it { is_expected.to allow_value({ 'secret' => 'S' * 32, 'redis_username' => 'acme-web', 'redis_password' => 'pw' }) }

  it do
    is_expected.to allow_value(
      {
        'secret' => 'S' * 32, 'consul_token' => sensitive('rw'), 'consul_read_token' => sensitive('ro'),
        'redis_read_username' => 'acme-web-read', 'redis_read_password' => sensitive('ro'),
      },
    )
  end

  it { is_expected.not_to allow_value({ 'consul_token' => 'token' }) }
  it { is_expected.not_to allow_value({ 'secret' => 'S' * 32, 'token' => 'typo-for-consul_token' }) }
end
