# frozen_string_literal: true

require 'spec_helper'
require 'rspec/core'

RSpec.describe Specbandit::RspecAdapter do
  let(:output) { StringIO.new }

  before do
    allow(RSpec).to receive(:clear_examples)
    allow(RSpec::Core::Runner).to receive(:run).and_return(0)
    allow(RSpec.world).to receive(:wants_to_quit=)
    allow(RSpec.world).to receive(:non_example_failure=)
    allow(RSpec.configuration).to receive(:output_stream=)
  end

  describe '#setup' do
    it 'is a no-op' do
      adapter = described_class.new
      expect { adapter.setup }.not_to raise_error
    end
  end

  describe '#teardown' do
    it 'is a no-op' do
      adapter = described_class.new
      expect { adapter.teardown }.not_to raise_error
    end
  end

  describe '#run_batch' do
    subject(:adapter) do
      described_class.new(rspec_opts: [], verbose: false, output: output)
    end

    it 'returns an RspecBatchResult' do
      result = adapter.run_batch(['spec/a_spec.rb'], 1)
      expect(result).to be_a(Specbandit::RspecBatchResult)
    end

    it 'includes exit_code from RSpec runner' do
      allow(RSpec::Core::Runner).to receive(:run).and_return(0)
      result = adapter.run_batch(['spec/a_spec.rb'], 1)
      expect(result.exit_code).to eq(0)
    end

    it 'includes exit_code 1 on failure' do
      allow(RSpec::Core::Runner).to receive(:run).and_return(1)
      result = adapter.run_batch(['spec/a_spec.rb'], 1)
      expect(result.exit_code).to eq(1)
    end

    it 'includes batch_num and files' do
      result = adapter.run_batch(['spec/a_spec.rb', 'spec/b_spec.rb'], 3)
      expect(result.batch_num).to eq(3)
      expect(result.files).to eq(['spec/a_spec.rb', 'spec/b_spec.rb'])
    end

    it 'includes a positive duration' do
      result = adapter.run_batch(['spec/a_spec.rb'], 1)
      expect(result.duration).to be_a(Numeric)
      expect(result.duration).to be >= 0
    end

    it 'includes a json_path pointing to an existing file' do
      result = adapter.run_batch(['spec/a_spec.rb'], 1)
      expect(result.json_path).not_to be_nil
      expect(File.exist?(result.json_path)).to be true
      # Clean up
      File.delete(result.json_path) if File.exist?(result.json_path)
    end

    it 'passes files and rspec_opts to RSpec runner with injected json formatter' do
      adapter_with_opts = described_class.new(
        rspec_opts: ['--format', 'documentation'],
        verbose: false,
        output: output
      )

      expect(RSpec::Core::Runner).to receive(:run) do |args, _err, _out|
        expect(args).to start_with('spec/a_spec.rb', '--format', 'documentation')
        expect(args).to include('--format', 'json', '--out')
        0
      end

      result = adapter_with_opts.run_batch(['spec/a_spec.rb'], 1)
      File.delete(result.json_path) if result.json_path && File.exist?(result.json_path)
    end

    it 'resets RSpec state before each batch' do
      expect(RSpec).to receive(:clear_examples)
      expect(RSpec.world).to receive(:wants_to_quit=).with(false)
      expect(RSpec.world).to receive(:non_example_failure=).with(false)
      expect(RSpec.configuration).to receive(:output_stream=).with($stdout)

      result = adapter.run_batch(['spec/a_spec.rb'], 1)
      File.delete(result.json_path) if result.json_path && File.exist?(result.json_path)
    end

    context 'when verbose' do
      subject(:verbose_adapter) do
        described_class.new(rspec_opts: [], verbose: true, output: output)
      end

      it 'prints RSpec stdout to output' do
        allow(RSpec::Core::Runner).to receive(:run) do |_args, _err, out|
          out.print('test output here')
          0
        end

        result = verbose_adapter.run_batch(['spec/a_spec.rb'], 1)
        expect(output.string).to include('test output here')
        File.delete(result.json_path) if result.json_path && File.exist?(result.json_path)
      end
    end

    context 'when not verbose' do
      it 'does not print RSpec stdout to output' do
        allow(RSpec::Core::Runner).to receive(:run) do |_args, _err, out|
          out.print('test output here')
          0
        end

        result = adapter.run_batch(['spec/a_spec.rb'], 1)
        expect(output.string).not_to include('test output here')
        File.delete(result.json_path) if result.json_path && File.exist?(result.json_path)
      end
    end
  end
end
