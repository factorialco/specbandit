# frozen_string_literal: true

require 'spec_helper'
require 'rspec/core'
require 'json'
require 'tmpdir'
require 'fileutils'

RSpec.describe Specbandit::Worker do
  let(:queue) { instance_double(Specbandit::RedisQueue) }
  let(:output) { StringIO.new }
  let(:key) { 'pr-123-run-456' }

  before do
    allow(RSpec).to receive(:clear_examples)
    allow(RSpec::Core::Runner).to receive(:run).and_return(0)
    allow(RSpec.world).to receive(:wants_to_quit=)
    allow(RSpec.world).to receive(:non_example_failure=)
    allow(RSpec.configuration).to receive(:output_stream=)
  end

  # Helper: extract the LAST --out path from RSpec::Core::Runner.run args.
  # The adapter always appends a temp JSON formatter at the end, so the last
  # --out is the tempfile that accumulate_json_results reads from.
  def json_out_from_args(args)
    result = nil
    args.each_with_index do |arg, i|
      result = args[i + 1] if ['--out', '-o'].include?(arg) && args[i + 1]
    end
    result
  end

  describe '#run' do
    context 'with adapter (generic)' do
      let(:mock_adapter) do
        adapter = double('Adapter')
        allow(adapter).to receive(:setup)
        allow(adapter).to receive(:teardown)
        allow(adapter).to receive(:run_batch) do |files, batch_num|
          Specbandit::BatchResult.new(
            batch_num: batch_num,
            files: files,
            exit_code: 0,
            duration: 1.0
          )
        end
        adapter
      end

      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          adapter: mock_adapter,
          key_rerun: nil,
          queue: queue,
          output: output
        )
      end

      it 'calls adapter.setup before batches and adapter.teardown after' do
        expect(queue).to receive(:steal).with(key, 2).and_return([])
        expect(mock_adapter).to receive(:setup).ordered
        expect(mock_adapter).to receive(:teardown).ordered

        worker.run
      end

      it 'calls adapter.teardown even if an error occurs' do
        expect(queue).to receive(:steal).with(key, 2).and_raise(StandardError, 'boom')
        expect(mock_adapter).to receive(:setup)
        expect(mock_adapter).to receive(:teardown)

        expect { worker.run }.to raise_error(StandardError, 'boom')
      end

      it 'delegates batch execution to the adapter' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb', 'spec/b_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2).and_return([])

        expect(mock_adapter).to receive(:run_batch)
          .with(['spec/a_spec.rb', 'spec/b_spec.rb'], 1)
          .and_return(Specbandit::BatchResult.new(batch_num: 1, files: ['spec/a_spec.rb', 'spec/b_spec.rb'],
                                                  exit_code: 0, duration: 1.0))

        worker.run
      end

      it 'shows generic summary (Files/Failed batches) for non-RSpec adapter' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2).and_return([])

        worker.run

        expect(output.string).to include('Files:')
        expect(output.string).to include('Failed batches:')
        expect(output.string).not_to include('Examples:')
      end
    end

    context 'steal mode (no key_rerun)' do
      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: [],
          key_rerun: nil,
          queue: queue,
          output: output
        )
      end

      it 'returns 0 when queue is empty from the start' do
        expect(queue).to receive(:steal).with(key, 2).and_return([])

        exit_code = worker.run

        expect(exit_code).to eq(0)
      end

      it 'steals and runs batches until queue is exhausted' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb', 'spec/b_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/c_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return([])

        exit_code = worker.run

        expect(exit_code).to eq(0)
        expect(RSpec::Core::Runner).to have_received(:run).twice
      end

      it 'returns 1 if any batch fails' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb', 'spec/b_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/c_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return([])

        allow(RSpec::Core::Runner).to receive(:run).and_return(0, 1)

        exit_code = worker.run

        expect(exit_code).to eq(1)
      end

      it 'continues stealing after a batch failure' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/b_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return([])

        allow(RSpec::Core::Runner).to receive(:run).and_return(1, 0)

        exit_code = worker.run

        expect(exit_code).to eq(1)
        expect(RSpec::Core::Runner).to have_received(:run).twice
      end

      it 'passes rspec_opts to the adapter along with injected json formatter' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return([])

        worker_with_opts = described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: ['--format', 'documentation'],
          key_rerun: nil,
          queue: queue,
          output: output
        )

        expect(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
          # User opts come first, then the injected json formatter
          expect(args).to start_with('spec/a_spec.rb', '--format', 'documentation')
          expect(args).to include('--format', 'json', '--out')
          0
        end

        worker_with_opts.run
      end

      it 'does not push to any rerun key' do
        expect(queue).to receive(:steal).with(key, 2).and_return(['spec/a_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2).and_return([])
        expect(queue).not_to receive(:push)

        worker.run
      end
    end

    context 'record mode (key_rerun set, rerun key empty)' do
      let(:key_rerun) { 'pr-123-run-456-runner-3' }

      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: [],
          key_rerun: key_rerun,
          key_rerun_ttl: 604_800,
          queue: queue,
          output: output
        )
      end

      before do
        # Rerun key is empty -> record mode
        allow(queue).to receive(:read_all).with(key_rerun).and_return([])
      end

      it 'steals from the main key and records batches to the rerun key' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb', 'spec/b_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/c_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return([])

        expect(queue).to receive(:push)
          .with(key_rerun, ['spec/a_spec.rb', 'spec/b_spec.rb'], ttl: 604_800)
        expect(queue).to receive(:push)
          .with(key_rerun, ['spec/c_spec.rb'], ttl: 604_800)

        exit_code = worker.run

        expect(exit_code).to eq(0)
      end

      it 'returns 1 if any batch fails but still records all batches' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return([])

        allow(RSpec::Core::Runner).to receive(:run).and_return(1)
        expect(queue).to receive(:push).with(key_rerun, ['spec/a_spec.rb'], ttl: 604_800)

        exit_code = worker.run

        expect(exit_code).to eq(1)
      end
    end

    context 'failed key recording (key_failed set)' do
      let(:key_failed) { 'pr-123-run-456-failed' }

      context 'with RSpec adapter (per-file granularity)' do
        subject(:worker) do
          described_class.new(
            key: key,
            batch_size: 3,
            rspec_opts: [],
            key_rerun: nil,
            key_failed: key_failed,
            key_failed_ttl: 604_800,
            queue: queue,
            output: output
          )
        end

        it 'pushes only the individually failed files, not the whole batch' do
          expect(queue).to receive(:steal).with(key, 3)
                                          .and_return(['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'])
          expect(queue).to receive(:steal).with(key, 3).and_return([])

          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            json_path = json_out_from_args(args)
            if json_path
              json_data = {
                'examples' => [
                  { 'status' => 'passed', 'file_path' => 'spec/a_spec.rb' },
                  { 'status' => 'failed', 'file_path' => 'spec/b_spec.rb' },
                  { 'status' => 'failed', 'file_path' => 'spec/c_spec.rb' }
                ],
                'summary' => { 'duration' => 1.0, 'example_count' => 3, 'failure_count' => 2,
                               'pending_count' => 0, 'errors_outside_of_examples_count' => 0 }
              }
              File.write(json_path, JSON.generate(json_data))
            end
            1
          end

          expect(queue).to receive(:push)
            .with(key_failed, ['spec/b_spec.rb', 'spec/c_spec.rb'], ttl: 604_800)

          worker.run
        end

        it 'deduplicates file paths when multiple examples fail in the same file' do
          expect(queue).to receive(:steal).with(key, 3)
                                          .and_return(['spec/a_spec.rb', 'spec/b_spec.rb'])
          expect(queue).to receive(:steal).with(key, 3).and_return([])

          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            json_path = json_out_from_args(args)
            if json_path
              json_data = {
                'examples' => [
                  { 'status' => 'failed', 'file_path' => 'spec/a_spec.rb', 'description' => 'test 1' },
                  { 'status' => 'failed', 'file_path' => 'spec/a_spec.rb', 'description' => 'test 2' },
                  { 'status' => 'passed', 'file_path' => 'spec/b_spec.rb' }
                ],
                'summary' => { 'duration' => 1.0, 'example_count' => 3, 'failure_count' => 2,
                               'pending_count' => 0, 'errors_outside_of_examples_count' => 0 }
              }
              File.write(json_path, JSON.generate(json_data))
            end
            1
          end

          expect(queue).to receive(:push)
            .with(key_failed, ['spec/a_spec.rb'], ttl: 604_800)

          worker.run
        end
      end

      context 'in steal mode' do
        let(:mock_adapter) do
          adapter = double('Adapter')
          allow(adapter).to receive(:setup)
          allow(adapter).to receive(:teardown)
          adapter
        end

        subject(:worker) do
          described_class.new(
            key: key,
            batch_size: 2,
            adapter: mock_adapter,
            key_rerun: nil,
            key_failed: key_failed,
            key_failed_ttl: 604_800,
            queue: queue,
            output: output
          )
        end

        it 'pushes failed batch files to the failed key' do
          expect(queue).to receive(:steal).with(key, 2)
                                          .and_return(['spec/a_spec.rb', 'spec/b_spec.rb'])
          expect(queue).to receive(:steal).with(key, 2).and_return([])

          allow(mock_adapter).to receive(:run_batch).and_return(
            Specbandit::BatchResult.new(batch_num: 1, files: ['spec/a_spec.rb', 'spec/b_spec.rb'],
                                        exit_code: 1, duration: 1.0)
          )

          expect(queue).to receive(:push)
            .with(key_failed, ['spec/a_spec.rb', 'spec/b_spec.rb'], ttl: 604_800)

          worker.run
        end

        it 'does not push passing batch files to the failed key' do
          expect(queue).to receive(:steal).with(key, 2)
                                          .and_return(['spec/a_spec.rb'])
          expect(queue).to receive(:steal).with(key, 2).and_return([])

          allow(mock_adapter).to receive(:run_batch).and_return(
            Specbandit::BatchResult.new(batch_num: 1, files: ['spec/a_spec.rb'],
                                        exit_code: 0, duration: 1.0)
          )

          expect(queue).not_to receive(:push)

          worker.run
        end

        it 'records only the failed batches when some pass and some fail' do
          expect(queue).to receive(:steal).with(key, 2)
                                          .and_return(['spec/a_spec.rb'])
          expect(queue).to receive(:steal).with(key, 2)
                                          .and_return(['spec/b_spec.rb'])
          expect(queue).to receive(:steal).with(key, 2).and_return([])

          call_count = 0
          allow(mock_adapter).to receive(:run_batch) do |files, batch_num|
            call_count += 1
            exit_code = call_count == 2 ? 1 : 0
            Specbandit::BatchResult.new(batch_num: batch_num, files: files,
                                        exit_code: exit_code, duration: 1.0)
          end

          expect(queue).to receive(:push)
            .with(key_failed, ['spec/b_spec.rb'], ttl: 604_800)

          worker.run
        end
      end

      context 'in replay mode' do
        let(:key_rerun) { 'pr-123-run-456-runner-3' }
        let(:recorded_files) { ['spec/x_spec.rb', 'spec/y_spec.rb'] }

        subject(:worker) do
          described_class.new(
            key: key,
            batch_size: 2,
            rspec_opts: [],
            key_rerun: key_rerun,
            key_rerun_ttl: 604_800,
            key_failed: key_failed,
            key_failed_ttl: 604_800,
            queue: queue,
            output: output
          )
        end

        before do
          allow(queue).to receive(:read_all).with(key_rerun).and_return(recorded_files)
        end

        it 'pushes only individually failed files to the failed key during replay' do
          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            json_path = json_out_from_args(args)
            if json_path
              json_data = {
                'examples' => [
                  { 'status' => 'failed', 'file_path' => 'spec/x_spec.rb' },
                  { 'status' => 'passed', 'file_path' => 'spec/y_spec.rb' }
                ]
              }
              File.write(json_path, JSON.generate(json_data))
            end
            1
          end

          expect(queue).to receive(:push)
            .with(key_failed, ['spec/x_spec.rb'], ttl: 604_800)

          worker.run
        end
      end
    end

    context 'no failed key configured' do
      let(:mock_adapter) do
        adapter = double('Adapter')
        allow(adapter).to receive(:setup)
        allow(adapter).to receive(:teardown)
        allow(adapter).to receive(:run_batch).and_return(
          Specbandit::BatchResult.new(batch_num: 1, files: ['spec/a_spec.rb'],
                                      exit_code: 1, duration: 1.0)
        )
        adapter
      end

      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          adapter: mock_adapter,
          key_rerun: nil,
          key_failed: nil,
          queue: queue,
          output: output
        )
      end

      it 'does not push to any failed key even when batches fail' do
        expect(queue).to receive(:steal).with(key, 2)
                                        .and_return(['spec/a_spec.rb'])
        expect(queue).to receive(:steal).with(key, 2).and_return([])
        expect(queue).not_to receive(:push)

        worker.run
      end
    end

    context 'replay mode (key_rerun set, rerun key has data)' do
      let(:key_rerun) { 'pr-123-run-456-runner-3' }
      let(:recorded_files) { ['spec/x_spec.rb', 'spec/y_spec.rb', 'spec/z_spec.rb'] }

      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: [],
          key_rerun: key_rerun,
          key_rerun_ttl: 604_800,
          queue: queue,
          output: output
        )
      end

      before do
        # Rerun key has data -> replay mode
        allow(queue).to receive(:read_all).with(key_rerun).and_return(recorded_files)
      end

      it 'runs files from the rerun key in batches' do
        exit_code = worker.run

        expect(exit_code).to eq(0)
        # 3 files with batch_size 2 = 2 batches
        expect(RSpec::Core::Runner).to have_received(:run).twice
      end

      it 'never touches the shared queue' do
        expect(queue).not_to receive(:steal)
        expect(queue).not_to receive(:push)

        worker.run
      end

      it 'returns 1 if any replay batch fails' do
        allow(RSpec::Core::Runner).to receive(:run).and_return(0, 1)

        exit_code = worker.run

        expect(exit_code).to eq(1)
      end
    end

    context 'rerun flag with empty rerun key (stale rerun)' do
      let(:key_rerun) { 'pr-123-run-456-runner-3' }

      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: [],
          key_rerun: key_rerun,
          key_rerun_ttl: 604_800,
          rerun: true,
          queue: queue,
          output: output
        )
      end

      before do
        allow(queue).to receive(:read_all).with(key_rerun).and_return([])
      end

      it 'fails hard with exit code 1' do
        exit_code = worker.run

        expect(exit_code).to eq(1)
      end

      it 'prints a clear error message' do
        worker.run

        expect(output.string).to include('ERROR')
        expect(output.string).to include("rerun key '#{key_rerun}' is empty")
        expect(output.string).to include('Cannot replay')
      end

      it 'does not steal from the shared queue' do
        expect(queue).not_to receive(:steal)

        worker.run
      end

      it 'does not run any specs' do
        worker.run

        expect(RSpec::Core::Runner).not_to have_received(:run)
      end
    end

    context 'rerun flag with populated rerun key (valid rerun)' do
      let(:key_rerun) { 'pr-123-run-456-runner-3' }
      let(:recorded_files) { ['spec/x_spec.rb', 'spec/y_spec.rb'] }

      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: [],
          key_rerun: key_rerun,
          key_rerun_ttl: 604_800,
          rerun: true,
          queue: queue,
          output: output
        )
      end

      before do
        allow(queue).to receive(:read_all).with(key_rerun).and_return(recorded_files)
      end

      it 'enters replay mode normally' do
        exit_code = worker.run

        expect(exit_code).to eq(0)
      end
    end

    context 'verbose mode' do
      subject(:worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: [],
          key_rerun: nil,
          verbose: true,
          queue: queue,
          output: output
        )
      end

      subject(:quiet_worker) do
        described_class.new(
          key: key,
          batch_size: 2,
          rspec_opts: [],
          key_rerun: nil,
          verbose: false,
          queue: queue,
          output: output
        )
      end

      before do
        allow(queue).to receive(:steal).with(key, 2)
                                       .and_return(['spec/a_spec.rb'], [])
      end

      it 'shows batch telemetry when verbose' do
        worker.run
        expect(output.string).to include('Batch #1: running 1 files')
        expect(output.string).to include('spec/a_spec.rb')
      end

      it 'hides batch telemetry when quiet' do
        quiet_worker.run
        expect(output.string).not_to include('Batch #1: running 1 files')
        expect(output.string).not_to include('  spec/a_spec.rb')
      end
    end

    context 'summary and reporting' do
      let(:tmpdir) { Dir.mktmpdir('specbandit-test') }
      let(:json_out_path) { File.join(tmpdir, 'results.json') }

      after { FileUtils.rm_rf(tmpdir) }

      def make_rspec_json(examples:, duration: 1.5, failure_count: 0, pending_count: 0)
        {
          'version' => '3.13.0',
          'summary' => {
            'duration' => duration,
            'example_count' => examples.size,
            'failure_count' => failure_count,
            'pending_count' => pending_count,
            'errors_outside_of_examples_count' => 0
          },
          'summary_line' => "#{examples.size} examples, #{failure_count} failures",
          'examples' => examples
        }
      end

      def passing_example(id:)
        {
          'id' => id,
          'description' => "example #{id}",
          'full_description' => "Something example #{id}",
          'status' => 'passed',
          'file_path' => "spec/#{id}_spec.rb",
          'line_number' => 1,
          'run_time' => 0.01
        }
      end

      def failing_example(id:)
        {
          'id' => id,
          'description' => "example #{id}",
          'full_description' => "Something example #{id}",
          'status' => 'failed',
          'file_path' => "spec/#{id}_spec.rb",
          'line_number' => 5,
          'run_time' => 0.02,
          'exception' => {
            'class' => 'RSpec::Expectations::ExpectationNotMetError',
            'message' => 'expected true to be false'
          }
        }
      end

      context 'unified console summary' do
        subject(:worker) do
          described_class.new(
            key: key,
            batch_size: 2,
            rspec_opts: [],
            key_rerun: nil,
            queue: queue,
            output: output
          )
        end

        it 'prints summary with batch count and timing stats' do
          batch_call = 0
          allow(queue).to receive(:steal).with(key, 2)
                                         .and_return(['spec/a_spec.rb'], ['spec/b_spec.rb'], [])
          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            batch_call += 1
            json_data = make_rspec_json(
              examples: [passing_example(id: "ex#{batch_call}")],
              duration: batch_call * 10.0
            )
            File.write(json_out_from_args(args), JSON.generate(json_data))
            0
          end

          worker.run

          expect(output.string).to include('[specbandit] Summary')
          expect(output.string).to include('Batches:  2')
          expect(output.string).to include('Examples: 2')
          expect(output.string).to include('Failures: 0')
          expect(output.string).to include('Batch timing: min')
        end

        it 'prints failed specs in the summary' do
          allow(queue).to receive(:steal).with(key, 2)
                                         .and_return(['spec/a_spec.rb'], [])
          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            json_data = make_rspec_json(
              examples: [failing_example(id: 'fail1')],
              duration: 5.0,
              failure_count: 1
            )
            File.write(json_out_from_args(args), JSON.generate(json_data))
            1
          end

          worker.run

          expect(output.string).to include('Failed specs (1)')
          expect(output.string).to include('spec/fail1_spec.rb:5')
          expect(output.string).to include('expected true to be false')
        end

        it 'always shows examples/failures/pending even without user --out' do
          allow(queue).to receive(:steal).with(key, 2)
                                         .and_return(['spec/a_spec.rb'], [])
          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            json_data = make_rspec_json(
              examples: [passing_example(id: 'a')],
              duration: 1.0
            )
            File.write(json_out_from_args(args), JSON.generate(json_data))
            0
          end

          worker.run

          expect(output.string).to include('Examples: 1')
          expect(output.string).to include('Failures: 0')
          expect(output.string).to include('Pending:  0')
        end
      end

      context 'JSON result accumulation' do
        subject(:worker) do
          described_class.new(
            key: key,
            batch_size: 2,
            rspec_opts: ['--format', 'json', '--out', json_out_path],
            key_rerun: nil,
            queue: queue,
            output: output
          )
        end

        it 'merges all batch results into the user JSON output file' do
          batch_call = 0
          allow(queue).to receive(:steal).with(key, 2)
                                         .and_return(['spec/a_spec.rb'], ['spec/b_spec.rb'], [])
          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            batch_call += 1
            examples = if batch_call == 1
                         [passing_example(id: 'a')]
                       else
                         [failing_example(id: 'b')]
                       end
            failure_count = batch_call == 2 ? 1 : 0
            json_data = make_rspec_json(examples: examples, duration: 2.0, failure_count: failure_count)
            # Write to the injected tempfile path so accumulation works
            File.write(json_out_from_args(args), JSON.generate(json_data))
            batch_call == 2 ? 1 : 0
          end

          worker.run

          # The merged result should be written to the user's --out path
          merged = JSON.parse(File.read(json_out_path))
          expect(merged['examples'].size).to eq(2)
          expect(merged['summary']['example_count']).to eq(2)
          expect(merged['summary']['failure_count']).to eq(1)
          expect(merged['summary']['duration']).to eq(4.0)
          expect(merged['specbandit_version']).to eq(Specbandit::VERSION)
        end

        it 'includes batch_timings in the merged JSON' do
          allow(queue).to receive(:steal).with(key, 2)
                                         .and_return(['spec/a_spec.rb'], [])
          allow(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
            json_data = make_rspec_json(examples: [passing_example(id: 'a')], duration: 1.0)
            File.write(json_out_from_args(args), JSON.generate(json_data))
            0
          end

          worker.run

          merged = JSON.parse(File.read(json_out_path))
          expect(merged['batch_timings']).to be_a(Hash)
          expect(merged['batch_timings']['count']).to eq(1)
          expect(merged['batch_timings']['min']).to be_a(Numeric)
          expect(merged['batch_timings']['avg']).to be_a(Numeric)
          expect(merged['batch_timings']['max']).to be_a(Numeric)
          expect(merged['batch_timings']['all']).to be_an(Array)
        end

        it 'does not write merged JSON when no user --out option is set' do
          worker_no_json = described_class.new(
            key: key,
            batch_size: 2,
            rspec_opts: [],
            key_rerun: nil,
            queue: queue,
            output: output
          )

          allow(queue).to receive(:steal).with(key, 2)
                                         .and_return(['spec/a_spec.rb'], [])

          worker_no_json.run

          # The user-specified json_out_path should not exist
          expect(File.exist?(json_out_path)).to be false
        end
      end
    end
  end
end
