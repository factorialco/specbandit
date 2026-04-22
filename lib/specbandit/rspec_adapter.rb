# frozen_string_literal: true

require 'stringio'
require 'json'
require 'tempfile'
require 'rspec/core'

module Specbandit
  # RSpec-specific batch result that extends BatchResult with the path
  # to the JSON output file. The Worker uses this to accumulate
  # per-example results for rich reporting (failed spec details, etc.).
  class RspecBatchResult < BatchResult
    attr_accessor :json_path
  end

  # RSpec adapter: runs RSpec programmatically in-process.
  #
  # Each batch calls RSpec::Core::Runner.run with careful state cleanup
  # between batches. This avoids process startup overhead and is the
  # fastest way to run RSpec batches in a single process.
  #
  # The adapter injects a JSON formatter writing to a tempfile so the
  # Worker can accumulate structured results. User-provided rspec_opts
  # (e.g. --format documentation) are preserved and prepended.
  class RspecAdapter
    include Adapter

    attr_reader :rspec_opts, :verbose, :output

    def initialize(rspec_opts: [], verbose: false, output: $stdout)
      @rspec_opts = Array(rspec_opts)
      @verbose = verbose
      @output = output
    end

    # No-op for RSpec adapter — RSpec is already loaded.
    def setup; end

    # Run a batch of spec files via RSpec::Core::Runner.run.
    #
    # Returns an RspecBatchResult with exit_code, duration, and json_path
    # pointing to a tempfile containing the JSON output. The caller is
    # responsible for reading and cleaning up the tempfile.
    def run_batch(files, batch_num)
      reset_rspec_state

      batch_json = Tempfile.new(['specbandit-batch', '.json'])
      args = files + rspec_opts + ['--format', 'json', '--out', batch_json.path]

      err = StringIO.new
      out = StringIO.new

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exit_code = RSpec::Core::Runner.run(args, err, out)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      result = RspecBatchResult.new(
        batch_num: batch_num,
        files: files,
        exit_code: exit_code,
        duration: duration
      )
      result.json_path = batch_json.path
      result
    ensure
      # Print RSpec output through our output stream
      rspec_output = out&.string
      output.print(rspec_output) if rspec_output && !rspec_output.empty?

      rspec_err = err&.string
      output.print(rspec_err) if rspec_err && !rspec_err.empty?

      # Don't unlink the tempfile here — the Worker needs to read it.
      # The Worker is responsible for cleanup after accumulation.
      batch_json&.close
    end

    # No-op for RSpec adapter.
    def teardown; end

    private

    # Reset RSpec state between batches so each batch runs cleanly.
    #
    # RSpec.clear_examples resets example groups, the reporter, filters, and
    # the start-time clock -- but it leaves three critical pieces of state
    # that cause cascading failures when running multiple batches in the
    # same process:
    #
    # 1. output_stream -- After batch #1, Runner#configure sets
    #    output_stream to a StringIO. On batch #2+, the guard
    #    `if output_stream == $stdout` is permanently false, so the new
    #    `out` is never used. All RSpec output silently goes to the stale
    #    batch-1 StringIO.
    #
    # 2. wants_to_quit -- If any batch triggers a load error or fail-fast,
    #    this flag is set to true. On subsequent batches, Runner#setup
    #    returns immediately and Runner#run does exit_early -- specs are
    #    never loaded or run.
    #
    # 3. non_example_failure -- Once set, exit_code() unconditionally
    #    returns the failure exit code, even if all examples passed.
    #
    def reset_rspec_state
      RSpec.clear_examples
      RSpec.world.wants_to_quit = false
      RSpec.world.non_example_failure = false
      RSpec.configuration.output_stream = $stdout
    end
  end
end
