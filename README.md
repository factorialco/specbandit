<p align="center">
  <img src="specbandit.png" alt="specbandit logo" width="200">
</p>

# specbandit

Distributed test runner using Redis as a work queue. One process pushes test file paths to a Redis list; multiple CI runners atomically steal batches and execute them via a pluggable adapter.

```
CI Job 1 (push):    RPUSH key f1 f2 f3 ... fN  -->  [Redis List]
CI Job 2 (worker):  LPOP key 5  <--  [Redis List]  -->  adapter (cli/rspec)
CI Job 3 (worker):  LPOP key 5  <--  [Redis List]  -->  adapter (cli/rspec)
CI Job N (worker):  LPOP key 5  <--  [Redis List]  -->  adapter (cli/rspec)
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

## Adapters

specbandit v0.7.0 introduces a pluggable adapter architecture. Two adapters ship out of the box:

| Adapter | Default? | How it runs | Best for |
|---------|----------|-------------|----------|
| `cli` | Yes | Spawns a shell command per batch | Any test runner (Jest, pytest, Go test, etc.) |
| `rspec` | No | Runs `RSpec::Core::Runner` in-process | RSpec (fastest, richest reporting) |

### CLI adapter (default)

The CLI adapter spawns a shell command for each batch, appending file paths as arguments. It works with any test runner.

```bash
# Run RSpec via CLI adapter
specbandit work --key KEY --command "bundle exec rspec"

# Run with extra options
specbandit work --key KEY --command "bundle exec rspec" --command-opts "--format documentation"

# Run Jest
specbandit work --key KEY --command "npx jest"

# Forward args after -- (merged with --command-opts)
specbandit work --key KEY --command "bundle exec rspec" -- --format documentation
```

### RSpec adapter

The RSpec adapter runs `RSpec::Core::Runner.run` in-process with `RSpec.clear_examples` between batches. No subprocess forking overhead. Provides rich reporting with per-example details, failure messages, and JSON accumulation.

```bash
specbandit work --key KEY --adapter rspec

# With RSpec options
specbandit work --key KEY --adapter rspec --rspec-opts "--format documentation"

# JSON output for CI artifact collection
specbandit work --key KEY --adapter rspec -- --format json --out results.json
```

### Migration from v0.6.x

In v0.6.x, RSpec was the only execution method and was always used implicitly. In v0.7.0, the default adapter changed to `cli`. To keep the previous behavior, add `--adapter rspec`:

```bash
# v0.6.x
specbandit work --key KEY

# v0.7.0 equivalent
specbandit work --key KEY --adapter rspec
```

Or set the environment variable:

```bash
export SPECBANDIT_ADAPTER=rspec
```

## Usage

### 1. Push test files to Redis

A single CI job enqueues all test file paths before workers start.

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
# Using CLI adapter (default) -- works with any test runner
specbandit work --key pr-123-run-456 --command "bundle exec rspec" --batch-size 10

# Using RSpec adapter -- in-process, fastest for RSpec
specbandit work --key pr-123-run-456 --adapter rspec --batch-size 10
```

Each worker loops:
1. `LPOP` N file paths from Redis (atomic)
2. Execute them via the configured adapter
3. Repeat until the queue is empty
4. Exit 0 if all batches passed, 1 if any failed

A failing batch does **not** stop the worker. It continues stealing remaining work so other runners aren't blocked waiting on files that will never be consumed.

### CLI reference

```
specbandit push [options] [files...]
  --key KEY              Redis queue key (required)
  --pattern PATTERN      Glob pattern for file discovery
  --redis-url URL        Redis URL (default: redis://localhost:6379)
  --key-ttl SECONDS      TTL for all Redis keys (default: 604800 / 1 week)

specbandit work [options] [-- extra-opts...]
  --key KEY              Redis queue key (required)
  --adapter TYPE         Adapter type: 'cli' (default) or 'rspec'
  --command CMD          Command to run (required for cli adapter)
  --command-opts OPTS    Extra options forwarded to the command (space-separated)
  --rspec-opts OPTS      Extra options forwarded to RSpec (for rspec adapter)
  --batch-size N         Files per batch (default: 5)
  --redis-url URL        Redis URL (default: redis://localhost:6379)
  --key-rerun KEY        Per-runner rerun key for re-run support (see below)
  --key-failed KEY       Redis key to record failed test files
  --key-ttl SECONDS      TTL for all Redis keys (default: 604800 / 1 week)
  --verbose              Show per-batch file list and full command output

Arguments after -- are forwarded to the adapter. They are merged with
--command-opts (cli adapter) or --rspec-opts (rspec adapter).
```

