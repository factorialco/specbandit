# frozen_string_literal: true

require 'rspec/core'

module Specbroker
  class Worker
    attr_reader :queue, :key, :batch_size, :rspec_opts, :output

    def initialize(
      key: Specbroker.configuration.key,
      batch_size: Specbroker.configuration.batch_size,
      rspec_opts: Specbroker.configuration.rspec_opts,
      queue: nil,
      output: $stdout
    )
      @key = key
      @batch_size = batch_size
      @rspec_opts = Array(rspec_opts)
      @queue = queue || RedisQueue.new
      @output = output
    end

    # Main work loop: steal batches from Redis and run them through RSpec.
    #
    # Returns 0 if all batches passed (or queue was empty), 1 if any batch failed.
    def run
      failed = false
      batch_num = 0

      loop do
        files = queue.steal(key, batch_size)

        if files.empty?
          output.puts '[specbroker] Queue exhausted. No more files to run.'
          break
        end

        batch_num += 1
        output.puts "[specbroker] Batch ##{batch_num}: running #{files.size} files"
        files.each { |f| output.puts "  #{f}" }

        exit_code = run_rspec_batch(files)
        if exit_code != 0
          output.puts "[specbroker] Batch ##{batch_num} FAILED (exit code: #{exit_code})"
          failed = true
        else
          output.puts "[specbroker] Batch ##{batch_num} passed."
        end
      end

      if batch_num.zero?
        output.puts '[specbroker] Nothing to do (queue was empty).'
      else
        output.puts "[specbroker] Finished #{batch_num} batches. #{failed ? 'SOME FAILED' : 'All passed.'}"
      end

      failed ? 1 : 0
    end

    private

    def run_rspec_batch(files)
      # Clear example state from previous batches so RSpec can run cleanly
      # in the same process. This preserves configuration but resets
      # the world (example groups, examples, shared groups, etc.).
      RSpec.clear_examples

      args = files + rspec_opts
      err = StringIO.new
      out = StringIO.new

      RSpec::Core::Runner.run(args, err, out)
    ensure
      # Print RSpec output through our output stream
      rspec_output = out&.string
      output.print(rspec_output) unless rspec_output.nil? || rspec_output.empty?

      rspec_err = err&.string
      output.print(rspec_err) unless rspec_err.nil? || rspec_err.empty?
    end
  end
end
