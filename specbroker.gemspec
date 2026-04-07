# frozen_string_literal: true

require_relative 'lib/specbroker/version'

Gem::Specification.new do |spec|
  spec.name = 'specbroker'
  spec.version = Specbroker::VERSION
  spec.authors = ['Ferran Basora']
  spec.summary = 'Distributed RSpec runner using Redis as a work queue'
  spec.description = 'A work-stealing distributed RSpec runner. Push spec file paths ' \
                     'to a Redis list, then multiple CI runners atomically steal batches ' \
                     'and execute them in-process via RSpec::Core::Runner.'
  spec.homepage = 'https://github.com/ferranbasora/specbroker'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0'

  spec.files = Dir['lib/**/*.rb', 'bin/*', 'LICENSE', 'README.md']
  spec.bindir = 'bin'
  spec.executables = ['specbroker']

  spec.add_dependency 'redis', '>= 4.6', '< 6'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rspec-core', '~> 3.0'
end
