# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Specbandit::Configuration do
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

    it 'has nil key_rerun by default' do
      expect(config.key_rerun).to be_nil
    end

    it 'uses default key_rerun_ttl of 1 week' do
      expect(config.key_rerun_ttl).to eq(604_800)
    end

    it 'uses cli as default adapter' do
      expect(config.adapter).to eq('cli')
    end

    it 'has nil command by default' do
      expect(config.command).to be_nil
    end

    it 'has empty command_opts by default' do
      expect(config.command_opts).to eq([])
    end
  end

  describe 'environment variable overrides' do
    around do |example|
      original_env = ENV.to_h.slice(
        'SPECBANDIT_REDIS_URL',
        'SPECBANDIT_BATCH_SIZE',
        'SPECBANDIT_KEY',
        'SPECBANDIT_RSPEC_OPTS',
        'SPECBANDIT_KEY_TTL',
        'SPECBANDIT_KEY_RERUN',
        'SPECBANDIT_KEY_RERUN_TTL',
        'SPECBANDIT_ADAPTER',
        'SPECBANDIT_COMMAND',
        'SPECBANDIT_COMMAND_OPTS'
      )
      example.run
    ensure
      ENV.delete('SPECBANDIT_REDIS_URL')
      ENV.delete('SPECBANDIT_BATCH_SIZE')
      ENV.delete('SPECBANDIT_KEY')
      ENV.delete('SPECBANDIT_RSPEC_OPTS')
      ENV.delete('SPECBANDIT_KEY_TTL')
      ENV.delete('SPECBANDIT_KEY_RERUN')
      ENV.delete('SPECBANDIT_KEY_RERUN_TTL')
      ENV.delete('SPECBANDIT_ADAPTER')
      ENV.delete('SPECBANDIT_COMMAND')
      ENV.delete('SPECBANDIT_COMMAND_OPTS')
      original_env.each { |k, v| ENV[k] = v }
    end

    it 'reads redis_url from SPECBANDIT_REDIS_URL' do
      ENV['SPECBANDIT_REDIS_URL'] = 'redis://custom:6380'
      config = described_class.new
      expect(config.redis_url).to eq('redis://custom:6380')
    end

    it 'reads batch_size from SPECBANDIT_BATCH_SIZE' do
      ENV['SPECBANDIT_BATCH_SIZE'] = '10'
      config = described_class.new
      expect(config.batch_size).to eq(10)
    end

    it 'reads key from SPECBANDIT_KEY' do
      ENV['SPECBANDIT_KEY'] = 'pr-42-run-99'
      config = described_class.new
      expect(config.key).to eq('pr-42-run-99')
    end

    it 'parses rspec_opts from SPECBANDIT_RSPEC_OPTS' do
      ENV['SPECBANDIT_RSPEC_OPTS'] = '--format documentation --color'
      config = described_class.new
      expect(config.rspec_opts).to eq(['--format', 'documentation', '--color'])
    end

    it 'reads key_ttl from SPECBANDIT_KEY_TTL' do
      ENV['SPECBANDIT_KEY_TTL'] = '3600'
      config = described_class.new
      expect(config.key_ttl).to eq(3600)
    end

    it 'reads key_rerun from SPECBANDIT_KEY_RERUN' do
      ENV['SPECBANDIT_KEY_RERUN'] = 'pr-42-run-99-runner-3'
      config = described_class.new
      expect(config.key_rerun).to eq('pr-42-run-99-runner-3')
    end

    it 'reads key_rerun_ttl from SPECBANDIT_KEY_RERUN_TTL' do
      ENV['SPECBANDIT_KEY_RERUN_TTL'] = '86400'
      config = described_class.new
      expect(config.key_rerun_ttl).to eq(86_400)
    end

    it 'reads adapter from SPECBANDIT_ADAPTER' do
      ENV['SPECBANDIT_ADAPTER'] = 'rspec'
      config = described_class.new
      expect(config.adapter).to eq('rspec')
    end

    it 'reads command from SPECBANDIT_COMMAND' do
      ENV['SPECBANDIT_COMMAND'] = 'bundle exec rspec'
      config = described_class.new
      expect(config.command).to eq('bundle exec rspec')
    end

    it 'parses command_opts from SPECBANDIT_COMMAND_OPTS' do
      ENV['SPECBANDIT_COMMAND_OPTS'] = '--format documentation --color'
      config = described_class.new
      expect(config.command_opts).to eq(['--format', 'documentation', '--color'])
    end
  end

  describe '#validate!' do
    it 'raises when key is nil' do
      config.key = nil
      expect { config.validate! }.to raise_error(
        Specbandit::Error, /key is required/
      )
    end

    it 'raises when key is empty' do
      config.key = ''
      expect { config.validate! }.to raise_error(
        Specbandit::Error, /key is required/
      )
    end

    it 'raises when batch_size is not positive' do
      config.key = 'valid-key'
      config.batch_size = 0
      expect { config.validate! }.to raise_error(
        Specbandit::Error, /batch_size must be a positive integer/
      )
    end

    it 'raises when key_ttl is not positive' do
      config.key = 'valid-key'
      config.key_ttl = 0
      expect { config.validate! }.to raise_error(
        Specbandit::Error, /key_ttl must be a positive integer/
      )
    end

    it 'raises when key_rerun_ttl is not positive' do
      config.key = 'valid-key'
      config.key_rerun_ttl = 0
      expect { config.validate! }.to raise_error(
        Specbandit::Error, /key_rerun_ttl must be a positive integer/
      )
    end

    it 'passes when key and batch_size are valid' do
      config.key = 'valid-key'
      config.batch_size = 3
      expect { config.validate! }.not_to raise_error
    end
  end
end
