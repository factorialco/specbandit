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
        opts.banner = 'Usage: specbandit work [options] [-- extra-opts...]'

        opts.on('--key KEY', 'Redis queue key (required, or set SPECBANDIT_KEY)') do |v|
          Specbandit.configuration.key = v
        end

        opts.on('--adapter TYPE', 'Adapter type: cli (default) or rspec') do |v|
          Specbandit.configuration.adapter = v
        end

        opts.on('--command CMD', 'Command to run with file paths (required for cli adapter)') do |v|
          Specbandit.configuration.command = v
        end

        opts.on('--command-opts OPTS', 'Extra options forwarded to the command (space-separated)') do |v|
          Specbandit.configuration.command_opts = v.split
        end

        opts.on('--batch-size N', Integer, 'Number of files to steal per batch (default: 5)') do |v|
          Specbandit.configuration.batch_size = v
        end

        opts.on('--redis-url URL', 'Redis URL (default: redis://localhost:6379)') do |v|
          Specbandit.configuration.redis_url = v
        end

        opts.on('--rspec-opts OPTS', 'Extra options to pass to RSpec (for rspec adapter, space-separated)') do |v|
          Specbandit.configuration.rspec_opts = v.split
        end

        opts.on('--key-rerun KEY', 'Per-runner rerun key for re-run support') do |v|
          Specbandit.configuration.key_rerun = v
        end

        opts.on('--key-rerun-ttl SECONDS', Integer, 'TTL for rerun key in seconds (default: 604800 / 1 week)') do |v|
          Specbandit.configuration.key_rerun_ttl = v
        end

        opts.on('--key-failed KEY', 'Redis key to record failed test files for later review') do |v|
          Specbandit.configuration.key_failed = v
        end

        opts.on('--key-failed-ttl SECONDS', Integer, 'TTL for failed key in seconds (default: 604800 / 1 week)') do |v|
          Specbandit.configuration.key_failed_ttl = v
        end

        opts.on('--rerun', 'Signal this is a re-run (fail hard if rerun key is empty)') do
          Specbandit.configuration.rerun = true
        end

        opts.on('--report FILE', 'Write JSON report with run statistics to FILE') do |v|
          Specbandit.configuration.report = v
        end

        opts.on('--verbose', 'Show per-batch file list and full command output (default: quiet)') do
          Specbandit.configuration.verbose = true
        end

        opts.on('-h', '--help', 'Show this help') do
          puts opts
          return 0
        end
      end

      parser.parse!(argv)

      # Remaining args after `--` are forwarded to the adapter.
      # They are merged with --command-opts or --rspec-opts depending on the adapter.
      extra_opts = argv.any? ? argv : []

      config = Specbandit.configuration
      adapter = build_adapter(config, extra_opts)

      config.validate!

      worker = Worker.new(adapter: adapter)
      worker.run
    end

    # Build the appropriate adapter based on configuration.
    #
    # --adapter rspec  -> RspecAdapter (runs RSpec programmatically in-process)
    # --adapter cli    -> CliAdapter (default, spawns shell commands)
    # (no --adapter)   -> CliAdapter (backward compatible with specbanditjs)
    def build_adapter(config, extra_opts)
      adapter_type = config.adapter.downcase

      case adapter_type
      when 'rspec'
        rspec_opts = config.rspec_opts + extra_opts
        RspecAdapter.new(
          rspec_opts: rspec_opts,
          verbose: config.verbose,
          output: $stdout
        )
      when 'cli'
        unless config.command
          raise Error, 'command is required for CLI adapter (set via --command or SPECBANDIT_COMMAND)'
        end

        command_opts = config.command_opts + extra_opts
        CliAdapter.new(
          command: config.command,
          command_opts: command_opts,
          verbose: config.verbose,
          output: $stdout
        )
      else
        raise Error, "Unknown adapter: #{adapter_type}. Supported: cli, rspec"
      end
    end

    def print_usage
      puts <<~USAGE
        specbandit v#{VERSION} - Distributed test runner using Redis

        Usage:
          specbandit push [options] [files...]           Enqueue test files into Redis
          specbandit work [options] [-- extra-opts...]   Steal and run test file batches

        Push options:
          --key KEY              Redis queue key (required, or set SPECBANDIT_KEY)
          --pattern PATTERN      Glob pattern for file discovery (e.g. 'spec/**/*_spec.rb')
          --redis-url URL        Redis URL (default: redis://localhost:6379)
          --key-ttl SECONDS      TTL for the Redis key (default: 21600 / 6 hours)

        Work options:
          --key KEY              Redis queue key (required, or set SPECBANDIT_KEY)
          --adapter TYPE         Adapter type: 'cli' (default) or 'rspec'
          --command CMD          Command to run with file paths (required for cli adapter)
          --command-opts OPTS    Extra options forwarded to the command (space-separated)
          --rspec-opts OPTS      Extra options forwarded to RSpec (for rspec adapter)
          --batch-size N         Files per batch (default: 5, or set SPECBANDIT_BATCH_SIZE)
          --redis-url URL        Redis URL (default: redis://localhost:6379)
           --key-rerun KEY        Per-runner rerun key for re-run support
           --key-rerun-ttl N      TTL for rerun key (default: 604800 / 1 week)
           --key-failed KEY       Redis key to record failed test files
           --key-failed-ttl N     TTL for failed key (default: 604800 / 1 week)
           --rerun                Signal this is a re-run (fail hard if rerun key is empty)
          --report FILE          Write JSON report to FILE after run
          --verbose              Show per-batch file list and full command output

          Arguments after -- are forwarded to the adapter (rspec opts, command opts, etc.).
          They are merged with --command-opts or --rspec-opts if both are provided.

        Environment variables:
          SPECBANDIT_KEY              Queue key
          SPECBANDIT_REDIS_URL        Redis URL
          SPECBANDIT_ADAPTER          Adapter type (cli/rspec)
          SPECBANDIT_COMMAND          Command to run (cli adapter)
          SPECBANDIT_COMMAND_OPTS     Command options (space-separated)
          SPECBANDIT_BATCH_SIZE       Batch size
          SPECBANDIT_KEY_TTL          Key TTL in seconds (default: 21600)
          SPECBANDIT_RSPEC_OPTS       RSpec options (rspec adapter)
          SPECBANDIT_KEY_RERUN        Per-runner rerun key
          SPECBANDIT_KEY_RERUN_TTL    Rerun key TTL in seconds (default: 604800)
          SPECBANDIT_KEY_FAILED       Redis key for failed test files
          SPECBANDIT_KEY_FAILED_TTL   Failed key TTL in seconds (default: 604800)
          SPECBANDIT_RERUN            Signal re-run mode (1/true/yes)
          SPECBANDIT_VERBOSE          Enable verbose output (1/true/yes)
          SPECBANDIT_REPORT           Path to write JSON report file

        File input priority for push:
          1. stdin (piped)     echo "spec/a_spec.rb" | specbandit push --key KEY
          2. --pattern         specbandit push --key KEY --pattern 'spec/**/*_spec.rb'
          3. direct args       specbandit push --key KEY spec/a_spec.rb spec/b_spec.rb

        Adapters:
          cli   (default) Spawns a shell command for each batch. Works with any test runner.
                Requires --command.
          rspec Runs RSpec programmatically in-process. No process startup overhead per batch.
                Requires rspec-core ~> 3.0.
      USAGE
    end
  end
end
