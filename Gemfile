# frozen_string_literal: true

# GEM_SOURCE: an internal mirror, if needed.
source ENV['GEM_SOURCE'] || 'https://rubygems.org'

# OpenVox, not the puppet gem: Voxpupuli's tooling depends on it, and both
# gems together would conflict. OPENVOX_GEM_VERSION='~> 9.0' (under Ruby 4.0)
# tests the OpenVox 9 lane.
# An empty value (e.g. from a CI matrix) counts as unset.
openvox_version = ENV.fetch('OPENVOX_GEM_VERSION', '').strip
gem 'openvox', openvox_version.empty? ? '~> 8.0' : openvox_version

group :test do
  gem 'metadata-json-lint', require: false
  # Pinned exactly: REFERENCE.md is committed and CI checks it, so a new
  # strings release must not change its format unannounced. To update: raise
  # the pin, regenerate REFERENCE.md and commit both together.
  gem 'openvox-strings', '7.2.0', require: false
  # runtime dependency of the Redis provider
  gem 'redis', '~> 5.0'
  # rspec-puppet, fixtures, lint, strings and the shared RuboCop config
  gem 'voxpupuli-test', '~> 14.0'
end

group :development do
  gem 'guard-rake', require: false
end

# No acceptance tests yet (they would need a real Consul/Redis).
group :system_tests do
  gem 'voxpupuli-acceptance', require: false
end

group :release do
  gem 'voxpupuli-release', require: false
end

# Machine-local additions: Gemfile.local or ~/.gemfile
extra_gemfiles = [
  "#{__FILE__}.local",
  File.join(Dir.home, '.gemfile'),
]
extra_gemfiles.each do |gemfile|
  next unless File.file?(gemfile) && File.readable?(gemfile)

  # rubocop:disable Security/Eval
  eval(File.read(gemfile), binding)
  # rubocop:enable Security/Eval
end
