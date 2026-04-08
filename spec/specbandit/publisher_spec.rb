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

      count = publisher.publish(files: files)

      expect(count).to eq(2)
      expect(output.string).to include('Enqueued 2 files')
    end
  end

  describe '#publish with pattern' do
    it 'resolves files via Dir.glob' do
      allow(Dir).to receive(:glob).with('spec/**/*_spec.rb')
                                  .and_return(['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'])
      expect(queue).to receive(:push).with(key, ['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'],
                                           ttl: 21_600).and_return(3)

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

      count = publisher.publish
      expect(count).to eq(2)
    end
  end

  describe '#publish with no files' do
    it 'returns 0 and prints a message' do
      count = publisher.publish(files: [])

      expect(count).to eq(0)
      expect(output.string).to include('No files to enqueue')
    end
  end
end
