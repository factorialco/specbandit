# frozen_string_literal: true

require 'redis'

module Specbandit
  class RedisQueue
    attr_reader :redis

    def initialize(redis_url: Specbandit.configuration.redis_url)
      @redis = Redis.new(url: redis_url)
    end

    MAX_ATTEMPTS = 3

    # Push file paths onto the queue and set an expiry on the key.
    # Returns the new length of the list.
    def push(key, files, ttl: nil)
      return 0 if files.empty?

      with_retries do
        count = redis.rpush(key, files)
        redis.expire(key, ttl) if ttl
        count
      end
    end

    # Atomically steal up to `count` file paths from the queue.
    # Returns an array of file paths (empty array when exhausted).
    #
    # Uses LPOP with count argument (Redis 6.2+).
    def steal(key, count)
      result = with_retries { redis.lpop(key, count) }

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
      with_retries { redis.llen(key) }
    end

    # Mark a queue key as "published" by setting a companion marker key.
    #
    # The marker is a separate string key (`<key>:published`) that survives
    # the queue list being fully drained. It is the source of truth for
    # "was work ever pushed for this key?" -- Redis auto-deletes empty lists,
    # so the list alone cannot distinguish "never pushed" from "drained".
    def mark_published(key, ttl: nil)
      with_retries do
        if ttl
          redis.set(published_marker(key), '1', ex: ttl)
        else
          redis.set(published_marker(key), '1')
        end
      end
    end

    # Whether a queue key has been published (its marker exists).
    def published?(key)
      with_retries { redis.exists?(published_marker(key)) }
    end

    # Read all file paths from the list non-destructively.
    # Returns an array of file paths (empty array when key doesn't exist).
    def read_all(key)
      with_retries { redis.lrange(key, 0, -1) }
    end

    def close
      redis.close
    end

    private

    # Companion marker key name for a given queue key.
    def published_marker(key)
      "#{key}:published"
    end

    def with_retries(attempts: MAX_ATTEMPTS)
      retries = 0
      begin
        yield
      rescue Redis::BaseConnectionError => e
        retries += 1
        raise if retries >= attempts

        delay = 2**retries
        warn "[specbandit] Redis connection failed (attempt #{retries}/#{attempts}): #{e.message}. Retrying in #{delay}s..."
        sleep(delay)
        retry
      end
    end
  end
end
