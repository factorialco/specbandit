# frozen_string_literal: true

require 'spec_helper'
require 'rspec/core'
require 'securerandom'
require 'tmpdir'
require 'fileutils'

# Integration test that exercises the full push -> steal -> run cycle
# using a real Redis connection. Skip if Redis is not available.
RSpec.describe 'Full cycle integration', :integration do
  let(:redis_url) { ENV.fetch('SPECBANDIT_REDIS_URL', 'redis://localhost:6379') }
  let(:key) { "specbandit-test-#{SecureRandom.hex(8)}" }
  let(:output) { StringIO.new }

  before(:each) do
    @redis = Redis.new(url: redis_url)
    @redis.ping
  rescue Redis::BaseError => e
    skip "Redis not available: #{e.message}"
  end

  after(:each) do
    begin
      @redis&.del(key, "#{key}:published", "#{key}:manifest")
      leftover = @redis&.scan_each(match: "#{key}*")&.to_a || []
      @redis&.del(*leftover) if leftover.any?
    rescue StandardError
      nil
    end
    begin
      @redis&.close
    rescue StandardError
      nil
    end
  end

  it 'pushes files and steals them back in batches' do
    files = (1..7).map { |i| "spec/fake_#{i}_spec.rb" }

    # Push phase
    queue = Specbandit::RedisQueue.new(redis_url: redis_url)
    queue.push(key, files)
    expect(queue.length(key)).to eq(7)

    # Steal phase - simulate two workers stealing batches of 3
    batch1 = queue.steal(key, 3)
    expect(batch1.size).to eq(3)
    expect(queue.length(key)).to eq(4)

    batch2 = queue.steal(key, 3)
    expect(batch2.size).to eq(3)
    expect(queue.length(key)).to eq(1)

    batch3 = queue.steal(key, 3)
    expect(batch3.size).to eq(1) # Last batch is smaller

    batch4 = queue.steal(key, 3)
    expect(batch4).to eq([]) # Queue exhausted

    # All files were distributed exactly once
    all_stolen = batch1 + batch2 + batch3
    expect(all_stolen.sort).to eq(files.sort)

    queue.close
  end

  it 'token steals are idempotent: replaying the same token returns the same batch' do
    files = (1..4).map { |i| "spec/fake_#{i}_spec.rb" }
    rerun = "#{key}-rerun-1"

    queue = Specbandit::RedisQueue.new(redis_url: redis_url)
    queue.push(key, files)

    batch = queue.steal(key, 2, token: 'tok-a', rerun_key: rerun, ttl: 600)
    expect(batch).to eq(files[0, 2])

    # A retry of the same steal (lost response scenario) must return the batch
    # that was already popped, NOT pop the next two files.
    replayed = queue.steal(key, 2, token: 'tok-a', rerun_key: rerun, ttl: 600)
    expect(replayed).to eq(batch)
    expect(queue.length(key)).to eq(2)

    # Recording rode along atomically.
    expect(queue.read_all(rerun)).to eq(files[0, 2])

    # A fresh token pops the next batch as usual.
    expect(queue.steal(key, 2, token: 'tok-b', rerun_key: rerun, ttl: 600)).to eq(files[2, 2])
    expect(queue.read_all(rerun)).to eq(files)

    queue.close
  end

  it 'audit passes when everything was stolen and fails when the manifest has an orphan' do
    files = %w[unit_a unit_b unit_c]

    queue = Specbandit::RedisQueue.new(redis_url: redis_url)
    publisher = Specbandit::Publisher.new(key: key, queue: queue, output: output)
    publisher.publish(files: files)

    queue.steal(key, 2, token: 't1', rerun_key: "#{key}-rerun-1", ttl: 600)
    queue.steal(key, 2, token: 't2', rerun_key: "#{key}-rerun-2", ttl: 600)

    auditor = Specbandit::Auditor.new(key: key, shards: 2, queue: queue, output: output)
    expect(auditor.audit).to eq(0)

    # Simulate a lost item: enqueue and drain it without any rerun record.
    queue.push(key, ['unit_lost'])
    queue.push("#{key}:manifest", ['unit_lost'])
    queue.steal(key, 1)

    expect(auditor.audit).to eq(1)
    expect(output.string).to include('unit_lost')

    queue.close
  end

  it 'publisher and worker work end-to-end' do
    Specbandit.configure do |c|
      c.redis_url = redis_url
      c.key = key
      c.batch_size = 2
    end

    # Create temporary spec files that pass
    dir = Dir.mktmpdir('specbandit-test')
    3.times do |i|
      File.write(File.join(dir, "pass_#{i}_spec.rb"), <<~RUBY)
        RSpec.describe "pass_#{i}" do
          it "passes" do
            expect(true).to eq(true)
          end
        end
      RUBY
    end

    spec_files = Dir.glob(File.join(dir, '*_spec.rb')).sort

    # Push
    publisher = Specbandit::Publisher.new(
      key: key,
      queue: Specbandit::RedisQueue.new(redis_url: redis_url),
      output: output
    )
    count = publisher.publish(files: spec_files)
    expect(count).to eq(3)

    # Work — using explicit RspecAdapter
    adapter = Specbandit::RspecAdapter.new(
      rspec_opts: ['--format', 'progress', '--no-color'],
      verbose: false,
      output: output
    )
    worker = Specbandit::Worker.new(
      key: key,
      batch_size: 2,
      adapter: adapter,
      queue: Specbandit::RedisQueue.new(redis_url: redis_url),
      output: output
    )
    exit_code = worker.run

    expect(exit_code).to eq(0)
    expect(output.string).to include('[specbandit] Summary')
    expect(output.string).to include('Batches:  2')
    expect(output.string).to include('Examples: 3')
    expect(output.string).to include('Failures: 0')
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it 'records only the individually failed files, not the whole batch' do
    key_failed = "#{key}-failed"

    Specbandit.configure do |c|
      c.redis_url = redis_url
      c.key = key
      # Use a large batch size so passing and failing files land in the same batch
      c.batch_size = 10
    end

    # Create temporary spec files: 2 pass, 1 fails — all in one batch
    dir = Dir.mktmpdir('specbandit-test')
    2.times do |i|
      File.write(File.join(dir, "pass_#{i}_spec.rb"), <<~RUBY)
        RSpec.describe "pass_#{i}" do
          it "passes" do
            expect(true).to eq(true)
          end
        end
      RUBY
    end
    File.write(File.join(dir, 'fail_0_spec.rb'), <<~RUBY)
      RSpec.describe "fail_0" do
        it "fails" do
          expect(true).to eq(false)
        end
      end
    RUBY

    spec_files = Dir.glob(File.join(dir, '*_spec.rb')).sort

    # Push
    redis_queue = Specbandit::RedisQueue.new(redis_url: redis_url)
    publisher = Specbandit::Publisher.new(
      key: key,
      queue: redis_queue,
      output: output
    )
    count = publisher.publish(files: spec_files)
    expect(count).to eq(3)

    # Work with key_failed configured
    adapter = Specbandit::RspecAdapter.new(
      rspec_opts: ['--format', 'progress', '--no-color'],
      verbose: false,
      output: output
    )
    worker = Specbandit::Worker.new(
      key: key,
      batch_size: 10,
      adapter: adapter,
      key_failed: key_failed,
      queue: Specbandit::RedisQueue.new(redis_url: redis_url),
      output: output
    )
    exit_code = worker.run

    expect(exit_code).to eq(1)

    # Verify only the failing file was recorded, not the passing ones
    failed_files = redis_queue.read_all(key_failed)
    expect(failed_files.size).to eq(1)
    expect(failed_files.first).to end_with('fail_0_spec.rb')

    redis_queue.close
  ensure
    @redis&.del(key_failed) if key_failed
    FileUtils.rm_rf(dir) if dir
  end
end
