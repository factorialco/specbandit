# frozen_string_literal: true

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

      queue.push(key, resolved, ttl: key_ttl)
      output.puts "[specbandit] Enqueued #{resolved.size} files onto key '#{key}' (TTL: #{key_ttl}s)."
      resolved.size
    end

    private

    def resolve_files(files:, pattern:)
      # Priority 1: stdin (if not a TTY)
      return $stdin.each_line.map(&:strip).reject(&:empty?) unless $stdin.tty?

      # Priority 2: --pattern flag (Dir.glob in Ruby, no shell expansion)
      return Dir.glob(pattern).sort if pattern && !pattern.empty?

      # Priority 3: direct file arguments
      Array(files)
    end
  end
end
