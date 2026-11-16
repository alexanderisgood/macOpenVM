# macOS QEMU storage cache fixture

Use an existing `qemu-io` installation and an existing scratch directory on the
filesystem being measured:

```sh
python3 Benchmarks/storage_cache.py \
  --qemu-io /opt/homebrew/bin/qemu-io \
  --scratch-parent .lab \
  --output .lab/storage-cache-results.json
```

The output must not exist. The harness creates its own exclusive temporary
directory and sparse 16 MiB file; it accepts no existing disk path. Each of three
blocks alternates `none` and `writeback` order. It issues 4,096 nonzero 4 KiB
writes in a fixed coprime permutation, flushes, then reopens and verifies every
byte. It separately issues FUA and verifies the affected block after reopening.
Generated disk files are removed after the owning process exits. A failed command,
unexpected output, verification error or 20-second timeout invalidates the run.

Wall time includes QEMU startup, command parsing, writes, final flush and process
exit. It excludes verification. Report every trial; these short, queue-depth-one
measurements do not establish sustained SSD throughput, Windows performance,
native-speed parity or power-loss durability. Readback is narrower than physical
power-loss verification. Record background load and retain the tool/harness hashes.

On one M5 Pro/macOS 27 host with an active installer and other applications,
QEMU 11.1.0 medians were 104.13 MiB/s (`none`) and 246.37 MiB/s (`writeback`).
All six reopened-byte/FUA checks passed. An independent incorrect-pattern control
was rejected by the harness. The exact pinned app runtime also accepted the
proposed drive options in a separate 16 MiB, CPU-less process: QMP reported
`writeback=true`, `direct=false`, `no-flush=false`, and its disposable disk
descriptor had no synchronous-write flag. The live user VM was not controlled.

The [retained measurements](../docs/evidence/storage-cache-2026-11-16.json) are a
component result. The earlier 2 MiB exploratory run also favored writeback, but
its timings were more heavily affected by process startup. Both runs remain in
the private bounded evidence directory. A later Windows benchmark is required.
