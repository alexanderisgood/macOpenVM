# Generated Metal surface experiment

This explicit Apple-silicon macOS component experiment uses generated quadrant
colours only. It opens no window or VM and saves no pixel or screen files. It is
not a guest FPS,120Hz, gameplay, input-latency or physical-presentation benchmark.

From the repository root:

```sh
python3 Benchmarks/metal_surface.py --build
python3 Benchmarks/metal_surface.py --run --artifact /absolute/path/printed/by/build
```

Without either action the script reports SKIP. Building freezes all component
sources, recipes, release binaries and sanitizer binary under a unique private
artifact directory. Running requires current exact input hashes, owned immutable
executables and the successful build record. SDK and compiler versions are
recorded. This is local unsigned provenance, not release attestation.

The release fixtures exercise native3456×2168 and3840×2160, BGRA/RGBA and both
unorm/sRGB, two surfaces and one in-flight frame. Every consumer pixel is checked
against independently generated expected quadrant colours, including forced
opaque alpha. Two warmups precede five retained samples per case.

SingleProcess measures GPU export into an IOSurface and a second GPU draw after
a local Mach-port import. TransportProbe uses a separately spawned consumer and
private inherited Mach capabilities. It restores the parent's registered ports,
clears the consumer's inherited channel slot before GPU initialization,
checks kernel audit UID and the actual owned peer's PID, and validates fixed
message shape, geometry, case, slot, sequence and epoch. It creates no named
service and uses no global surface ID. All actual children are waited/reaped.
This purpose-built process arrangement is not production VM/session admission.

Release metrics separate export-submit-to-completion, consumer-notice and
consumer-GPU-draw-to-completion. The validated ACK also includes the CPU pixel
oracle and one declared32ms consumer pause; it is not a pure transport metric.
Original source rendering and pixel validation are excluded from GPU timings.
No sample is discarded. Host cache, load, power and thermal state are uncontrolled.

Five sanitizer fault cases reject replayed acknowledgements, stale epochs,
consumer exit, a consumer exceeding the response deadline, and malformed surface
metadata. Expected consumer exits7 and24 belong to the respective injected cases;
the parent succeeds only when the expected failure is handled without forced
cleanup and the actual child is reaped. Fault cases report no performance samples.

The public JSON follows the project evidence schema and omits local build paths;
full commands, private outputs and recipes remain in the private artifact/session.
The pure admission tests run without GPU access:

```sh
python3 -m unittest discover -s Benchmarks -p test_metal_surface.py
```

An IOSurface Mach capability does not enforce a read-only consumer. Shader-read
usage declares a role. A future VM implementation must use dedicated host output
surfaces, bind peers to the reviewed runtime/session, preserve producer GPU
completion, handle resize/reconnect/cancellation, and retain the working fallback.

## Native Direct3D source ordering

`ProducerOrdering.m` and `DxmtSource.cpp` exercise the reviewed native DXMT
embedder library used by the current private GPU runtime. This separate explicit
test requires that reviewed source tree and exact library; it does not download
dependencies or accept arbitrary replacements. The header tree and library are
pinned, copied into an exclusive artifact and verified before running.

```sh
python3 Benchmarks/dxmt_surface.py --build \
  --dxmt-source /absolute/path/to/reviewed/dxmt-source \
  --dxmt-library /absolute/path/to/reviewed/libdxmt-native.dylib
python3 Benchmarks/dxmt_surface.py --run --artifact /absolute/path/printed/by/build
python3 -m unittest discover -s Benchmarks -p test_dxmt_surface.py
```

The adapter uses D3D11 hardware device creation, shared texture descriptors,
`ID3D11Fence` and the library's documented pollable native event. Both the event
wakeup byte and completed fence value must agree before export. Alternating
frames close the original event handle before waiting on its retained fd.
The importer wraps the actual shared backing as a separate Metal buffer/texture.
After GPU export completes, the fixture overwrites and verifies the source,
then draws and independently checks every pixel of the earlier IOSurface snapshot.
Native/4K and four source formats run in release and address/undefined-behaviour
sanitizer builds. Sanitizer timings are not performance metrics.

This is one process with explicitly exclusive source ownership. It does not
qualify Windows present-token error paths, real guest source ownership, kernel
driver behavior or physical presentation. The earlier separate-process transport
test remains a distinct component; combining their results does not establish
an end-to-end VM transport.
