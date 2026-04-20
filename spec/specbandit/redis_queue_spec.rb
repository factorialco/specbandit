# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Specbandit::RedisQueue do
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

  describe '#read_all' do
    it 'returns all elements via LRANGE non-destructively' do
      files = ['spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb']
      expect(redis_double).to receive(:lrange).with('my-key', 0, -1).and_return(files)

      result = queue.read_all('my-key')
      expect(result).to eq(files)
    end

    it 'returns empty array when key does not exist' do
      expect(redis_double).to receive(:lrange).with('missing-key', 0, -1).and_return([])

      result = queue.read_all('missing-key')
      expect(result).to eq([])
    end
  end

  describe 'retry on connection failure' do
    before do
      allow(queue).to receive(:sleep)
      allow(queue).to receive(:warn)
    end

    it 'retries and succeeds on transient connection error' do
      call_count = 0
      allow(redis_double).to receive(:llen).with('my-key') do
        call_count += 1
        raise Redis::CannotConnectError, 'connection refused' if call_count < 3

        42
      end

      expect(queue.length('my-key')).to eq(42)
      expect(call_count).to eq(3)
    end

    it 'raises after exhausting all 3 attempts' do
      allow(redis_double).to receive(:llen).with('my-key')
                                           .and_raise(Redis::CannotConnectError, 'connection refused')

      expect { queue.length('my-key') }.to raise_error(Redis::CannotConnectError)
    end

    it 'uses exponential backoff with base 1s' do
      call_count = 0
      allow(redis_double).to receive(:llen).with('my-key') do
        call_count += 1
        raise Redis::CannotConnectError, 'connection refused' if call_count < 3

        42
      end

      queue.length('my-key')

      expect(queue).to have_received(:sleep).with(2).ordered
      expect(queue).to have_received(:sleep).with(4).ordered
    end

    it 'prints a warning to stderr on each retry' do
      call_count = 0
      allow(redis_double).to receive(:llen).with('my-key') do
        call_count += 1
        raise Redis::CannotConnectError, 'connection refused' if call_count < 2

        42
      end

      queue.length('my-key')

      expect(queue).to have_received(:warn).with(%r{Redis connection failed \(attempt 1/3\).*Retrying in 2s})
    end
  end

  describe '#close' do
    it 'closes the Redis connection' do
      expect(redis_double).to receive(:close)
      queue.close
    end
  end
end
