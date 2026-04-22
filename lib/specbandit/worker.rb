# frozen_string_literal: true

require 'json'

module Specbandit
  class Worker
    attr_reader :queue, :key, :batch_size, :adapter, :key_rerun, :key_rerun_ttl, :rerun, :output, :verbose

    def initialize(
      key: Specbandit.configuration.key,
      batch_size: Specbandit.configuration.batch_size,
      adapter: nil,
      key_rerun: Specbandit.configuration.key_rerun,
      key_rerun_ttl: Specbandit.configuration.key_rerun_ttl,
      rerun: Specbandit.configuration.rerun,
      verbose: Specbandit.configuration.verbose,
      queue: nil,
      output: $stdout,
      # Legacy parameter for backward compatibility.
      # When adapter is not provided, rspec_opts is used to build an RspecAdapter.
      rspec_opts: nil
    )
      @key = key
      @batch_size = batch_size
      @key_rerun = key_rerun
      @key_rerun_ttl = key_rerun_ttl
      @rerun = rerun
      @verbose = verbose
      @queue = queue || RedisQueue.new
      @output = output
      @batch_results = []
      @accumulated_examples = []
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
      adapter.setup

      exit_code = if key_rerun
                    rerun_files = queue.read_all(key_rerun)
                    if rerun_files.any?
                      run_replay(rerun_files)
                    elsif rerun
                      output.puts "[specbandit] ERROR: --rerun flag is set but rerun key '#{key_rerun}' is empty."
                      output.puts '[specbandit] The rerun key may have expired (TTL) or Redis was flushed.'
                      output.puts '[specbandit] Cannot replay — failing to prevent silent false pass.'
                      1
                    else
                      run_steal(record: true)
                    end
                  else
                    run_steal(record: false)
                  end

      print_summary if @batch_results.any?
      merge_json_results
      exit_code
    ensure
      adapter.teardown
    end

    private

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
        queue.push(key_rerun, files, ttl: key_rerun_ttl) if record

        batch_num += 1
        output.puts "[specbandit] Batch ##{batch_num}: running #{files.size} files" if verbose
        files.each { |f| output.puts "  #{f}" } if verbose

        result = adapter.run_batch(files, batch_num)
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

    # Process a BatchResult: store it, and for RSpec batches,
    # read the JSON output for rich reporting.
    def process_batch_result(result)
      @batch_results << result

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
