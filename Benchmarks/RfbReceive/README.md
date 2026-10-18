# Receive-buffer materialization experiment

This original generated-pixel component opens no VM, socket or window and saves
no image files. It compares an owned receive copy followed by the production
decoder with a synchronous borrow of the same bounded bytes. It measures no
socket syscall, guest rendering, AppKit drawing or physical presentation.

Build and freeze the release component explicitly:

```sh
python3 Benchmarks/build_rfb_receive.py --build
```

The returned private artifact contains the immutable `RfbReceiveBenchmark`,
source and compiler records, input hashes and build log. Its explicit `--run`
argument emits numeric JSON. Require its recorded binary/input hashes before
running. No benchmark runs during the build. The source also supports a separate
release build with `--sanitize address`; sanitizer timings are not performance
samples.

Native3456×2168 and3840×2160 steady full frames use fragments of
1,3,7,65536,65533,31 bytes. Two retained warmup pairs precede ten alternating
copy/borrow pairs. Feed timing includes the owned copy in the comparison mode;
Data snapshots are timed separately. Complete generated pixels, opaque alpha,
initial coverage and the earlier immutable snapshot are checked outside timing.
Both paths use the same current parser/binary; this is not an old-source binary
comparison. Host caches, load, power and thermal state are uncontrolled.

The production borrow accepts only an already validated Raw body with no
buffered prefix. Headers, incomplete pixels and following messages receive owned
copies before return. The existing64KiB feed/buffer, canvas, rectangle, pixel,
completion-boundary and four-read callback limits stay unchanged. Tests overwrite
the caller allocation immediately, before draining fragmented or following data.

Evidence (private development record omitted) retains all samples
and the subsequent live observations. Component savings do not establish a
Windows FPS improvement or120Hz support.
