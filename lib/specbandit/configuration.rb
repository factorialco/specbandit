# frozen_string_literal: true

module Specbandit
  class Configuration
    attr_accessor :redis_url, :batch_size, :key, :rspec_opts, :key_ttl,
                  :key_rerun, :verbose,
                  :adapter, :command, :command_opts,
                  :key_failed, :report,
                  :redis_max_attempts, :redis_connect_timeout, :redis_timeout,
                  :redis_reconnect_attempts

    DEFAULT_REDIS_URL = 'redis://localhost:6379'
    DEFAULT_BATCH_SIZE = 5
    # A single TTL governs every key specbandit writes: the shared queue, its
    # published marker, the per-runner rerun key and the failed key. It defaults
    # to 1 week because re-runs can happen hours or days after the original run,
    # and the rerun key + published marker must still be alive when they do.
    DEFAULT_KEY_TTL = 604_800 # 1 week in seconds
    DEFAULT_ADAPTER = 'cli'

    # Redis connection resilience. Redis is a best-effort coordination store for
    # a distributed test run, and CI runners can sit a WAN hop away from it
    # (e.g. cross-datacenter mesh), so a transient blip must not red the build.
    # We retry a handful of times with capped exponential backoff, and give the
    # underlying client explicit connect/read/write timeouts + reconnects rather
    # than relying on library defaults.
    DEFAULT_REDIS_MAX_ATTEMPTS = 5
    DEFAULT_REDIS_CONNECT_TIMEOUT = 3.0
    # 10s rather than 5s: CI Redis latency spikes past 5s under load, and a
    # timed-out-but-executed command is exactly the event that used to lose
    # queue items (see RedisQueue::STEAL_SCRIPT). The steal is retry-safe now,
    # but a wider timeout keeps retries (and their log noise) rare.
    DEFAULT_REDIS_TIMEOUT = 10.0
    DEFAULT_REDIS_RECONNECT_ATTEMPTS = 3

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

      @redis_max_attempts = Integer(ENV.fetch('SPECBANDIT_REDIS_MAX_ATTEMPTS', DEFAULT_REDIS_MAX_ATTEMPTS))
      @redis_connect_timeout = Float(ENV.fetch('SPECBANDIT_REDIS_CONNECT_TIMEOUT', DEFAULT_REDIS_CONNECT_TIMEOUT))
      @redis_timeout = Float(ENV.fetch('SPECBANDIT_REDIS_TIMEOUT', DEFAULT_REDIS_TIMEOUT))
      @redis_reconnect_attempts = Integer(ENV.fetch('SPECBANDIT_REDIS_RECONNECT_ATTEMPTS', DEFAULT_REDIS_RECONNECT_ATTEMPTS))
    end

    def validate!
      raise Error, 'key is required (set via --key or SPECBANDIT_KEY)' if key.nil? || key.empty?
      raise Error, 'batch_size must be a positive integer' unless batch_size.positive?
      raise Error, 'key_ttl must be a positive integer' unless key_ttl.positive?
      raise Error, 'redis_max_attempts must be a positive integer' unless redis_max_attempts.positive?
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
