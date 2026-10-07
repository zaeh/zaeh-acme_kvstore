# frozen_string_literal: true

require 'digest'
require 'net/http'
require 'rbconfig'
require 'tmpdir'

# lookup_cert/deploy compile on the Puppet/OpenVox server, i.e. under
# JRuby: OpenVox Server 8 bundles JRuby 9.4.15.0 (Java 11+), 9 bundles
# JRuby 10.1.2.0 (Java 21+).
namespace :jruby do
  desc 'Check the lookup-side code under JRuby (JRUBY_COMPAT_VERSION, default 9.4.15.0; needs java)'
  task :compat do
    version = ENV.fetch('JRUBY_COMPAT_VERSION', '9.4.15.0')
    jar = fetch_jruby_jar(version)
    script = File.expand_path('jruby_compat.rb', __dir__)
    Dir.mktmpdir('jruby_compat') do |dir|
      sh RbConfig.ruby, script, 'fixture', dir
      # A clean environment: RUBYOPT, RUBYLIB, GEM_* and BUNDLE_* belong to MRI and Bundler.
      puts "java -jar #{jar} #{script} check"
      sh(ENV.to_h.slice('PATH', 'HOME', 'JAVA_HOME'), 'java', '-jar', jar, script, 'check', dir, unsetenv_others: true, verbose: false)
      sh RbConfig.ruby, script, 'check-back', dir
    end
  end
end

# Downloads jruby-complete from Maven Central once, verified by its SHA-256.
def fetch_jruby_jar(version)
  dir = File.expand_path('../vendor/jruby', __dir__)
  jar = File.join(dir, "jruby-complete-#{version}.jar")
  return jar if File.exist?(jar)

  url = "https://repo1.maven.org/maven2/org/jruby/jruby-complete/#{version}/jruby-complete-#{version}.jar"
  expected = http_get("#{url}.sha256").split.first
  data = http_get(url)
  raise "SHA-256 mismatch for #{url}" unless Digest::SHA256.hexdigest(data) == expected

  FileUtils.mkdir_p(dir)
  File.binwrite("#{jar}.tmp", data)
  File.rename("#{jar}.tmp", jar)
  jar
end

def http_get(url)
  response = Net::HTTP.get_response(URI(url))
  raise "GET #{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body
end
