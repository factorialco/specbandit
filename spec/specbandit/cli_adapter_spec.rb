# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe Specbandit::CliAdapter do
  let(:output) { StringIO.new }

  describe '#setup' do
    it 'is a no-op' do
      adapter = described_class.new(command: 'echo')
      expect { adapter.setup }.not_to raise_error
    end
  end

  describe '#teardown' do
    it 'is a no-op' do
      adapter = described_class.new(command: 'echo')
      expect { adapter.teardown }.not_to raise_error
    end
  end

  describe '#run_batch' do
    context 'when not verbose' do
      subject(:adapter) do
        described_class.new(command: 'echo', verbose: false, output: output)
      end

      it 'returns a BatchResult' do
        result = adapter.run_batch(['file1.rb', 'file2.rb'], 1)
        expect(result).to be_a(Specbandit::BatchResult)
      end

      it 'includes batch_num and files' do
        result = adapter.run_batch(['file1.rb', 'file2.rb'], 3)
        expect(result.batch_num).to eq(3)
        expect(result.files).to eq(['file1.rb', 'file2.rb'])
      end

      it 'includes exit_code 0 on success' do
        result = adapter.run_batch(['hello'], 1)
        expect(result.exit_code).to eq(0)
      end

      it 'includes a positive duration' do
        result = adapter.run_batch(['hello'], 1)
        expect(result.duration).to be_a(Numeric)
        expect(result.duration).to be >= 0
      end

      it 'includes exit_code != 0 on failure' do
        adapter = described_class.new(command: 'false', verbose: false, output: output)
        result = adapter.run_batch([], 1)
        expect(result.exit_code).not_to eq(0)
      end

      it 'splits command on whitespace' do
        allow(Open3).to receive(:capture3)
          .and_return(['', '', instance_double(Process::Status, exitstatus: 0)])

        adapter = described_class.new(command: 'bundle exec rspec', verbose: false, output: output)
        adapter.run_batch(['spec/a_spec.rb'], 1)

        expect(Open3).to have_received(:capture3)
          .with('bundle', 'exec', 'rspec', 'spec/a_spec.rb')
      end

      it 'appends command_opts before files' do
        allow(Open3).to receive(:capture3)
          .and_return(['', '', instance_double(Process::Status, exitstatus: 0)])

        adapter = described_class.new(
          command: 'rspec',
          command_opts: ['--format', 'documentation'],
          verbose: false,
          output: output
        )
        adapter.run_batch(['spec/a_spec.rb'], 1)

        expect(Open3).to have_received(:capture3)
          .with('rspec', '--format', 'documentation', 'spec/a_spec.rb')
      end

      it 'prints stderr on failure' do
        allow(Open3).to receive(:capture3)
          .and_return(['', "something went wrong\n", instance_double(Process::Status, exitstatus: 1)])

        adapter = described_class.new(command: 'rspec', verbose: false, output: output)
        adapter.run_batch(['spec/a_spec.rb'], 1)

        expect(output.string).to include('something went wrong')
      end

      it 'prints stdout' do
        allow(Open3).to receive(:capture3)
          .and_return(["some output\n", '', instance_double(Process::Status, exitstatus: 0)])

        adapter = described_class.new(command: 'rspec', verbose: false, output: output)
        adapter.run_batch(['spec/a_spec.rb'], 1)

        expect(output.string).to include('some output')
      end
    end

    context 'when verbose' do
      it 'runs the command and returns a BatchResult' do
        adapter = described_class.new(command: 'true', verbose: true, output: output)

        result = adapter.run_batch(['file1.rb'], 1)
        expect(result).to be_a(Specbandit::BatchResult)
        expect(result.exit_code).to eq(0)
      end
    end
  end
end
