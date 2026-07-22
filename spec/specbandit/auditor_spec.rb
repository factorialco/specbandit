# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Specbandit::Auditor do
  let(:queue) { instance_double(Specbandit::RedisQueue) }
  let(:output) { StringIO.new }
  let(:key) { 'pr-123-run-456' }

  subject(:auditor) { described_class.new(key: key, shards: 3, queue: queue, output: output) }

  def stub_rerun_keys(shard_contents)
    shard_contents.each_with_index do |files, i|
      allow(queue).to receive(:read_all).with("#{key}-rerun-#{i + 1}").and_return(files)
    end
  end

  describe '#audit' do
    it 'passes when every manifest item appears in some rerun key' do
      allow(queue).to receive(:read_all).with("#{key}:manifest").and_return(%w[a b c d])
      stub_rerun_keys([%w[a], %w[b c], %w[d]])

      expect(auditor.audit).to eq(0)
      expect(output.string).to include('Audit passed')
    end

    it 'fails and names the items that no worker picked up' do
      allow(queue).to receive(:read_all).with("#{key}:manifest").and_return(%w[a b c d])
      stub_rerun_keys([%w[a], %w[b], []])

      expect(auditor.audit).to eq(1)
      expect(output.string).to include('AUDIT FAILED: 2 item(s)')
      expect(output.string).to include('c')
      expect(output.string).to include('d')
      expect(output.string).to include('DID NOT RUN')
    end

    it 'passes when a late worker recorded nothing (empty rerun key)' do
      allow(queue).to receive(:read_all).with("#{key}:manifest").and_return(%w[a b])
      stub_rerun_keys([%w[a b], [], []])

      expect(auditor.audit).to eq(0)
    end

    it 'skips (exit 0) when no manifest exists, for mixed-version rollouts' do
      allow(queue).to receive(:read_all).with("#{key}:manifest").and_return([])

      expect(auditor.audit).to eq(0)
      expect(output.string).to include('No manifest found')
    end

    it 'notes items recorded by workers that are not in the manifest without failing' do
      allow(queue).to receive(:read_all).with("#{key}:manifest").and_return(%w[a])
      stub_rerun_keys([%w[a x], [], []])

      expect(auditor.audit).to eq(0)
      expect(output.string).to include('not in the manifest')
      expect(output.string).to include('x')
    end

    it 'tolerates duplicate entries from retried pushes' do
      allow(queue).to receive(:read_all).with("#{key}:manifest").and_return(%w[a a b])
      stub_rerun_keys([%w[a], %w[a b], []])

      expect(auditor.audit).to eq(0)
    end

    it 'honours a custom rerun key prefix' do
      custom = described_class.new(
        key: key, shards: 2, key_rerun_prefix: 'custom-prefix-', queue: queue, output: output
      )
      allow(queue).to receive(:read_all).with("#{key}:manifest").and_return(%w[a b])
      allow(queue).to receive(:read_all).with('custom-prefix-1').and_return(%w[a])
      allow(queue).to receive(:read_all).with('custom-prefix-2').and_return(%w[b])

      expect(custom.audit).to eq(0)
    end
  end
end
