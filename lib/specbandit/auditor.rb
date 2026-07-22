# frozen_string_literal: true

module Specbandit
  # Post-run reconciliation: compares what `push` enqueued (the `<key>:manifest`
  # copy) against what workers actually stole (the union of their rerun keys).
  #
  # A distributed queue drained to empty looks identical whether every item ran
  # or some were lost in transit -- workers cannot tell the difference on their
  # own. The audit runs after all workers finish and turns any silent loss into
  # a hard failure.
  #
  # Requires workers to run with a rerun key (`--key-rerun`), since the rerun
  # keys are the durable record of what each worker stole.
  class Auditor
    attr_reader :queue, :key, :key_rerun_prefix, :shards, :output

    def initialize(key:, shards:, key_rerun_prefix: nil, queue: nil, output: $stdout)
      @key = key
      @shards = shards
      @key_rerun_prefix = key_rerun_prefix || "#{key}-rerun-"
      @queue = queue || RedisQueue.new
      @output = output
    end

    # Returns 0 when every manifest item was stolen by some worker, 1 otherwise.
    def audit
      manifest = queue.read_all(manifest_key).uniq

      if manifest.empty?
        # No manifest: pushed by an older specbandit version, or the key
        # expired. Nothing to audit against -- succeed loudly so rollouts
        # with mixed versions don't break.
        output.puts "[specbandit] No manifest found at '#{manifest_key}'; skipping audit."
        return 0
      end

      executed = (1..shards).flat_map { |i| queue.read_all("#{key_rerun_prefix}#{i}") }.uniq
      missing = manifest - executed
      unexpected = executed - manifest

      output.puts "[specbandit] Audit for '#{key}': #{manifest.size} pushed, " \
                  "#{executed.size} recorded as stolen across #{shards} rerun key(s)."

      unless unexpected.empty?
        output.puts "[specbandit] Note: #{unexpected.size} item(s) in rerun keys but not in the manifest " \
                    '(retried push or manual enqueue?):'
        unexpected.each { |f| output.puts "    #{f}" }
      end

      if missing.empty?
        output.puts '[specbandit] Audit passed: every pushed item was picked up by a worker.'
        return 0
      end

      output.puts "[specbandit] AUDIT FAILED: #{missing.size} item(s) were pushed but never picked up by any worker:"
      missing.each { |f| output.puts "    #{f}" }
      output.puts '[specbandit] These items were silently lost -- their checks/tests DID NOT RUN.'
      1
    end

    private

    def manifest_key
      "#{key}:manifest"
    end
  end
end
