# frozen_string_literal: true

# Acceptance tests against real Consul, Redis and acme.sh (talking to Pebble),
# run in containers from spec/acceptance/compose.yml; needs Docker with the
# compose plugin. Not part of `rake test`.
namespace :acceptance do
  compose = ['docker', 'compose', '-f', File.expand_path('../spec/acceptance/compose.yml', __dir__)]
  # The e2e profile adds the OpenVox server, worker and consumer.
  e2e = [*compose, '--profile', 'e2e']

  desc 'Start Consul, Redis and Pebble for the acceptance tests'
  task :up do
    sh(*compose, 'up', '-d', '--wait')
  end

  desc 'Run the acceptance tests (services must be up and fresh)'
  task :run do
    sh RbConfig.ruby, '-S', 'rspec', '--pattern', 'spec/acceptance/*_spec.rb'
  end

  desc 'Stop and remove all acceptance test services'
  task :down do
    sh(*e2e, 'down', '-v')
  end

  desc 'Run the end-to-end tests in fresh containers: OpenVox server, ACME worker, consumer (E2E_OS=ubuntu24.04|rocky9)'
  task e2e: :spec_prep do
    Rake::Task['acceptance:down'].invoke # a previous run's leftovers
    sh(*e2e, 'up', '-d', '--build', '--wait')
    begin
      sh RbConfig.ruby, '-S', 'rspec', '--pattern', 'spec/acceptance/e2e/*_spec.rb'
    ensure
      Rake::Task['acceptance:down'].reenable
      Rake::Task['acceptance:down'].invoke
    end
  end
end

desc 'Run the acceptance tests in fresh containers (up, run, down)'
task :acceptance do
  Rake::Task['acceptance:down'].invoke # a previous run's leftovers
  Rake::Task['acceptance:up'].invoke
  begin
    Rake::Task['acceptance:run'].invoke
  ensure
    Rake::Task['acceptance:down'].reenable
    Rake::Task['acceptance:down'].invoke
  end
end
