# frozen_string_literal: true

require 'optparse'

module Specbroker
  class CLI
    COMMANDS = %w[push work].freeze

    def self.run(argv = ARGV)
      new(argv).execute
    end

    attr_reader :argv

    def initialize(argv)
      @argv = argv.dup
    end

    def execute
      command = argv.shift

      case command
      when 'push'
        run_push
      when 'work'
        run_work
      when nil, '-h', '--help'
        print_usage
        0
      when '-v', '--version'
        puts "specbroker #{VERSION}"
        0
      else
        warn "Unknown command: #{command}"
        print_usage
        1
      end
    rescue Specbroker::Error => e
      warn "[specbroker] Error: #{e.message}"
      1
    rescue Redis::BaseError => e
      warn "[specbroker] Redis error: #{e.message}"
      1
    end

    private

    def run_push
      options = { pattern: nil }

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: specbroker push [options] [files...]'

        opts.on('--key KEY', 'Redis queue key (required, or set SPECBROKER_KEY)') do |v|
          Specbroker.configuration.key = v
        end

        opts.on('--pattern PATTERN', "Glob pattern to resolve files (e.g. 'spec/**/*_spec.rb')") do |v|
          options[:pattern] = v
        end

        opts.on('--redis-url URL', 'Redis URL (default: redis://localhost:6379)') do |v|
          Specbroker.configuration.redis_url = v
        end

        opts.on('--key-ttl SECONDS', Integer, 'TTL for the Redis key in seconds (default: 21600 / 6 hours)') do |v|
          Specbroker.configuration.key_ttl = v
        end

        opts.on('-h', '--help', 'Show this help') do
          puts opts
          return 0
        end
      end

      parser.parse!(argv)
      Specbroker.configuration.validate!

      publisher = Publisher.new
      files_arg = argv.empty? ? [] : argv
      count = publisher.publish(files: files_arg, pattern: options[:pattern])

      count.positive? ? 0 : 1
    end

    def run_work
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: specbroker work [options]'

        opts.on('--key KEY', 'Redis queue key (required, or set SPECBROKER_KEY)') do |v|
          Specbroker.configuration.key = v
        end

        opts.on('--batch-size N', Integer, 'Number of files to steal per batch (default: 5)') do |v|
          Specbroker.configuration.batch_size = v
        end

        opts.on('--redis-url URL', 'Redis URL (default: redis://localhost:6379)') do |v|
          Specbroker.configuration.redis_url = v
        end

        opts.on('--rspec-opts OPTS', 'Extra options to pass to RSpec (space-separated)') do |v|
          Specbroker.configuration.rspec_opts = v.split
        end

        opts.on('--key-rerun KEY', 'Per-runner rerun key for re-run support') do |v|
          Specbroker.configuration.key_rerun = v
        end

        opts.on('--key-rerun-ttl SECONDS', Integer, 'TTL for rerun key in seconds (default: 604800 / 1 week)') do |v|
          Specbroker.configuration.key_rerun_ttl = v
        end

        opts.on('-h', '--help', 'Show this help') do
          puts opts
          return 0
        end
      end

      parser.parse!(argv)
      Specbroker.configuration.validate!

      worker = Worker.new
      worker.run
    end

    def print_usage
      puts <<~USAGE
        specbroker v#{VERSION} - Distributed RSpec runner using Redis

        Usage:
          specbroker push [options] [files...]    Enqueue spec files into Redis
          specbroker work [options]               Steal and run spec file batches

        Push options:
          --key KEY            Redis queue key (required, or set SPECBROKER_KEY)
          --pattern PATTERN    Glob pattern for file discovery (e.g. 'spec/**/*_spec.rb')
          --redis-url URL      Redis URL (default: redis://localhost:6379)
          --key-ttl SECONDS    TTL for the Redis key (default: 21600 / 6 hours)

        Work options:
          --key KEY            Redis queue key (required, or set SPECBROKER_KEY)
          --batch-size N       Files per batch (default: 5, or set SPECBROKER_BATCH_SIZE)
          --redis-url URL      Redis URL (default: redis://localhost:6379)
          --rspec-opts OPTS    Extra options forwarded to RSpec
          --key-rerun KEY      Per-runner rerun key for re-run support
          --key-rerun-ttl N    TTL for rerun key (default: 604800 / 1 week)

        Environment variables:
          SPECBROKER_KEY              Queue key
          SPECBROKER_REDIS_URL        Redis URL
          SPECBROKER_BATCH_SIZE       Batch size
          SPECBROKER_KEY_TTL          Key TTL in seconds (default: 21600)
          SPECBROKER_RSPEC_OPTS       RSpec options
          SPECBROKER_KEY_RERUN        Per-runner rerun key
          SPECBROKER_KEY_RERUN_TTL    Rerun key TTL in seconds (default: 604800)

        File input priority for push:
          1. stdin (piped)     echo "spec/a_spec.rb" | specbroker push --key KEY
          2. --pattern         specbroker push --key KEY --pattern 'spec/**/*_spec.rb'
          3. direct args       specbroker push --key KEY spec/a_spec.rb spec/b_spec.rb
      USAGE
    end
  end
end
