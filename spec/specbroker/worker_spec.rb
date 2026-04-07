# frozen_string_literal: true

require 'spec_helper'
require 'rspec/core'

RSpec.describe Specbroker::Worker do
  let(:queue) { instance_double(Specbroker::RedisQueue) }
  let(:output) { StringIO.new }
  let(:key) { 'pr-123-run-456' }

  before do
    allow(RSpec).to receive(:clear_examples)
    allow(RSpec::Core::Runner).to receive(:run).and_return(0)
  end

  describe '#run' do
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
        expect(output.string).to include('Nothing to do')
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
        expect(output.string).to include('Batch #1: running 2 files')
        expect(output.string).to include('Batch #2: running 1 files')
        expect(output.string).to include('All passed')
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
        expect(output.string).to include('Batch #1 passed')
        expect(output.string).to include('Batch #2 FAILED')
        expect(output.string).to include('SOME FAILED')
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

      it 'passes rspec_opts to the runner' do
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
          expect(args).to eq(['spec/a_spec.rb', '--format', 'documentation'])
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
        expect(output.string).to include('Record mode')
        expect(output.string).to include('Recording stolen files to rerun key')
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
        expect(output.string).to include('SOME FAILED')
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
        expect(output.string).to include('Replay mode: found 3 files')
        expect(output.string).to include('Batch #1: running 2 files')
        expect(output.string).to include('Batch #2: running 1 files')
        expect(output.string).to include('Replay finished')
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
        expect(output.string).to include('SOME FAILED')
      end
    end
  end
end