### Environment variables

All CLI options can be set via environment variables:

| Variable | Description | Default |
|---|---|---|
| `SPECBANDIT_KEY` | Redis queue key | _(required)_ |
| `SPECBANDIT_REDIS_URL` | Redis connection URL | `redis://localhost:6379` |
| `SPECBANDIT_ADAPTER` | Adapter type (`cli` or `rspec`) | `cli` |
| `SPECBANDIT_COMMAND` | Command to run (cli adapter) | _(none)_ |
| `SPECBANDIT_COMMAND_OPTS` | Space-separated command options | _(none)_ |
| `SPECBANDIT_BATCH_SIZE` | Files per steal | `5` |
| `SPECBANDIT_KEY_TTL` | Expiry (seconds) for **all** Redis keys | `604800` (1 week) |
| `SPECBANDIT_RSPEC_OPTS` | Space-separated RSpec options (rspec adapter) | _(none)_ |
| `SPECBANDIT_KEY_RERUN` | Per-runner rerun key | _(none)_ |
| `SPECBANDIT_KEY_FAILED` | Redis key for failed test files | _(none)_ |
| `SPECBANDIT_VERBOSE` | Enable verbose output (`1`/`true`/`yes`) | _(false)_ |

CLI flags take precedence over environment variables.

### Ruby API

```ruby
require "specbandit"

Specbandit.configure do |c|
  c.redis_url      = "redis://my-redis:6379"
  c.key            = "pr-123-run-456"
  c.batch_size     = 10
  c.key_ttl        = 604_800 # 1 week (default) -- applies to every key specbandit writes
  c.key_rerun      = "pr-123-run-456-runner-3"
end

# Push
publisher = Specbandit::Publisher.new
publisher.publish(pattern: "spec/**/*_spec.rb")

# Work with CLI adapter (default)
adapter = Specbandit::CliAdapter.new(
  command: "bundle exec rspec",
  command_opts: ["--format", "documentation"]
)
worker = Specbandit::Worker.new(adapter: adapter)
exit_code = worker.run

# Work with RSpec adapter (in-process)
adapter = Specbandit::RspecAdapter.new(
  rspec_opts: ["--format", "documentation"]
)
worker = Specbandit::Worker.new(adapter: adapter)
exit_code = worker.run

# Legacy: passing rspec_opts directly still works (auto-creates RspecAdapter)
worker = Specbandit::Worker.new(rspec_opts: ["--format", "documentation"])
exit_code = worker.run
```

## Example: GitHub Actions (basic)

### Using RSpec adapter (in-process)

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
            --adapter rspec \
            --batch-size 10
```

### Using CLI adapter (any test runner)

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
            --command "bundle exec rspec" \
            --batch-size 10
```

## Re-running failed CI jobs

### The problem

When you use specbandit to distribute tests across multiple CI runners (e.g. a GitHub Actions matrix with 4 runners), each runner **steals** a random subset of spec files from the shared Redis queue. The distribution is non-deterministic -- which runner gets which files depends on timing.

This creates a subtle but serious problem with CI re-runs:

1. **First run**: Runner #3 steals and executes files X, Y, Z. File Y fails. The shared queue is now empty (all files were consumed across all runners).
2. **Re-run of runner #3**: GitHub Actions re-runs only the failed runner. It starts `specbandit work` again with the same `--key`, but the shared queue is already empty. Without a per-runner memory the runner would see nothing to do and exit 0 -- silently passing the failing test.

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

### How it works: the mode is derived from Redis, never from a flag

Specbandit decides what to do purely from the **state of Redis** -- there is no `--rerun` flag or environment variable to get wrong. Two signals drive the decision:

- **Published marker.** `specbandit push` writes a durable companion key (`<key>:published`) alongside the queue. Because Redis auto-deletes empty lists, a drained queue is indistinguishable from one that was never created -- the marker is the only reliable proof that work was ever enqueued.
- **Rerun key.** The per-runner `--key-rerun` that records what this runner executed.

The full decision table:

