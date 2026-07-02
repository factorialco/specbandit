# frozen_string_literal: true

require 'json'

module Specbandit
  class Worker
    attr_reader :queue, :key, :batch_size, :adapter, :key_rerun, :key_ttl, :key_failed,
                :output, :verbose, :report

    def initialize(
      key: Specbandit.configuration.key,
      batch_size: Specbandit.configuration.batch_size,
      adapter: nil,
      key_rerun: Specbandit.configuration.key_rerun,
      key_ttl: Specbandit.configuration.key_ttl,
      key_failed: Specbandit.configuration.key_failed,
      verbose: Specbandit.configuration.verbose,
      report: Specbandit.configuration.report,
      queue: nil,
      output: $stdout,
      # Legacy parameter for backward compatibility.
      # When adapter is not provided, rspec_opts is used to build an RspecAdapter.
      rspec_opts: nil
    )
      @key = key
      @batch_size = batch_size
      @key_rerun = key_rerun
      @key_ttl = key_ttl
      @key_failed = key_failed
      @verbose = verbose
      @report = report
      @queue = queue || RedisQueue.new
      @output = output
      @batch_results = []
      @accumulated_examples = []
      @accumulated_failed_files = []
      @accumulated_summary = { duration: 0.0, example_count: 0, failure_count: 0, pending_count: 0,
                               errors_outside_of_examples_count: 0 }

      # Support both new adapter-based and legacy rspec_opts-based construction.
      # If no adapter is provided, fall back to RspecAdapter for backward compatibility.
      @adapter = adapter || RspecAdapter.new(
        rspec_opts: rspec_opts || Specbandit.configuration.rspec_opts,
        verbose: verbose,
        output: output
      )
    end

    # Main entry point. Detects the operating mode and dispatches accordingly.
    #
    # Returns 0 if all batches passed (or nothing to do), 1 if any batch failed.
    def run
      @run_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      adapter.setup

      exit_code = determine_exit_code

      print_summary if @batch_results.any?
      merge_json_results
      write_report
      exit_code
    ensure
      adapter.teardown
    end

    private

    # Decide the operating mode from the state of Redis and execute it.
    #
    # The mode is derived entirely from Redis -- never from an environment
    # variable or flag -- following this table:
    #
    #   Published | Key (queue)    | Rerun key   | Behavior
    #   ----------|----------------|-------------|-------------------------------
    #   No        | --             | --          | Crash: nothing was ever pushed
    #   Yes       | empty/drained  | empty       | OK: worker arriving late (0)
    #   Yes       | has data       | empty       | Steal (record if rerun key set)
    #   Yes       | empty/drained  | has data    | Replay recorded files
    #   Yes       | has data       | has data    | Crash: inconsistent (weird case)
    #
    # "Published" is a durable marker written by `specbandit push`; it is the
    # only reliable signal that work was ever enqueued, because Redis
    # auto-deletes empty lists (so a drained queue is indistinguishable from a
    # never-created one by the list alone).
    def determine_exit_code
      return fail_not_published unless queue.published?(key)

      key_has_data = queue.length(key).positive?
      rerun_files = key_present?(key_rerun) ? queue.read_all(key_rerun) : []

      if key_has_data && rerun_files.any?
        fail_inconsistent_state
      elsif rerun_files.any?
        run_replay(rerun_files)
      elsif key_has_data
        run_steal(record: key_present?(key_rerun))
      else
        # Published, but the queue is drained and this runner has no rerun
        # memory: it simply arrived after everything was already taken.
        output.puts "[specbandit] Queue '#{key}' already drained and no rerun files to replay. " \
                    'Nothing to do (worker arriving late).' if verbose
        0
      end
    end

    # A Redis key name is usable only when it is a non-nil, non-empty string.
    # Guards the Ruby gotcha where "" is truthy (e.g. --key-rerun "$UNSET_VAR"),
    # which would otherwise read/write against an empty key name.
    def key_present?(value)
      !value.nil? && !value.empty?
    end

    # No published marker for this key: `specbandit push` was never run for it,
    # or the key expired. Crash rather than silently pass with zero tests.
    def fail_not_published
      output.puts "[specbandit] ERROR: queue '#{key}' was never published."
      output.puts '[specbandit] Run `specbandit push` before `specbandit work`, or the key/TTL may have expired.'
      output.puts '[specbandit] Refusing to run to prevent a silent false pass.'
      1
    end

    # Both the shared queue and this runner's rerun key hold files at once.
    # That should never happen: a fresh run has no rerun memory yet, and a
    # re-run reads from a drained queue. Crash instead of double-executing.
    def fail_inconsistent_state
      output.puts "[specbandit] ERROR: inconsistent state — shared queue '#{key}' still has files " \
                  "while rerun key '#{key_rerun}' also has recorded files."
      output.puts '[specbandit] Refusing to run to avoid double-execution / undefined behavior.'
      1
    end

    # Replay mode: run a known list of files in local batches.
    # Used when re-running a failed CI job -- the rerun key already
    # contains the exact files this runner executed previously.
    def run_replay(files)
      output.puts "[specbandit] Replay mode: found #{files.size} files in rerun key '#{key_rerun}'." if verbose
      output.puts '[specbandit] Running previously recorded files (not touching shared queue).' if verbose

      failed = false
      batch_num = 0

      files.each_slice(batch_size) do |batch|
        batch_num += 1
        output.puts "[specbandit] Batch ##{batch_num}: running #{batch.size} files" if verbose
        batch.each { |f| output.puts "  #{f}" } if verbose

        result = adapter.run_batch(batch, batch_num)
        record_failed_files(batch, result)
        process_batch_result(result)

        if result.exit_code != 0
          output.puts "[specbandit] Batch ##{batch_num} FAILED (exit code: #{result.exit_code})" if verbose
          failed = true
        elsif verbose
          output.puts "[specbandit] Batch ##{batch_num} passed."
        end
      end

      if verbose
        output.puts "[specbandit] Replay finished: #{batch_num} batches. #{failed ? 'SOME FAILED' : 'All passed.'}"
      end
      failed ? 1 : 0
    end

    # Steal mode: atomically pop batches from the shared queue.
    # When record is true, each stolen batch is also pushed to the
    # rerun key so this runner can replay them on a re-run.
    def run_steal(record:)
      mode_label = record ? 'Record' : 'Steal'
      output.puts "[specbandit] #{mode_label} mode: stealing batches from '#{key}'." if verbose
      output.puts "[specbandit] Recording stolen files to rerun key '#{key_rerun}'." if verbose && record

      failed = false
      batch_num = 0

      loop do
        files = queue.steal(key, batch_size)

        if files.empty?
          output.puts '[specbandit] Queue exhausted. No more files to run.' if verbose
          break
        end

        # Record the stolen batch so this runner can replay on re-run
        queue.push(key_rerun, files, ttl: key_ttl) if record

        batch_num += 1
        output.puts "[specbandit] Batch ##{batch_num}: running #{files.size} files" if verbose
        files.each { |f| output.puts "  #{f}" } if verbose

        result = adapter.run_batch(files, batch_num)
        record_failed_files(files, result)
        process_batch_result(result)

        if result.exit_code != 0
          output.puts "[specbandit] Batch ##{batch_num} FAILED (exit code: #{result.exit_code})" if verbose
          failed = true
        elsif verbose
          output.puts "[specbandit] Batch ##{batch_num} passed."
        end
      end

      if batch_num.zero?
        output.puts '[specbandit] Nothing to do (queue was empty).' if verbose
      elsif verbose
        output.puts "[specbandit] Finished #{batch_num} batches. #{failed ? 'SOME FAILED' : 'All passed.'}"
      end

      failed ? 1 : 0
    end

    # Record failed files to the failed key in Redis for later review.
    # Called after each batch; only pushes when key_failed is configured
    # and the batch had a non-zero exit code.
    #
    # For RSpec batches with JSON output, only the individual failed file
    # paths are recorded (not the entire batch). For CLI adapter batches
    # (no per-file granularity), the whole batch is recorded as fallback.
    def record_failed_files(files, result)
      return unless key_present?(key_failed)
      return if result.exit_code.zero?

      failed_files = extract_failed_files(result) || files
      return if failed_files.empty?

      queue.push(key_failed, failed_files, ttl: key_ttl)
      # The failed key is later consumed by a retry `work` pass, which refuses to
      # run any key without a published marker. `push` alone doesn't set it, so
      # mark it here -- otherwise the retry crashes with "was never published".
      queue.mark_published(key_failed, ttl: key_ttl)
    end

    # Extract individual failed file paths from an RspecBatchResult's JSON output.
    # Returns nil when per-file data is not available (CLI adapter).
    def extract_failed_files(result)
      return nil unless result.is_a?(RspecBatchResult) && result.json_path && File.exist?(result.json_path)

      data = JSON.parse(File.read(result.json_path))
      failed = data.fetch('examples', [])
                   .select { |e| e['status'] == 'failed' }
                   .filter_map { |e| e['file_path'] }
                   .uniq

      failed.empty? ? nil : failed
    rescue JSON::ParserError
      nil
    end

    # Process a BatchResult: store it, and for RSpec batches,
    # read the JSON output for rich reporting.
    def process_batch_result(result)
      @batch_results << result

      # Accumulate failed files for the report while JSON data is still available.
      if result.exit_code != 0
        per_file = extract_failed_files(result)
        @accumulated_failed_files.concat(per_file || result.files)
      end

      # If the adapter returned an RspecBatchResult with a json_path,
      # accumulate the structured results for rich reporting.
      return unless result.is_a?(RspecBatchResult) && result.json_path

      accumulate_json_results(result.json_path)

      # Clean up the tempfile now that we've read it
      File.delete(result.json_path) if File.exist?(result.json_path)
    rescue StandardError
      # Never fail because of tempfile cleanup
      nil
    end

    # --- Reporting helpers ---

    def batch_durations
      @batch_results.map(&:duration)
    end

    def has_rspec_results?
      @accumulated_examples.any? || @accumulated_summary[:example_count] > 0
    end

    # Extract the --out file path from rspec_opts (when using RspecAdapter).
    # RSpec accepts: --out FILE or -o FILE
    def json_output_path
      return nil unless adapter.is_a?(RspecAdapter)

      opts = adapter.rspec_opts
      opts.each_with_index do |opt, i|
        return opts[i + 1] if ['--out', '-o'].include?(opt) && opts[i + 1]
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
          'count' => batch_durations.size,
          'min' => batch_durations.min&.round(2),
          'avg' => batch_durations.empty? ? 0 : (batch_durations.sum / batch_durations.size).round(2),
          'max' => batch_durations.max&.round(2),
          'all' => batch_durations.map { |d| d.round(2) }
        }
      }

      File.write(path, JSON.pretty_generate(merged))
    end

    # Write a JSON report file with run statistics when --report is set.
    def write_report
      return unless report
      return if @batch_results.empty?

      wall_time = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @run_start_time).round(2)
      durations = batch_durations
      failed_batches_count = @batch_results.count { |r| r.exit_code != 0 }
      passed_batches_count = @batch_results.count { |r| r.exit_code == 0 }

      data = {
        specbandit_version: Specbandit::VERSION,
        summary: {
          total_files: @batch_results.sum { |r| r.files.size },
          total_batches: @batch_results.size,
          passed_batches: passed_batches_count,
          failed_batches: failed_batches_count,
          passed: failed_batches_count == 0
        },
        failed_files: @accumulated_failed_files.uniq,
        total_wall_time: wall_time,
        batch_timings: {
          count: durations.size,
          min: format('%.2f', durations.min || 0),
          avg: format('%.2f', durations.empty? ? 0 : durations.sum / durations.size),
          max: format('%.2f', durations.max || 0),
          all: durations.map { |d| d.round(2) }
        },
        batches: @batch_results.map do |r|
          {
            batch_num: r.batch_num,
            files: r.files,
            exit_code: r.exit_code,
            duration: r.duration.round(2),
            passed: r.exit_code == 0
          }
        end
      }

      File.write(report, JSON.pretty_generate(data))
    end

    # Print a unified summary to the output stream after all batches.
    def print_summary
      output.puts ''
      output.puts '=' * 60
      output.puts '[specbandit] Summary'
      output.puts '=' * 60
      output.puts "  Batches:  #{batch_durations.size}"

      if has_rspec_results?
        # Rich RSpec-specific summary
        output.puts "  Examples: #{@accumulated_summary[:example_count]}"
        output.puts "  Failures: #{@accumulated_summary[:failure_count]}"
        output.puts "  Pending:  #{@accumulated_summary[:pending_count]}"
      else
        # Generic batch-level summary (CLI adapter or no JSON data)
        total_files = @batch_results.sum { |r| r.files.size }
        failed_batches = @batch_results.count { |r| r.exit_code != 0 }
        output.puts "  Files:          #{total_files}"
        output.puts "  Failed batches: #{failed_batches}"
      end

      output.puts ''
      output.puts format(
        '  Batch timing: min %.1fs | avg %.1fs | max %.1fs',
        batch_durations.min || 0,
        batch_durations.empty? ? 0 : batch_durations.sum / batch_durations.size,
        batch_durations.max || 0
      )

      if has_rspec_results?
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
      else
        failed_batch_results = @batch_results.select { |r| r.exit_code != 0 }
        if failed_batch_results.any?
          output.puts ''
          output.puts "  Failed batches (#{failed_batch_results.size}):"
          failed_batch_results.each do |r|
            output.puts "    Batch ##{r.batch_num} (exit code #{r.exit_code}): #{r.files.join(', ')}"
          end
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
  end
end
