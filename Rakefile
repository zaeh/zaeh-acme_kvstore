# frozen_string_literal: true

# Each Gemfile group's tasks load only if that group is installed.
begin
  require 'voxpupuli/test/rake'
rescue LoadError
  begin
    require 'puppetlabs_spec_helper/rake_tasks'
  rescue LoadError
    nil # neither is installed; only metadata_lint below will be available
  end
end

begin
  require 'voxpupuli/acceptance/rake'
rescue LoadError
  nil # :system_tests Gemfile group not installed
end

begin
  require 'voxpupuli/release/rake_tasks'
rescue LoadError
  nil # :release Gemfile group not installed
else
  GCGConfig.user = 'zaeh'
  GCGConfig.project = 'acme_kvstore'
end

# `pdk test unit` calls puppetlabs_spec_helper's task names, which
# voxpupuli-test >= 10 no longer defines.
if Rake::Task.task_defined?(:'fixtures:prep')
  require 'rspec/core/rake_task'

  task spec_prep: :'fixtures:prep' unless Rake::Task.task_defined?(:spec_prep)
  task spec_clean: :'fixtures:clean' unless Rake::Task.task_defined?(:spec_clean)
  task spec_standalone: :'spec:standalone' unless Rake::Task.task_defined?(:spec_standalone)
  task parallel_spec_standalone: :'parallel_spec:standalone' unless Rake::Task.task_defined?(:parallel_spec_standalone)

  unless Rake::Task.task_defined?(:spec_list_json)
    desc 'List spec tests in a JSON document (used by `pdk test unit --list`)'
    RSpec::Core::RakeTask.new(:spec_list_json) do |t|
      t.rspec_opts = ['--dry-run', '--format', 'json']
      t.pattern = 'spec/{aliases,classes,defines,functions,hosts,integration,plans,tasks,type_aliases,types,unit}/**/*_spec.rb'
    end
  end
end

desc 'Run metadata-json-lint'
task :metadata_lint do
  sh 'bundle exec metadata-json-lint metadata.json'
end

task default: Rake::Task.task_defined?(:test) ? %i[test metadata_lint] : %i[metadata_lint]
