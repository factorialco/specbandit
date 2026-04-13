# frozen_string_literal: true

require 'open3'

module Specbandit
  # CLI adapter: spawns a shell command for each batch.
  #
  # Works with any test runner. The command string is split on whitespace,
  # and file paths are appended as arguments:
  #
  #   <executable> [...command_args] [...command_opts] [...file_paths]
  #
  # Example: command="bundle exec rspec", command_opts=["--format", "documentation"]
  #   -> system("bundle", "exec", "rspec", "--format", "documentation", "file1.rb", "file2.rb")
  class CliAdapter
    include Adapter

    attr_reader :command, :command_opts, :verbose, :output

    def initialize(command:, command_opts: [], verbose: false, output: $stdout)
      @command = command
      @command_opts = Array(command_opts)
      @verbose = verbose
      @output = output
    end

    # No-op for CLI adapter.
    def setup; end

    # Spawn the command with file paths appended as arguments.
    # Returns a BatchResult with the exit code and timing.
    def run_batch(files, batch_num)
      command_parts = command.split(/\s+/)
      args = command_parts + command_opts + files

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if verbose
        # Inherit stdio so user sees output in real-time
        system(*args)
        exit_code = $?.exitstatus || 1
      else
        stdout, stderr, status = Open3.capture3(*args)
        exit_code = status.exitstatus || 1

        # Print stderr on failure
        output.puts stderr if exit_code != 0 && stderr && !stderr.strip.empty?

        # Print stdout if any
        output.print(stdout) if stdout && !stdout.empty?
      end

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      BatchResult.new(
        batch_num: batch_num,
        files: files,
        exit_code: exit_code,
        duration: duration
      )
    end

    # No-op for CLI adapter.
    def teardown; end
  end
end
