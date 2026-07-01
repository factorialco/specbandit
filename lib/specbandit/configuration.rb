# frozen_string_literal: true

module Specbandit
  class Configuration
    attr_accessor :redis_url, :batch_size, :key, :rspec_opts, :key_ttl,
                  :key_rerun, :verbose,
                  :adapter, :command, :command_opts,
                  :key_failed, :report

    DEFAULT_REDIS_URL = 'redis://localhost:6379'
    DEFAULT_BATCH_SIZE = 5
    # A single TTL governs every key specbandit writes: the shared queue, its
    # published marker, the per-runner rerun key and the failed key. It defaults
    # to 1 week because re-runs can happen hours or days after the original run,
    # and the rerun key + published marker must still be alive when they do.
    DEFAULT_KEY_TTL = 604_800 # 1 week in seconds
    DEFAULT_ADAPTER = 'cli'

    def initialize
      @redis_url = ENV.fetch('SPECBANDIT_REDIS_URL', DEFAULT_REDIS_URL)
      @batch_size = Integer(ENV.fetch('SPECBANDIT_BATCH_SIZE', DEFAULT_BATCH_SIZE))
      @key = ENV.fetch('SPECBANDIT_KEY', nil)
      @rspec_opts = parse_rspec_opts(ENV.fetch('SPECBANDIT_RSPEC_OPTS', nil))
      @key_ttl = Integer(ENV.fetch('SPECBANDIT_KEY_TTL', DEFAULT_KEY_TTL))
      @key_rerun = ENV.fetch('SPECBANDIT_KEY_RERUN', nil)
      @verbose = env_truthy?('SPECBANDIT_VERBOSE')
      @adapter = ENV.fetch('SPECBANDIT_ADAPTER', DEFAULT_ADAPTER)
      @command = ENV.fetch('SPECBANDIT_COMMAND', nil)
      @command_opts = parse_space_separated(ENV.fetch('SPECBANDIT_COMMAND_OPTS', nil))
      @key_failed = ENV.fetch('SPECBANDIT_KEY_FAILED', nil)
      @report = ENV.fetch('SPECBANDIT_REPORT', nil)
    end

    def validate!
      raise Error, 'key is required (set via --key or SPECBANDIT_KEY)' if key.nil? || key.empty?
      raise Error, 'batch_size must be a positive integer' unless batch_size.positive?
      raise Error, 'key_ttl must be a positive integer' unless key_ttl.positive?
    end

    private

    def parse_rspec_opts(opts)
      return [] if opts.nil? || opts.empty?

      opts.split
    end

    def parse_space_separated(value)
      return [] if value.nil? || value.empty?

      value.split
    end

    def env_truthy?(name)
      %w[1 true yes].include?(ENV.fetch(name, '').downcase)
    end
  end
end
