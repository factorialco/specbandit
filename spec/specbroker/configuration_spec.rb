# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Specbroker::Configuration do
  subject(:config) { described_class.new }

  describe 'defaults' do
    it 'uses default redis_url' do
      expect(config.redis_url).to eq('redis://localhost:6379')
    end

    it 'uses default batch_size' do
      expect(config.batch_size).to eq(5)
    end

    it 'has nil key by default' do
      expect(config.key).to be_nil
    end

    it 'has empty rspec_opts by default' do
      expect(config.rspec_opts).to eq([])
    end

    it 'uses default key_ttl of 6 hours' do
      expect(config.key_ttl).to eq(21_600)
    end
  end

  describe 'environment variable overrides' do
    around do |example|
      original_env = ENV.to_h.slice(
        'SPECBROKER_REDIS_URL',
        'SPECBROKER_BATCH_SIZE',
        'SPECBROKER_KEY',
        'SPECBROKER_RSPEC_OPTS',
        'SPECBROKER_KEY_TTL'
      )
      example.run
    ensure
      ENV.delete('SPECBROKER_REDIS_URL')
      ENV.delete('SPECBROKER_BATCH_SIZE')
      ENV.delete('SPECBROKER_KEY')
      ENV.delete('SPECBROKER_RSPEC_OPTS')
      ENV.delete('SPECBROKER_KEY_TTL')
      original_env.each { |k, v| ENV[k] = v }
    end

    it 'reads redis_url from SPECBROKER_REDIS_URL' do
      ENV['SPECBROKER_REDIS_URL'] = 'redis://custom:6380'
      config = described_class.new
      expect(config.redis_url).to eq('redis://custom:6380')
    end

    it 'reads batch_size from SPECBROKER_BATCH_SIZE' do
      ENV['SPECBROKER_BATCH_SIZE'] = '10'
      config = described_class.new
      expect(config.batch_size).to eq(10)
    end

    it 'reads key from SPECBROKER_KEY' do
      ENV['SPECBROKER_KEY'] = 'pr-42-run-99'
      config = described_class.new
      expect(config.key).to eq('pr-42-run-99')
    end

    it 'parses rspec_opts from SPECBROKER_RSPEC_OPTS' do
      ENV['SPECBROKER_RSPEC_OPTS'] = '--format documentation --color'
      config = described_class.new
      expect(config.rspec_opts).to eq(['--format', 'documentation', '--color'])
    end

    it 'reads key_ttl from SPECBROKER_KEY_TTL' do
      ENV['SPECBROKER_KEY_TTL'] = '3600'
      config = described_class.new
      expect(config.key_ttl).to eq(3600)
    end
  end

  describe '#validate!' do
    it 'raises when key is nil' do
      config.key = nil
      expect { config.validate! }.to raise_error(
        Specbroker::Error, /key is required/
      )
    end

    it 'raises when key is empty' do
      config.key = ''
      expect { config.validate! }.to raise_error(
        Specbroker::Error, /key is required/
      )
    end

    it 'raises when batch_size is not positive' do
      config.key = 'valid-key'
      config.batch_size = 0
      expect { config.validate! }.to raise_error(
        Specbroker::Error, /batch_size must be a positive integer/
      )
    end

    it 'raises when key_ttl is not positive' do
      config.key = 'valid-key'
      config.key_ttl = 0
      expect { config.validate! }.to raise_error(
        Specbroker::Error, /key_ttl must be a positive integer/
      )
    end

    it 'passes when key and batch_size are valid' do
      config.key = 'valid-key'
      config.batch_size = 3
      expect { config.validate! }.not_to raise_error
    end
  end
end
