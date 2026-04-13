# frozen_string_literal: true

module Specbandit
  # Result of running a single batch of test files.
  # Adapters return instances of this (or a subclass) from #run_batch.
  BatchResult = Struct.new(:batch_num, :files, :exit_code, :duration, keyword_init: true)

  # Adapter interface for executing test batches.
  #
  # specbandit supports pluggable execution strategies:
  # - CliAdapter: spawns a shell command for each batch (works with any test runner)
  # - RspecAdapter: runs RSpec programmatically in-process (maximum performance)
  #
  # To implement a custom adapter, define a class that responds to:
  #   #setup           - One-time initialization before any batches run
  #   #run_batch(files, batch_num) - Execute a batch, return a BatchResult
  #   #teardown        - Cleanup after all batches are done
  module Adapter
  end
end
