# frozen_string_literal: true

require 'spec_helper'
require 'rspec/core'

RSpec.describe Specbroker::Worker do
  let(:queue) { instance_double(Specbroker::RedisQueue) }
  let(:output) { StringIO.new }
  let(:key) { 'pr-123-run-456' }

  subject(:worker) do
    described_class.new(
      key: key,
      batch_size: 2,
      rspec_opts: [],
      queue: queue,
      output: output
    )
  end

  describe '#run' do
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

      allow(RSpec).to receive(:clear_examples)
      allow(RSpec::Core::Runner).to receive(:run).and_return(0)

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

      allow(RSpec).to receive(:clear_examples)
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

      allow(RSpec).to receive(:clear_examples)
      # First batch fails, second passes
      allow(RSpec::Core::Runner).to receive(:run).and_return(1, 0)

      exit_code = worker.run

      # Still returns 1 because one batch failed
      expect(exit_code).to eq(1)
      # But both batches were attempted
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
        queue: queue,
        output: output
      )

      allow(RSpec).to receive(:clear_examples)
      expect(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
        expect(args).to eq(['spec/a_spec.rb', '--format', 'documentation'])
        0
      end

      worker_with_opts.run
    end
  end
end
