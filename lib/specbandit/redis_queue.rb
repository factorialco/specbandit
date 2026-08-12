# frozen_string_literal: true

require 'redis'

module Specbandit
  class RedisQueue
    attr_reader :redis

    # Cap the exponential backoff so a real outage degrades/fails within a
    # bounded window instead of sleeping for minutes on the last attempts.
    MAX_BACKOFF_SECONDS = 10

    def initialize(
      redis_url: Specbandit.configuration.redis_url,
      connect_timeout: Specbandit.configuration.redis_connect_timeout,
      read_timeout: Specbandit.configuration.redis_timeout,
      write_timeout: Specbandit.configuration.redis_timeout,
      reconnect_attempts: Specbandit.configuration.redis_reconnect_attempts,
      max_attempts: Specbandit.configuration.redis_max_attempts
    )
      @max_attempts = max_attempts
      @redis = Redis.new(
        url: redis_url,
        connect_timeout: connect_timeout,
        read_timeout: read_timeout,
        write_timeout: write_timeout,
        reconnect_attempts: reconnect_attempts
      )
    end

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

    # Remove a key entirely. Used to discard stale rerun memory when a
    # full rerun starts over from the shared queue.
    def delete(key)
      with_retries { redis.del(key) }
    end

    # Remove a queue and its published marker together, so the key is back to
    # the state it had before anything was ever pushed to it. A producer calls
    # this before pushing: the queue key is not scoped by run attempt, so a
    # second attempt would otherwise stack another copy of the work list on
    # top of whatever the first attempt left behind.
    #
    # Returns the number of keys removed (0, 1 or 2).
    def clear(key)
      with_retries { redis.del(key, published_marker(key)) }
    end

    def close
      redis.close
    end

    private

    # Companion marker key name for a given queue key.
    def published_marker(key)
      "#{key}:published"
    end

    def with_retries(attempts: @max_attempts)
      retries = 0
      begin
        yield
      rescue Redis::BaseConnectionError => e
        retries += 1
        raise if retries >= attempts

        delay = [2**retries, MAX_BACKOFF_SECONDS].min
        warn "[specbandit] Redis connection failed (attempt #{retries}/#{attempts}): #{e.message}. Retrying in #{delay}s..."
        sleep(delay)
        retry
      end
    end
  end
end
