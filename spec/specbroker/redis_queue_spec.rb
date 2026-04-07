# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Specbroker::RedisQueue do
  let(:redis_double) { instance_double(Redis) }

  subject(:queue) { described_class.new }

  before do
    allow(Redis).to receive(:new).and_return(redis_double)
  end

  describe '#push' do
    it 'calls RPUSH with the key and files' do
      files = ['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb']
      expect(redis_double).to receive(:rpush).with('my-key', files).and_return(3)

      result = queue.push('my-key', files)
      expect(result).to eq(3)
    end

    it 'sets EXPIRE when ttl is provided' do
      files = ['spec/a_spec.rb']
      expect(redis_double).to receive(:rpush).with('my-key', files).and_return(1)
      expect(redis_double).to receive(:expire).with('my-key', 3600)

      queue.push('my-key', files, ttl: 3600)
    end

    it 'does not set EXPIRE when ttl is nil' do
      files = ['spec/a_spec.rb']
      expect(redis_double).to receive(:rpush).with('my-key', files).and_return(1)
      expect(redis_double).not_to receive(:expire)

      queue.push('my-key', files)
    end

    it 'returns 0 for empty files without calling Redis' do
      expect(redis_double).not_to receive(:rpush)
      expect(queue.push('my-key', [])).to eq(0)
    end
  end

  describe '#steal' do
    it 'returns an array of files from LPOP' do
      expect(redis_double).to receive(:lpop).with('my-key', 3)
                                            .and_return(['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'])

      result = queue.steal('my-key', 3)
      expect(result).to eq(['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'])
    end

    it 'returns empty array when LPOP returns nil (queue exhausted)' do
      expect(redis_double).to receive(:lpop).with('my-key', 3).and_return(nil)

      result = queue.steal('my-key', 3)
      expect(result).to eq([])
    end

    it 'wraps a single string in an array' do
      expect(redis_double).to receive(:lpop).with('my-key', 1)
                                            .and_return('spec/only_spec.rb')

      result = queue.steal('my-key', 1)
      expect(result).to eq(['spec/only_spec.rb'])
    end
  end

  describe '#length' do
    it 'returns the list length' do
      expect(redis_double).to receive(:llen).with('my-key').and_return(42)
      expect(queue.length('my-key')).to eq(42)
    end
  end

  describe '#close' do
    it 'closes the Redis connection' do
      expect(redis_double).to receive(:close)
      queue.close
    end
  end
end
