# frozen_string_literal: true

require 'spec_helper'

describe 'Acme_kvstore::Redis_config' do
  it { is_expected.to allow_values({}, { 'host' => 'redis.example.com', 'port' => 6380, 'tls' => true, 'db' => 0 }) }
  it { is_expected.not_to allow_value({ 'host' => 'redis.example.com', 'password' => 'global' }) }
  it { is_expected.not_to allow_value({ 'port' => 70_000 }) }
end
