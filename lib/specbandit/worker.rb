# frozen_string_literal: true

require 'stringio'
require 'json'
require 'tempfile'
require 'rspec/core'

module Specbandit
  class Worker
    attr_reader :queue, :key, :batch_size, :rspec_opts, :key_rerun, :key_rerun_ttl, :output, :verbose

    def initialize(
      key: Specbandit.configuration.key,
      batch_size: Specbandit.configuration.batch_size,
      rspec_opts: Specbandit.configuration.rspec_opts,
      key_rerun: Specbandit.configuration.key_rerun,
      key_rerun_ttl: Specbandit.configuration.key_rerun_ttl,
      verbose: Specbandit.configuration.verbose,
      queue: nil,
      output: $stdout
    )
      @key = key
      @batch_size = batch_size
      @rspec_opts = Array(rspec_opts)
      @key_rerun = key_rerun
      @key_rerun_ttl = key_rerun_ttl
      @verbose = verbose
      @queue = queue || RedisQueue.new
      @output = output
      @batch_durations = []
      @accumulated_examples = []
      @accumulated_summary = { duration: 0.0, example_count: 0, failure_count: 0, pending_count: 0,
                               errors_outside_of_examples_count: 0 }
    end

    # Main entry point. Detects the operating mode and dispatches accordingly.
    #
    # Returns 0 if all batches passed (or nothing to do), 1 if any batch failed.
    def run
      exit_code = if key_rerun
                    rerun_files = queue.read_all(key_rerun)
                    if rerun_files.any?
                      run_replay(rerun_files)
                    else
                      run_steal(record: true)
                    end
                  else
                    run_steal(record: false)
                  end

      print_summary if @batch_durations.any?
      merge_json_results
      write_github_step_summary if ENV['GITHUB_STEP_SUMMARY']

      exit_code
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
        batch.each { |f| output.puts "  #{f}" } if verbose

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
        files.each { |f| output.puts "  #{f}" } if verbose

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
      reset_rspec_state

      # Always write JSON to a tempfile so we can accumulate structured results
      # regardless of whether the user passed --format json --out.
      batch_json = Tempfile.new(['specbandit-batch', '.json'])
      args = files + rspec_opts + ['--format', 'json', '--out', batch_json.path]

      err = StringIO.new
      out = StringIO.new

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exit_code = RSpec::Core::Runner.run(args, err, out)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      @batch_durations << duration

      accumulate_json_results(batch_json.path)
      exit_code
    ensure
      # Print RSpec output through our output stream
      rspec_output = out&.string
      output.print(rspec_output) if verbose && rspec_output && !rspec_output.empty?

      rspec_err = err&.string
      output.print(rspec_err) if verbose && rspec_err && !rspec_err.empty?

      batch_json&.close
      batch_json&.unlink
    end

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

    # --- Reporting helpers ---

    # Extract the --out file path from rspec_opts.
    # RSpec accepts: --out FILE or -o FILE
    def json_output_path
      rspec_opts.each_with_index do |opt, i|
        return rspec_opts[i + 1] if ['--out', '-o'].include?(opt) && rspec_opts[i + 1]
      end
      nil
    end

    # After each batch, read the JSON output from the temp file and accumulate
    # examples and summary fields.
    def accumulate_json_results(path)
      return unless path && File.exist?(path)

      begin
        data = JSON.parse(File.read(path))
      rescue JSON::ParserError
        return
      end

      @accumulated_examples.concat(data.fetch('examples', []))

      summary = data.fetch('summary', {})
      @accumulated_summary[:duration] += summary.fetch('duration', 0.0)
      @accumulated_summary[:example_count] += summary.fetch('example_count', 0)
      @accumulated_summary[:failure_count] += summary.fetch('failure_count', 0)
      @accumulated_summary[:pending_count] += summary.fetch('pending_count', 0)
      @accumulated_summary[:errors_outside_of_examples_count] += summary.fetch('errors_outside_of_examples_count', 0)
    end

    # After all batches, write the merged JSON back to the --out file so
    # CI artifact collection picks up the complete results.
    def merge_json_results
      path = json_output_path
      return unless path && @accumulated_examples.any?

      merged = {
        'version' => RSpec::Core::Version::STRING,
        'specbandit_version' => Specbandit::VERSION,
        'summary' => {
          'duration' => @accumulated_summary[:duration],
          'example_count' => @accumulated_summary[:example_count],
          'failure_count' => @accumulated_summary[:failure_count],
          'pending_count' => @accumulated_summary[:pending_count],
          'errors_outside_of_examples_count' => @accumulated_summary[:errors_outside_of_examples_count]
        },
        'summary_line' => summary_line,
        'examples' => @accumulated_examples,
        'batch_timings' => {
          'count' => @batch_durations.size,
          'min' => @batch_durations.min&.round(2),
          'avg' => @batch_durations.empty? ? 0 : (@batch_durations.sum / @batch_durations.size).round(2),
          'max' => @batch_durations.max&.round(2),
          'all' => @batch_durations.map { |d| d.round(2) }
        }
      }

      File.write(path, JSON.pretty_generate(merged))
    end

    # Print a unified summary to the output stream after all batches.
    def print_summary
      output.puts ''
      output.puts '=' * 60
      output.puts '[specbandit] Summary'
      output.puts '=' * 60
      output.puts "  Batches:  #{@batch_durations.size}"
      output.puts "  Examples: #{@accumulated_summary[:example_count]}"
      output.puts "  Failures: #{@accumulated_summary[:failure_count]}"
      output.puts "  Pending:  #{@accumulated_summary[:pending_count]}"

      output.puts ''
      output.puts format(
        '  Batch timing: min %.1fs | avg %.1fs | max %.1fs',
        @batch_durations.min || 0,
        @batch_durations.empty? ? 0 : @batch_durations.sum / @batch_durations.size,
        @batch_durations.max || 0
      )

      failed_examples = @accumulated_examples.select { |e| e['status'] == 'failed' }
      if failed_examples.any?
        output.puts ''
        output.puts "  Failed specs (#{failed_examples.size}):"
        failed_examples.each do |ex|
          location = ex.dig('file_path') || 'unknown'
          line = ex.dig('line_number')
          location = "#{location}:#{line}" if line
          desc = ex.dig('full_description') || ex.dig('description') || ''
          message = ex.dig('exception', 'message') || ''
          # Truncate long messages
          message = "#{message[0, 120]}..." if message.length > 120
          output.puts "    #{location} - #{desc}"
          output.puts "      #{message}" unless message.empty?
        end
      end

      output.puts '=' * 60
      output.puts ''
    end

    def summary_line
      parts = ["#{@accumulated_summary[:example_count]} examples"]
      parts << "#{@accumulated_summary[:failure_count]} failures"
      parts << "#{@accumulated_summary[:pending_count]} pending" if @accumulated_summary[:pending_count] > 0
      parts.join(', ')
    end

    # Write a markdown summary to $GITHUB_STEP_SUMMARY for GitHub Actions.
    def write_github_step_summary
      path = ENV['GITHUB_STEP_SUMMARY']
      return unless path

      md = StringIO.new
      md.puts '### 🏴‍☠️ Specbandit Results'
      md.puts ''
      md.puts '| Metric | Value |'
      md.puts '|--------|-------|'
      md.puts "| Batches | #{@batch_durations.size} |"
      md.puts "| Examples | #{@accumulated_summary[:example_count]} |"
      md.puts "| Failures | #{@accumulated_summary[:failure_count]} |"
      md.puts "| Pending | #{@accumulated_summary[:pending_count]} |"

      md.puts format('| Batch time (min) | %.1fs |', @batch_durations.min || 0)
      md.puts format('| Batch time (avg) | %.1fs |',
                     @batch_durations.empty? ? 0 : @batch_durations.sum / @batch_durations.size)
      md.puts format('| Batch time (max) | %.1fs |', @batch_durations.max || 0)
      md.puts ''

      failed_examples = @accumulated_examples.select { |e| e['status'] == 'failed' }
      if failed_examples.any?
        md.puts "<details><summary>❌ #{failed_examples.size} failed specs</summary>"
        md.puts ''
        md.puts '| Location | Description | Error |'
        md.puts '|----------|-------------|-------|'
        failed_examples.each do |ex|
          location = ex['file_path'] || 'unknown'
          line = ex['line_number']
          location = "#{location}:#{line}" if line
          desc = (ex['full_description'] || ex['description'] || '').gsub('|', '\\|')
          message = (ex.dig('exception', 'message') || '').gsub('|', '\\|').gsub("\n", ' ')
          message = "#{message[0, 100]}..." if message.length > 100
          md.puts "| `#{location}` | #{desc} | #{message} |"
        end
        md.puts ''
        md.puts '</details>'
      end

      File.open(path, 'a') { |f| f.write(md.string) }
    rescue StandardError
      # Never fail the build because of summary writing
      nil
    end
  end
end
