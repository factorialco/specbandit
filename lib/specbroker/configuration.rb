# frozen_string_literal: true

module Specbroker
  class Configuration
    attr_accessor :redis_url, :batch_size, :key, :rspec_opts, :key_ttl,
                  :key_rerun, :key_rerun_ttl

    DEFAULT_REDIS_URL = 'redis://localhost:6379'
    DEFAULT_BATCH_SIZE = 5
    DEFAULT_KEY_TTL = 21_600 # 6 hours in seconds
    DEFAULT_KEY_RERUN_TTL = 604_800 # 1 week in seconds

    def initialize
      @redis_url = ENV.fetch('SPECBROKER_REDIS_URL', DEFAULT_REDIS_URL)
      @batch_size = Integer(ENV.fetch('SPECBROKER_BATCH_SIZE', DEFAULT_BATCH_SIZE))
      @key = ENV.fetch('SPECBROKER_KEY', nil)
      @rspec_opts = parse_rspec_opts(ENV.fetch('SPECBROKER_RSPEC_OPTS', nil))
      @key_ttl = Integer(ENV.fetch('SPECBROKER_KEY_TTL', DEFAULT_KEY_TTL))
      @key_rerun = ENV.fetch('SPECBROKER_KEY_RERUN', nil)
      @key_rerun_ttl = Integer(ENV.fetch('SPECBROKER_KEY_RERUN_TTL', DEFAULT_KEY_RERUN_TTL))
    end

    def validate!
      raise Error, 'key is required (set via --key or SPECBROKER_KEY)' if key.nil? || key.empty?
      raise Error, 'batch_size must be a positive integer' unless batch_size.positive?
      raise Error, 'key_ttl must be a positive integer' unless key_ttl.positive?
      raise Error, 'key_rerun_ttl must be a positive integer' unless key_rerun_ttl.positive?
    end

    private

    def parse_rspec_opts(opts)
      return [] if opts.nil? || opts.empty?

      opts.split
    end
  end
end
