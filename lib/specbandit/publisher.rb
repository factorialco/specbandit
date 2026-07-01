# frozen_string_literal: true

require 'io/wait'

module Specbandit
  class Publisher
    attr_reader :queue, :key, :key_ttl, :output

    def initialize(key: Specbandit.configuration.key, key_ttl: Specbandit.configuration.key_ttl, queue: nil,
                   output: $stdout)
      @key = key
      @key_ttl = key_ttl
      @queue = queue || RedisQueue.new
      @output = output
    end

    # Resolve files from the three input sources (priority: stdin > pattern > args)
    # and push them onto the Redis queue.
    #
    # Returns the number of files enqueued.
    def publish(files: [], pattern: nil)
      resolved = resolve_files(files: files, pattern: pattern)

      if resolved.empty?
        output.puts '[specbandit] No files to enqueue.'
        return 0
      end

      push_ms = measure { queue.push(key, resolved, ttl: key_ttl) }
      # Record a durable "published" marker so workers can tell a drained
      # queue ("worker arriving late", OK) apart from one that was never
      # pushed ("you didn't push work", crash). Redis auto-deletes empty
      # lists, so the list itself cannot carry this signal.
      mark_ms = measure { queue.mark_published(key, ttl: key_ttl) }

      output.puts "[specbandit] Enqueued #{resolved.size} files onto key '#{key}' (TTL: #{key_ttl}s)."
      output.puts format('[specbandit] Redis latency: push %.1fms, publish-marker %.1fms (total %.1fms).',
                         push_ms, mark_ms, push_ms + mark_ms)
      resolved.size
    end

    private

    # Run the block and return the wall-clock time it took, in milliseconds.
    # Used to surface how long the Redis round-trips took in the push log.
    def measure
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    end

    def resolve_files(files:, pattern:)
      # Priority 1: stdin (only when data is actually piped in)
      if !$stdin.tty? && $stdin.ready?
        stdin_files = $stdin.each_line.map(&:strip).reject(&:empty?)
        return stdin_files if stdin_files.any?
      end

      # Priority 2: --pattern flag (Dir.glob in Ruby, no shell expansion)
      return Dir.glob(pattern).sort if pattern && !pattern.empty?

      # Priority 3: direct file arguments
      Array(files)
    end
  end
end
