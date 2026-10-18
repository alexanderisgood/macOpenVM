# 40. Measure and optimize the original raw display decoder

Status: experimental optimization. Generated-frame comparison and regressions (private development record omitted)
pass; native visible frame pacing and guest performance remain unqualified.

The fallback Windows display path uses original bounded RFB Raw decoding. Its
pixel loop currently materializes each received chunk as Data and then an array,
computes rectangle row/column for every pixel and checks coverage even after a
full canvas has initialized. These are candidate costs, not measured bottlenecks.

Capture an unchanged release baseline before altering behavior. Use original
generated BGRX fixtures for initial full-frame, steady full-frame and small dirty
updates at fixed 1280×720, 2560×1440 and 3840×2160 geometries. Decode through the
production parser in bounded fragments; time decode feeds and Data snapshot
creation separately. Validate complete updates, exact opaque pixels, initialized
coverage and previous snapshot preservation outside the timed interval. Retain
all samples and exact fixture/source/tool/binary provenance.

Only after the baseline may a small candidate borrow the bounded input bytes,
walk rows instead of dividing per pixel, and skip coverage checks after complete
initialization. Canvas, payload, rectangle, buffering and protocol limits must
remain unchanged. Fragmented nonzero-origin rows, overlaps, holes, resize/reset
and immutable snapshots require regression coverage. Any unsafe byte borrow must
stay inside its allocation lifetime and use already validated lengths.

Compare the same harness, release profile, geometries and correctness rules,
retaining all before/after trials. This is a host decoder component measurement;
it does not measure guest rendering, transport, AppKit drawing, frame pacing,
input latency, GPU acceleration, Retina mode application or virtualization parity.
No guest, network, account pixels or media are involved. Host load and cache are
uncontrolled unless separately qualified; no universal regression threshold or
speed claim follows from a few samples.

The subsequent receive-buffer experiment (private development record omitted)
keeps these limits and borrows the transport's allocation only for validated Raw
bodies without buffered prefixes. Any remaining byte is owned before return.
Fifty parser/socket tests and a generated AddressSanitizer fixture pass. Its
paired generated savings do not establish a clear live Windows FPS gain.
