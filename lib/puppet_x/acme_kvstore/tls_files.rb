# frozen_string_literal: true

require 'puppet_x'
require 'etc'

module PuppetX::AcmeKvstore
  # The ca_file/cert_file/key_file of the KV clients are read by the process
  # running the client: the Puppet agent (root) on a worker, the Puppet server
  # (user puppet) for lookup_cert and acme_kvstore::deploy. A file that cannot
  # be read fails with that hint instead of a bare ENOENT/EACCES.
  module TlsFiles
    # @return [String] path, after checking it can be read
    def self.check(path, setting:, backend:, error_class:)
      File.open(path, 'r', &:close)
      path
    rescue SystemCallError => e
      raise error_class, "#{backend} #{setting} '#{path}' cannot be read on this host as user '#{user}' (#{e.class.name.split('::').last}). " \
                         'acme_kvstore::lookup_cert and acme_kvstore::deploy read it on the Puppet server, the worker as root ' \
                         "on the agent; see docs/#{backend.downcase}.md#tls-files"
    end

    # Explicit keywords: anonymous ** forwarding needs Ruby 3.2, the server's JRuby 9.4 is 3.1.
    def self.read(path, setting:, backend:, error_class:)
      File.read(check(path, setting:, backend:, error_class:))
    end

    def self.user
      Etc.getpwuid(Process.euid).name
    rescue StandardError
      Process.euid.to_s
    end
  end
end
