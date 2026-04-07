# frozen_string_literal: true

require 'redis'

module Specbroker
  class RedisQueue
    attr_reader :redis

    def initialize(redis_url: Specbroker.configuration.redis_url)
      @redis = Redis.new(url: redis_url)
    end

    # Push file paths onto the queue and set an expiry on the key.
    # Returns the new length of the list.
    def push(key, files, ttl: nil)
      return 0 if files.empty?

      count = redis.rpush(key, files)
      redis.expire(key, ttl) if ttl
      count
    end

    # Atomically steal up to `count` file paths from the queue.
    # Returns an array of file paths (empty array when exhausted).
    #
    # Uses LPOP with count argument (Redis 6.2+).
    def steal(key, count)
      result = redis.lpop(key, count)

      # LPOP returns nil when the key doesn't exist or list is empty,
      # and returns a single string (not array) when count is 1 on some versions.
      case result
      when nil then []
      when String then [result]
      else Array(result)
      end
    end

    # Returns the current length of the queue.
    def length(key)
      redis.llen(key)
    end

    def close
      redis.close
    end
  end
end
