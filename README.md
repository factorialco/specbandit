# specbandit

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
gem "specbandit"
```

Or install directly:

```bash
gem install specbandit
```

**Requirements**: Ruby >= 3.0, Redis >= 6.2

## Usage

### 1. Push spec files to Redis

A single CI job enqueues all spec file paths before workers start.

```bash
# Via glob pattern (resolved in Ruby, avoids shell ARG_MAX limits)
specbandit push --key pr-123-run-456 --pattern 'spec/**/*_spec.rb'

# Via stdin pipe (for large file lists or custom filtering)
find spec -name '*_spec.rb' | specbandit push --key pr-123-run-456

# Via direct arguments (for small lists)
specbandit push --key pr-123-run-456 spec/models/user_spec.rb spec/models/order_spec.rb
```

File input priority: **stdin > --pattern > direct args**.

### 2. Steal and run from multiple workers

Each CI runner steals batches and runs them. Start as many runners as you want -- they'll divide the work automatically.

```bash
specbandit work --key pr-123-run-456 --batch-size 10
```

Each worker loops:
1. `LPOP` N file paths from Redis (atomic)
2. Run them in-process via `RSpec::Core::Runner`
3. Repeat until the queue is empty
4. Exit 0 if all batches passed, 1 if any failed

A failing batch does **not** stop the worker. It continues stealing remaining work so other runners aren't blocked waiting on files that will never be consumed.

### CLI reference

```
specbandit push [options] [files...]
  --key KEY              Redis queue key (required)
  --pattern PATTERN      Glob pattern for file discovery
  --redis-url URL        Redis URL (default: redis://localhost:6379)
  --key-ttl SECONDS      TTL for the Redis key (default: 21600 / 6 hours)

specbandit work [options]
  --key KEY              Redis queue key (required)
  --batch-size N         Files per batch (default: 5)
  --redis-url URL        Redis URL (default: redis://localhost:6379)
  --rspec-opts OPTS      Extra options forwarded to RSpec
  --key-rerun KEY        Per-runner rerun key for re-run support (see below)
  --key-rerun-ttl SECS   TTL for rerun key (default: 604800 / 1 week)
```

### Environment variables

All CLI options can be set via environment variables:

| Variable | Description | Default |
|---|---|---|
| `SPECBANDIT_KEY` | Redis queue key | _(required)_ |
| `SPECBANDIT_REDIS_URL` | Redis connection URL | `redis://localhost:6379` |
| `SPECBANDIT_BATCH_SIZE` | Files per steal | `5` |
| `SPECBANDIT_KEY_TTL` | Key expiry in seconds | `21600` (6 hours) |
| `SPECBANDIT_RSPEC_OPTS` | Space-separated RSpec options | _(none)_ |
| `SPECBANDIT_KEY_RERUN` | Per-runner rerun key | _(none)_ |
| `SPECBANDIT_KEY_RERUN_TTL` | Rerun key expiry in seconds | `604800` (1 week) |

CLI flags take precedence over environment variables.

### Ruby API

```ruby
require "specbandit"

Specbandit.configure do |c|
  c.redis_url      = "redis://my-redis:6379"
  c.key            = "pr-123-run-456"
  c.batch_size     = 10
  c.key_ttl        = 7200 # 2 hours (default: 21600 / 6 hours)
  c.key_rerun      = "pr-123-run-456-runner-3"
  c.key_rerun_ttl  = 604_800 # 1 week (default)
  c.rspec_opts     = ["--format", "documentation"]
end

# Push
publisher = Specbandit::Publisher.new
publisher.publish(pattern: "spec/**/*_spec.rb")

# Work (will auto-detect steal/record/replay mode based on key_rerun state)
worker = Specbandit::Worker.new
exit_code = worker.run
```

## Example: GitHub Actions (basic)

```yaml
jobs:
  push-specs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bundle install
      - run: |
          specbandit push \
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
          specbandit work \
            --key "pr-${{ github.event.number }}-${{ github.run_id }}" \
            --redis-url "${{ secrets.REDIS_URL }}" \
            --batch-size 10
```

## Re-running failed CI jobs

### The problem

When you use specbandit to distribute tests across multiple CI runners (e.g. a GitHub Actions matrix with 4 runners), each runner **steals** a random subset of spec files from the shared Redis queue. The distribution is non-deterministic -- which runner gets which files depends on timing.

This creates a subtle but serious problem with CI re-runs:

1. **First run**: Runner #3 steals and executes files X, Y, Z. File Y fails. The shared queue is now empty (all files were consumed across all runners).
2. **Re-run of runner #3**: GitHub Actions re-runs only the failed runner. It starts `specbandit work` again with the same `--key`, but the shared queue is already empty. Runner #3 sees nothing to do and **exits 0 -- the failing test silently passes**.

This happens because GitHub Actions re-runs **reuse the same `run_id`**, so the key resolves to the same (now empty) Redis list.

### The solution: `--key-rerun`

The `--key-rerun` flag gives each matrix runner its own "memory" in Redis. It enables specbandit to **record** which files each runner executed, and **replay** exactly those files on a re-run.

Each runner gets a unique rerun key (typically including the matrix index):

```bash
specbandit work \
  --key "pr-42-run-100" \
  --key-rerun "pr-42-run-100-runner-3" \
  --batch-size 10
```

### How it works: three operating modes

Specbandit detects the mode automatically based on the state of `--key-rerun`:

| `--key-rerun` provided? | Rerun key in Redis | Mode | Behavior |
|---|---|---|---|
| No | -- | **Steal** | Original behavior. Steal from shared queue, run, done. |
| Yes | Empty | **Record** | Steal from shared queue + record each batch to the rerun key. |
| Yes | Has data | **Replay** | Ignore shared queue entirely. Re-run exactly the recorded files. |

**On first run**, the rerun key doesn't exist yet (empty), so specbandit enters **record mode**:

```
┌──────────────────┐   LPOP N    ┌──────────────────┐   RPUSH    ┌──────────────────────────────┐
│  Redis            │ ─────────> │  Runner #3        │ ────────> │  Redis                        │
│  --key            │            │                   │           │  --key-rerun                   │
│  (shared queue)   │            │  steal + record   │           │  (per-runner memory)           │
│                   │            │  + run specs      │           │                                │
│  [f1,f2,...,fN]   │            │                   │           │  [f5,f6,f7] ← what #3 stole   │
└──────────────────┘            └──────────────────┘           └──────────────────────────────┘
```

**On re-run**, the rerun key already contains the files from the first run, so specbandit enters **replay mode**:

```
                                ┌──────────────────┐  LRANGE    ┌──────────────────────────────┐
   --key NOT touched            │  Runner #3        │ <──────── │  Redis                        │
                                │                   │           │  --key-rerun                   │
                                │  replay specs     │           │  (per-runner memory)           │
                                │  f5, f6, f7       │           │                                │
                                └──────────────────┘           │  [f5,f6,f7] ← still there      │
                                                               └──────────────────────────────┘
```

Key details:

- **Replay reads non-destructively** (`LRANGE`, not `LPOP`). The rerun key is never consumed. If you re-run the same runner multiple times, it replays the same files every time.
- **The shared queue is never touched in replay mode**. Other runners are unaffected.
- **Each runner has its own rerun key**. Only the re-run runner enters replay mode; runners that aren't re-run don't start at all.

### Complete GitHub Actions example with re-run support

```yaml
jobs:
  push-specs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bundle install
      - run: |
          specbandit push \
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
          specbandit work \
            --key "pr-${{ github.event.number }}-${{ github.run_id }}" \
            --key-rerun "pr-${{ github.event.number }}-${{ github.run_id }}-runner-${{ matrix.runner }}" \
            --redis-url "${{ secrets.REDIS_URL }}" \
            --batch-size 10
```

The only difference from the basic example is the addition of `--key-rerun`. The key structure:

- `--key` = `pr-42-run-100` -- **shared** across all 4 runners, same on re-run (because `run_id` is reused)
- `--key-rerun` = `pr-42-run-100-runner-3` -- **unique per runner**, same on re-run

### Walk-through: what happens step by step

**First run (all 4 runners start fresh):**

| Runner | Mode | What happens |
|---|---|---|
| Runner 1 | Record | Steals files A, B, C from shared queue. Records them to `...-runner-1`. |
| Runner 2 | Record | Steals files D, E from shared queue. Records them to `...-runner-2`. |
| Runner 3 | Record | Steals files F, G, H from shared queue. File G fails. Records them to `...-runner-3`. |
| Runner 4 | Record | Steals files I, J from shared queue. Records them to `...-runner-4`. |

**Re-run of runner 3 only:**

| Runner | Mode | What happens |
|---|---|---|
| Runner 3 | Replay | Reads F, G, H from `...-runner-3`. Runs exactly those files. G still fails = correctly reported. |

Runners 1, 2, 4 are not started at all.

### Rerun key TTL

The rerun key defaults to a **1 week TTL** (`604800` seconds). This is intentionally longer than the shared queue TTL (6 hours) because re-runs can happen hours or even days after the original CI run.

Override via `--key-rerun-ttl` or `SPECBANDIT_KEY_RERUN_TTL`:

```bash
# Set rerun key to expire after 3 days
specbandit work \
  --key "pr-42-run-100" \
  --key-rerun "pr-42-run-100-runner-3" \
  --key-rerun-ttl 259200
```

## How it works

- **Push** uses `RPUSH` to append all file paths to a Redis list in a single command, then sets `EXPIRE` on the key (default: 6 hours) to ensure stale queues are automatically cleaned up.
- **Steal** uses `LPOP key count` (Redis 6.2+), which atomically pops up to N elements. No Lua scripts, no locks, no race conditions.
- **Record** (when `--key-rerun` is set): after each steal, the batch is also `RPUSH`ed to the per-runner rerun key with its own TTL (default: 1 week).
- **Replay** (when `--key-rerun` has data): reads all files from the rerun key via `LRANGE` (non-destructive), splits into batches, and runs them locally. The shared queue is never touched.
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
