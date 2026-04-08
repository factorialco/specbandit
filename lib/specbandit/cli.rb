# frozen_string_literal: true

require 'optparse'

module Specbandit
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
        puts "specbandit #{VERSION}"
        0
      else
        warn "Unknown command: #{command}"
        print_usage
        1
      end
    rescue Specbandit::Error => e
      warn "[specbandit] Error: #{e.message}"
      1
    rescue Redis::BaseError => e
      warn "[specbandit] Redis error: #{e.message}"
      1
    end

    private

    def run_push
      options = { pattern: nil }

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: specbandit push [options] [files...]'

        opts.on('--key KEY', 'Redis queue key (required, or set SPECBANDIT_KEY)') do |v|
          Specbandit.configuration.key = v
        end

        opts.on('--pattern PATTERN', "Glob pattern to resolve files (e.g. 'spec/**/*_spec.rb')") do |v|
          options[:pattern] = v
        end

        opts.on('--redis-url URL', 'Redis URL (default: redis://localhost:6379)') do |v|
          Specbandit.configuration.redis_url = v
        end

        opts.on('--key-ttl SECONDS', Integer, 'TTL for the Redis key in seconds (default: 21600 / 6 hours)') do |v|
          Specbandit.configuration.key_ttl = v
        end

        opts.on('-h', '--help', 'Show this help') do
          puts opts
          return 0
        end
      end

      parser.parse!(argv)
      Specbandit.configuration.validate!

      publisher = Publisher.new
      files_arg = argv.empty? ? [] : argv
      count = publisher.publish(files: files_arg, pattern: options[:pattern])

      count.positive? ? 0 : 1
    end

    def run_work
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: specbandit work [options]'

        opts.on('--key KEY', 'Redis queue key (required, or set SPECBANDIT_KEY)') do |v|
          Specbandit.configuration.key = v
        end

        opts.on('--batch-size N', Integer, 'Number of files to steal per batch (default: 5)') do |v|
          Specbandit.configuration.batch_size = v
        end

        opts.on('--redis-url URL', 'Redis URL (default: redis://localhost:6379)') do |v|
          Specbandit.configuration.redis_url = v
        end

        opts.on('--rspec-opts OPTS', 'Extra options to pass to RSpec (space-separated)') do |v|
          Specbandit.configuration.rspec_opts = v.split
        end

        opts.on('--key-rerun KEY', 'Per-runner rerun key for re-run support') do |v|
          Specbandit.configuration.key_rerun = v
        end

        opts.on('--key-rerun-ttl SECONDS', Integer, 'TTL for rerun key in seconds (default: 604800 / 1 week)') do |v|
          Specbandit.configuration.key_rerun_ttl = v
        end

        opts.on('-h', '--help', 'Show this help') do
          puts opts
          return 0
        end
      end

      parser.parse!(argv)
      Specbandit.configuration.validate!

      worker = Worker.new
      worker.run
    end

    def print_usage
      puts <<~USAGE
        specbandit v#{VERSION} - Distributed RSpec runner using Redis

        Usage:
          specbandit push [options] [files...]    Enqueue spec files into Redis
          specbandit work [options]               Steal and run spec file batches

        Push options:
          --key KEY            Redis queue key (required, or set SPECBANDIT_KEY)
          --pattern PATTERN    Glob pattern for file discovery (e.g. 'spec/**/*_spec.rb')
          --redis-url URL      Redis URL (default: redis://localhost:6379)
          --key-ttl SECONDS    TTL for the Redis key (default: 21600 / 6 hours)

        Work options:
          --key KEY            Redis queue key (required, or set SPECBANDIT_KEY)
          --batch-size N       Files per batch (default: 5, or set SPECBANDIT_BATCH_SIZE)
          --redis-url URL      Redis URL (default: redis://localhost:6379)
          --rspec-opts OPTS    Extra options forwarded to RSpec
          --key-rerun KEY      Per-runner rerun key for re-run support
          --key-rerun-ttl N    TTL for rerun key (default: 604800 / 1 week)

        Environment variables:
          SPECBANDIT_KEY              Queue key
          SPECBANDIT_REDIS_URL        Redis URL
          SPECBANDIT_BATCH_SIZE       Batch size
          SPECBANDIT_KEY_TTL          Key TTL in seconds (default: 21600)
          SPECBANDIT_RSPEC_OPTS       RSpec options
          SPECBANDIT_KEY_RERUN        Per-runner rerun key
          SPECBANDIT_KEY_RERUN_TTL    Rerun key TTL in seconds (default: 604800)

        File input priority for push:
          1. stdin (piped)     echo "spec/a_spec.rb" | specbandit push --key KEY
          2. --pattern         specbandit push --key KEY --pattern 'spec/**/*_spec.rb'
          3. direct args       specbandit push --key KEY spec/a_spec.rb spec/b_spec.rb
      USAGE
    end
  end
end
