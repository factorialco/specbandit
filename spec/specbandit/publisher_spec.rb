# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Specbandit::Publisher do
  let(:queue) { instance_double(Specbandit::RedisQueue) }
  let(:output) { StringIO.new }
  let(:key) { 'pr-123-run-456' }

  subject(:publisher) { described_class.new(key: key, key_ttl: 21_600, queue: queue, output: output) }

  before do
    # Ensure stdin appears as a TTY so we test the other paths
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdin).to receive(:ready?).and_return(false)
  end

  describe '#publish with direct file arguments' do
    it 'pushes files to the queue with ttl and returns count' do
      files = ['spec/a_spec.rb', 'spec/b_spec.rb']
      expect(queue).to receive(:push).with(key, files, ttl: 21_600).and_return(2)
      expect(queue).to receive(:mark_published).with(key, ttl: 21_600)

      count = publisher.publish(files: files)

      expect(count).to eq(2)
      expect(output.string).to include('Enqueued 2 files')
    end

    it 'logs the Redis latency of the push and publish-marker round-trips' do
      files = ['spec/a_spec.rb', 'spec/b_spec.rb']
      allow(queue).to receive(:push).with(key, files, ttl: 21_600).and_return(2)
      allow(queue).to receive(:mark_published).with(key, ttl: 21_600)

      publisher.publish(files: files)

      expect(output.string).to match(/Redis latency: push \d+\.\d+ms, mark published \d+\.\d+ms\./)
    end
  end

  describe '#publish with pattern' do
    it 'resolves files via Dir.glob' do
      allow(Dir).to receive(:glob).with('spec/**/*_spec.rb')
                                  .and_return(['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'])
      expect(queue).to receive(:push).with(key, ['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'],
                                           ttl: 21_600).and_return(3)
      expect(queue).to receive(:mark_published).with(key, ttl: 21_600)

      count = publisher.publish(pattern: 'spec/**/*_spec.rb')

      expect(count).to eq(3)
      expect(output.string).to include('Enqueued 3 files')
    end
  end

  describe '#publish with stdin' do
    it 'reads file paths from stdin' do
      stdin_content = StringIO.new("spec/x_spec.rb\nspec/y_spec.rb\n\n")
      allow($stdin).to receive(:tty?).and_return(false)
      allow($stdin).to receive(:ready?).and_return(true)
      allow($stdin).to receive(:each_line).and_return(stdin_content.each_line)

      expect(queue).to receive(:push)
        .with(key, ['spec/x_spec.rb', 'spec/y_spec.rb'], ttl: 21_600)
        .and_return(2)
      expect(queue).to receive(:mark_published).with(key, ttl: 21_600)

      count = publisher.publish
      expect(count).to eq(2)
    end
  end

  describe '#publish with no files' do
    it 'returns 0, prints a message, and does not mark the key published' do
      expect(queue).not_to receive(:mark_published)

      count = publisher.publish(files: [])

      expect(count).to eq(0)
      expect(output.string).to include('No files to enqueue')
    end
  end

  describe '#publish with reset' do
    let(:files) { ['spec/a_spec.rb', 'spec/b_spec.rb'] }

    before do
      allow(queue).to receive(:push).with(key, files, ttl: 21_600).and_return(2)
      allow(queue).to receive(:mark_published).with(key, ttl: 21_600)
    end

    it 'clears the key before pushing' do
      allow(queue).to receive(:length).with(key).and_return(0)

      expect(queue).to receive(:clear).with(key).ordered
      expect(queue).to receive(:push).with(key, files, ttl: 21_600).and_return(2).ordered

      publisher.publish(files: files, reset: true)
    end

    it 'reports how many files an earlier push left behind' do
      allow(queue).to receive(:length).with(key).and_return(4213)
      allow(queue).to receive(:clear).with(key)

      publisher.publish(files: files, reset: true)

      expect(output.string).to include("Reset key '#{key}': discarded 4213 queued files from a previous push.")
    end

    it 'says so when the key was already empty' do
      allow(queue).to receive(:length).with(key).and_return(0)
      allow(queue).to receive(:clear).with(key)

      publisher.publish(files: files, reset: true)

      expect(output.string).to include("Reset key '#{key}': nothing left over.")
    end

    it 'does not clear when reset is not requested' do
      expect(queue).not_to receive(:clear)

      publisher.publish(files: files)
    end

    # Clearing here would drop the published marker with nothing to replace it,
    # and every worker on the key would then crash as "never published".
    it 'does not clear when there is nothing to push' do
      expect(queue).not_to receive(:clear)

      expect(publisher.publish(files: [], reset: true)).to eq(0)
    end
  end
end
