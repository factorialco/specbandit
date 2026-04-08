# frozen_string_literal: true

require 'stringio'
require 'rspec/core'

module Specbandit
  class Worker
    attr_reader :queue, :key, :batch_size, :rspec_opts, :key_rerun, :key_rerun_ttl, :output

    def initialize(
      key: Specbandit.configuration.key,
      batch_size: Specbandit.configuration.batch_size,
      rspec_opts: Specbandit.configuration.rspec_opts,
      key_rerun: Specbandit.configuration.key_rerun,
      key_rerun_ttl: Specbandit.configuration.key_rerun_ttl,
      queue: nil,
      output: $stdout
    )
      @key = key
      @batch_size = batch_size
      @rspec_opts = Array(rspec_opts)
      @key_rerun = key_rerun
      @key_rerun_ttl = key_rerun_ttl
      @queue = queue || RedisQueue.new
      @output = output
    end

    # Main entry point. Detects the operating mode and dispatches accordingly.
    #
    # Returns 0 if all batches passed (or nothing to do), 1 if any batch failed.
    def run
      if key_rerun
        rerun_files = queue.read_all(key_rerun)
        if rerun_files.any?
          run_replay(rerun_files)
        else
          run_steal(record: true)
        end
      else
        run_steal(record: false)
      end
    end

    private

    # Replay mode: run a known list of files in local batches.
    # Used when re-running a failed CI job -- the rerun key already
    # contains the exact files this runner executed previously.
    def run_replay(files)
      output.puts "[specbandit] Replay mode: found #{files.size} files in rerun key '#{key_rerun}'."
      output.puts '[specbandit] Running previously recorded files (not touching shared queue).'

      failed = false
      batch_num = 0

      files.each_slice(batch_size) do |batch|
        batch_num += 1
        output.puts "[specbandit] Batch ##{batch_num}: running #{batch.size} files"
        batch.each { |f| output.puts "  #{f}" }

        exit_code = run_rspec_batch(batch)
        if exit_code != 0
          output.puts "[specbandit] Batch ##{batch_num} FAILED (exit code: #{exit_code})"
          failed = true
        else
          output.puts "[specbandit] Batch ##{batch_num} passed."
        end
      end

      output.puts "[specbandit] Replay finished: #{batch_num} batches. #{failed ? 'SOME FAILED' : 'All passed.'}"
      failed ? 1 : 0
    end

    # Steal mode: atomically pop batches from the shared queue.
    # When record is true, each stolen batch is also pushed to the
    # rerun key so this runner can replay them on a re-run.
    def run_steal(record:)
      mode_label = record ? 'Record' : 'Steal'
      output.puts "[specbandit] #{mode_label} mode: stealing batches from '#{key}'."
      output.puts "[specbandit] Recording stolen files to rerun key '#{key_rerun}'." if record

      failed = false
      batch_num = 0

      loop do
        files = queue.steal(key, batch_size)

        if files.empty?
          output.puts '[specbandit] Queue exhausted. No more files to run.'
          break
        end

        # Record the stolen batch so this runner can replay on re-run
        queue.push(key_rerun, files, ttl: key_rerun_ttl) if record

        batch_num += 1
        output.puts "[specbandit] Batch ##{batch_num}: running #{files.size} files"
        files.each { |f| output.puts "  #{f}" }

        exit_code = run_rspec_batch(files)
        if exit_code != 0
          output.puts "[specbandit] Batch ##{batch_num} FAILED (exit code: #{exit_code})"
          failed = true
        else
          output.puts "[specbandit] Batch ##{batch_num} passed."
        end
      end

      if batch_num.zero?
        output.puts '[specbandit] Nothing to do (queue was empty).'
      else
        output.puts "[specbandit] Finished #{batch_num} batches. #{failed ? 'SOME FAILED' : 'All passed.'}"
      end

      failed ? 1 : 0
    end

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
