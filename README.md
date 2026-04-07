# specbroker

Distributed RSpec runner using Redis as a work queue. One process pushes spec file paths to a Redis list; multiple CI runners atomically steal batches and execute them in-process via `RSpec::Core::Runner`.

```
CI Job 1 (push):    RPUSH key f1 f2 f3 ... fN  -->  [Redis List]
CI Job 2 (worker):  LPOP key 5  <--  [Redis List]  -->  RSpec
CI Job 3 (worker):  LPOP key 5  <--  [Redis List]  -->  RSpec
CI Job N (worker):  LPOP key 5  <--  [Redis List]  -->  RSpec
```

`LPOP` with a count argument (Redis 6.2+) is atomic -- multiple workers calling it concurrently will never receive the same file.

## Installation

Add to your Gemfile:

```ruby
gem "specbroker"
```

Or install directly:

```bash
gem install specbroker
```

**Requirements**: Ruby >= 3.0, Redis >= 6.2

## Usage

### 1. Push spec files to Redis

A single CI job enqueues all spec file paths before workers start.

```bash
# Via glob pattern (resolved in Ruby, avoids shell ARG_MAX limits)
specbroker push --key pr-123-run-456 --pattern 'spec/**/*_spec.rb'

# Via stdin pipe (for large file lists or custom filtering)
find spec -name '*_spec.rb' | specbroker push --key pr-123-run-456

# Via direct arguments (for small lists)
specbroker push --key pr-123-run-456 spec/models/user_spec.rb spec/models/order_spec.rb
```

File input priority: **stdin > --pattern > direct args**.

### 2. Steal and run from multiple workers

Each CI runner steals batches and runs them. Start as many runners as you want -- they'll divide the work automatically.

```bash
specbroker work --key pr-123-run-456 --batch-size 10
```

Each worker loops:
1. `LPOP` N file paths from Redis (atomic)
2. Run them in-process via `RSpec::Core::Runner`
3. Repeat until the queue is empty
4. Exit 0 if all batches passed, 1 if any failed

A failing batch does **not** stop the worker. It continues stealing remaining work so other runners aren't blocked waiting on files that will never be consumed.

### CLI reference

```
specbroker push [options] [files...]
  --key KEY            Redis queue key (required)
  --pattern PATTERN    Glob pattern for file discovery
  --redis-url URL      Redis URL (default: redis://localhost:6379)
  --key-ttl SECONDS    TTL for the Redis key (default: 21600 / 6 hours)

specbroker work [options]
  --key KEY            Redis queue key (required)
  --batch-size N       Files per batch (default: 5)
  --redis-url URL      Redis URL (default: redis://localhost:6379)
  --rspec-opts OPTS    Extra options forwarded to RSpec
```

### Environment variables

All CLI options can be set via environment variables:

| Variable | Description | Default |
|---|---|---|
| `SPECBROKER_KEY` | Redis queue key | _(required)_ |
| `SPECBROKER_REDIS_URL` | Redis connection URL | `redis://localhost:6379` |
| `SPECBROKER_BATCH_SIZE` | Files per steal | `5` |
| `SPECBROKER_KEY_TTL` | Key expiry in seconds | `21600` (6 hours) |
| `SPECBROKER_RSPEC_OPTS` | Space-separated RSpec options | _(none)_ |

CLI flags take precedence over environment variables.

### Ruby API

```ruby
require "specbroker"

Specbroker.configure do |c|
  c.redis_url  = "redis://my-redis:6379"
  c.key        = "pr-123-run-456"
  c.batch_size = 10
  c.key_ttl    = 7200 # 2 hours (default: 21600 / 6 hours)
  c.rspec_opts = ["--format", "documentation"]
end

# Push
publisher = Specbroker::Publisher.new
publisher.publish(pattern: "spec/**/*_spec.rb")

# Work
worker = Specbroker::Worker.new
exit_code = worker.run
```

## Example: GitHub Actions

```yaml
jobs:
  push-specs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bundle install
      - run: |
          specbroker push \
            --key "pr-${{ github.event.number }}-${{ github.run_id }}" \
            --redis-url "${{ secrets.REDIS_URL }}" \
            --pattern 'spec/**/*_spec.rb'

  run-specs:
    runs-on: ubuntu-latest
    needs: push-specs
    strategy:
      matrix:
        runner: [1, 2, 3, 4]
    steps:
      - uses: actions/checkout@v4
      - run: bundle install
      - run: |
          specbroker work \
            --key "pr-${{ github.event.number }}-${{ github.run_id }}" \
            --redis-url "${{ secrets.REDIS_URL }}" \
            --batch-size 10
```

## How it works

- **Push** uses `RPUSH` to append all file paths to a Redis list in a single command, then sets `EXPIRE` on the key (default: 6 hours) to ensure stale queues are automatically cleaned up.
- **Steal** uses `LPOP key count` (Redis 6.2+), which atomically pops up to N elements. No Lua scripts, no locks, no race conditions.
- **Run** uses `RSpec::Core::Runner.run` in-process with `RSpec.clear_examples` between batches to reset example state while preserving configuration. No subprocess forking overhead.
- **Exit code** is 0 if every batch passed (or the queue was already empty), 1 if any batch had failures.

## Development

```bash
bundle install
bundle exec rspec                    # unit tests (no Redis needed)
bundle exec rspec spec/integration/  # integration tests (requires Redis on localhost:6379)
```

## License

MIT
