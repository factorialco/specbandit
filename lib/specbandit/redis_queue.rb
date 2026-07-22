# frozen_string_literal: true

require 'digest'
require 'redis'

module Specbandit
  class RedisQueue
    attr_reader :redis

    # Cap the exponential backoff so a real outage degrades/fails within a
    # bounded window instead of sleeping for minutes on the last attempts.
    MAX_BACKOFF_SECONDS = 10

    # How long a steal's dedup key lives. It only needs to survive the retry
    # window of a single steal call (client reconnect retries + our
    # with_retries backoff, i.e. well under a minute), not the whole run.
    STEAL_DEDUP_TTL = 300

    # Atomic, idempotent steal.
    #
    # A bare LPOP is at-least-once from the server's perspective: if the
    # command executes but the response is lost (read timeout, connection
    # reset), any retry -- ours or the redis client's internal
    # reconnect_attempts retry -- issues a *second* LPOP and the first batch
    # silently evaporates. In CI that meant a green build with test/lint
    # units that never ran.
    #
    # This script makes the pop replay-safe: the popped batch is stored under
    # a caller-supplied dedup key in the same atomic step, so a retry of the
    # same steal (same token) returns the already-popped batch instead of
    # popping again. It also records the batch to the runner's rerun key
    # atomically, closing the old crash-between-steal-and-record hole.
    #
    #   KEYS[1] = queue key
    #   KEYS[2] = dedup key (unique per steal call)
    #   KEYS[3] = rerun key (optional)
    #   ARGV[1] = count
    #   ARGV[2] = dedup key TTL (seconds)
    #   ARGV[3] = rerun key TTL (seconds, only used when KEYS[3] is present)
    STEAL_SCRIPT = <<~LUA
      local cached = redis.call('LRANGE', KEYS[2], 0, -1)
      if #cached > 0 then
        return cached
      end
      local items = redis.call('LPOP', KEYS[1], tonumber(ARGV[1]))
      if items == false then
        return {}
      end
      if #items > 0 then
        redis.call('RPUSH', KEYS[2], unpack(items))
        redis.call('EXPIRE', KEYS[2], tonumber(ARGV[2]))
        if #KEYS >= 3 then
          redis.call('RPUSH', KEYS[3], unpack(items))
          redis.call('EXPIRE', KEYS[3], tonumber(ARGV[3]))
        end
      end
      return items
    LUA
    STEAL_SCRIPT_SHA = Digest::SHA1.hexdigest(STEAL_SCRIPT)

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
    # When `token` is given, the pop runs through STEAL_SCRIPT so that any
    # retry of the same call (same token) returns the already-popped batch
    # instead of popping again -- see the script docs above. `rerun_key`
    # (with `rerun_ttl`) additionally records the batch atomically for
    # re-run support.
    #
    # Without a token this is a bare LPOP (Redis 6.2+ count form), which can
    # lose a batch if the response to an executed pop is lost and the command
    # is retried. Callers should prefer the token form.
    def steal(key, count, token: nil, rerun_key: nil, ttl: nil)
      return steal_via_lpop(key, count) if token.nil?

      keys = [key, steal_dedup_key(key, token)]
      argv = [count, STEAL_DEDUP_TTL]
      if rerun_key
        keys << rerun_key
        argv << (ttl || Specbandit.configuration.key_ttl)
      end

      result = with_retries { eval_script(STEAL_SCRIPT, STEAL_SCRIPT_SHA, keys: keys, argv: argv) }
      Array(result)
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

    def steal_via_lpop(key, count)
      result = with_retries { redis.lpop(key, count) }

      # LPOP returns nil when the key doesn't exist or list is empty,
      # and returns a single string (not array) when count is 1 on some versions.
      case result
      when nil then []
      when String then [result]
      else Array(result)
      end
    end

    # EVALSHA first (script is almost always cached), falling back to EVAL on
    # NOSCRIPT (fresh server, script cache flushed).
    def eval_script(script, sha, keys:, argv:)
      redis.evalsha(sha, keys: keys, argv: argv)
    rescue Redis::CommandError => e
      raise unless e.message.include?('NOSCRIPT')

      redis.eval(script, keys: keys, argv: argv)
    end

    def steal_dedup_key(key, token)
      "#{key}:steal:#{token}"
    end

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
