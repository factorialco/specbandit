# frozen_string_literal: true

module Specbroker
  class Configuration
    attr_accessor :redis_url, :batch_size, :key, :rspec_opts

    DEFAULT_REDIS_URL = 'redis://localhost:6379'
    DEFAULT_BATCH_SIZE = 5

    def initialize
      @redis_url = ENV.fetch('SPECBROKER_REDIS_URL', DEFAULT_REDIS_URL)
      @batch_size = Integer(ENV.fetch('SPECBROKER_BATCH_SIZE', DEFAULT_BATCH_SIZE))
      @key = ENV.fetch('SPECBROKER_KEY', nil)
      @rspec_opts = parse_rspec_opts(ENV.fetch('SPECBROKER_RSPEC_OPTS', nil))
    end

    def validate!
      raise Error, 'key is required (set via --key or SPECBROKER_KEY)' if key.nil? || key.empty?
      raise Error, 'batch_size must be a positive integer' unless batch_size.positive?
    end

    private

    def parse_rspec_opts(opts)
      return [] if opts.nil? || opts.empty?

      opts.split
    end
  end
end