| Published | Shared queue (`--key`) | Rerun key (`--key-rerun`) | Behavior |
|---|---|---|---|
| **No** | -- | -- | **Crash** (exit 1). Nothing was ever pushed for this key (or it expired). Refuses to run rather than silently pass. |
| Yes | Drained / empty | Empty | **OK, exit 0.** Worker arriving late -- everything was already taken by peers and this runner has no re-run memory. |
| Yes | Has data | Empty | **Steal.** Classic run: pop batches from the shared queue (and record them to the rerun key if one is configured). |
| Yes | Drained / empty | Has data | **Replay.** Classic re-run: ignore the shared queue and re-run exactly the recorded files. |
| Yes | Has data | Has data | **Full rerun.** The queue was re-pushed while this runner still holds rerun memory from a previous run. The stale rerun key is deleted and the runner steals from the shared queue like a classic run, re-recording as it goes. |

> **Empty key names count as "not provided".** A `--key-rerun` whose value is an empty string -- e.g. `--key-rerun "$VAR"` where `$VAR` is unset in CI -- is treated exactly like `--key-rerun` being absent. The same applies to `--key-failed`: an empty/unset name is treated as "not configured" and no failed files are recorded.

> **The published marker replaces the old `--rerun` flag.** Earlier versions used a `--rerun` / `SPECBANDIT_RERUN` flag (driven by `github.run_attempt`) to decide whether to fail on an empty rerun key. That flag is gone: the marker lets specbandit tell "never pushed" (crash) apart from "drained, arriving late" (exit 0) without any CI-provided hint. Drop `--rerun` / `SPECBANDIT_RERUN` from your config.

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

- **Replay reads non-destructively** (`LRANGE`, not `LPOP`). Replay never consumes the rerun key, so re-running the same runner multiple times replays the same files every time. The one case where the rerun key is deleted (`DEL`) is a **full rerun** -- the shared queue has data again while the rerun key still holds files from a previous run -- where the stale memory is reset and rebuilt from the newly stolen batches.
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
            --adapter rspec \
            --batch-size 10
```

The only difference from the basic example is the addition of `--key-rerun` (no re-run flag needed -- the mode is derived from Redis). The key structure:

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

### Key TTL

A **single** TTL governs every key specbandit writes -- the shared queue, its published marker, the per-runner rerun key, and the failed key. It defaults to **1 week** (`604800` seconds), long enough that re-runs happening hours or even days after the original CI run still find their rerun key and published marker alive.

Override via `--key-ttl` or `SPECBANDIT_KEY_TTL` (set it on `push`, which is where the queue and its marker are created):

```bash
# Everything expires after 3 days
specbandit push --key "pr-42-run-100" --key-ttl 259200 --pattern 'spec/**/*_spec.rb'
```

## How it works

- **Push** uses `RPUSH` to append all file paths to a Redis list in a single command, sets `EXPIRE` on the key, and writes a durable `<key>:published` marker (with the same TTL). Empty Redis lists are auto-deleted, so this marker is what lets `work` tell "never pushed" (crash) apart from "drained, arriving late" (exit 0).
- **Steal** uses `LPOP key count` (Redis 6.2+), which atomically pops up to N elements. No Lua scripts, no locks, no race conditions.
- **Record** (when `--key-rerun` is set): after each steal, the batch is also `RPUSH`ed to the per-runner rerun key.
- **Replay** (when the rerun key has data and the shared queue is drained): reads all files from the rerun key via `LRANGE` (non-destructive), splits into batches, and runs them locally. The shared queue is never touched.
- **Full rerun** (when both the shared queue and the rerun key have data): the stale rerun key is removed with `DEL`, then the runner steals from the shared queue and re-records as in a classic run.
- **Mode selection** is derived entirely from Redis (published marker + queue/rerun state) -- see the decision table above. There is no re-run flag or environment variable.
- **Run** delegates to the configured adapter:
  - **CLI adapter**: spawns a shell command per batch via `Open3`, appending file paths as arguments. Works with any test runner.
  - **RSpec adapter**: uses `RSpec::Core::Runner.run` in-process with `RSpec.clear_examples` between batches to reset example state while preserving configuration. No subprocess forking overhead.
- **Exit code** is 0 if every batch passed (or the queue was already empty), 1 if any batch had failures.

## Development

```bash
bundle install
bundle exec rspec                    # unit tests (no Redis needed)
bundle exec rspec spec/integration/  # integration tests (requires Redis on localhost:6379)
```

## License

MIT
