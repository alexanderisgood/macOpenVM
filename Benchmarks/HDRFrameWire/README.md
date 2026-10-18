# HDR frame wire foundation checks

This is a portable implementation prerequisite. It does **not** enable usable
HDR: no endpoint negotiation, socket/FD transport, QEMU producer, Swift client,
EDR presentation, driver capability, EDID, or VM integration is implemented.
The existing 80-byte SDR protocol remains unchanged.

Run from the repository root with Python 3 and Clang:

```sh
python3 -m unittest discover -s Benchmarks/HDRFrameWire -p 'test_contract.py' -v
```

The runner compiles the actual `Backends/SharedFrameWire/SharedHDRFrameWire.c`
and the generated C fixture in a temporary directory. It performs strict C11
ASan/UBSan and optimized checks, owns and reaps each child, and imposes a
30-second process-group deadline per operation. `CC` may specify a Clang
executable path. There are no private build paths or required external Python
packages. LeakSanitizer is disabled because Apple's runtime does not support it;
the module allocates no memory.

Eight test groups cover an independent golden wire, malformed/truncated
packets, exact ACK identity, FP16 bit retention, 64 MiB/alignment bounds, resource
rotation, stale generations, meaning transitions, failed/partial writes,
reentrant writer guards, and 20,000 randomized two-slot ownership operations.
These are correctness checks, not FPS or physical HDR benchmarks.

The new wire uses its own `MVH2` magic and version 2 with 128-byte packets. It
accepts only explicit RGBA16FloatLE, linear Rec.709/D65 absolute scRGB with
1.0 = 80 cd/m² and an optical scale field of 80000 millinits. It never infers color
from a texture format, changes brightness, converts channels, or clamps pixel
values. Negative, above-one and other FP16 payload bits are copied unchanged.
Rendering must separately handle any invalid pixel values appropriately.

Resource incarnation, color generation and scanout selection generation are
nonzero 64-bit facts. Resource IDs are nonzero 32-bit virtio IDs; source/target/
scanout IDs can be zero. Individual frame identities are immutable. Buffer
rotation advances scanout generation without reallocating a compatible pool.
Only successfully completed snapshots advance content generation.

The producer state requires two fresh, dedicated, disjoint host mappings and a
serialized caller. A synchronous writer fills the unpublished slot at a
separately established producer fence. A published slot remains frozen until
the exact canonical ACK after the consumer's real GPU copy completes. Latest
unpublished snapshots may be replaced. Partial writes invalidate the latest
stamp. Genuine current/new incompatible color/layout/target facts retire the
pool and clear pending publication; older color/selection observations are
ignored as stale. Retired mappings are abandoned and never repurposed.

Production integration must still establish negotiated compatibility, admitted
read-only shared-memory FDs and deadlines, actual resource/mapping custody and
producer fences, authoritative Windows source color and target transforms,
same-size color transitions and damage accumulation, typed Swift/GPU-completion
ACK behavior, absolute 80-nit EDR presentation and fallback, live Windows/physical
HDR qualification, and paired workload performance. The C module's numeric
generations and callback success do not prove those external obligations.
