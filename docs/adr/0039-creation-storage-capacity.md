# 39. Show actual destination capacity before sparse VM creation

Status: experimental implementation. Focused source/native-file tests (private development record omitted)
pass; native capacity UI and full installation headroom remain unqualified.

The creation assistants explain sparse allocation, but do not currently show
physical space available at the chosen destination. The development host recently
had about 3.5 GiB available while the Linux/Windows defaults request 32/64 GiB of
virtual capacity. Successful sparse-file creation does not prove an OS install
will fit or reserve room for later guest writes.

Read the selected directory's actual filesystem availability through a retained
directory descriptor and public `fstatfs`. Use available blocks multiplied by
block size with overflow checks; do not count speculative purgeable storage or
automatically reclaim files. Reject unavailable/invalid observations and avoid
publishing a response for an old destination after a selection change.

Capacity reads follow ordinary ancestor aliases such as macOS `/var`, while
refusing a symlink at the selected directory leaf. Bracket the filesystem query
with held-descriptor/named-leaf identity checks. A capacity observation grants no
file-writing permission, so it must not impose unrelated VM directory ownership
rules or reject normal system temp paths. Existing mutation admission remains
independent; same-user path changes after the observation remain possible.

The Liquid Glass assistants will show host space and virtual disk capacity
separately, explain sparse growth and provide concrete guidance when virtual
capacity exceeds current available space. This comparison does not establish an
installer's requirements. Keep sparse allocation usable: do not require the
entire virtual disk to be physically allocated or silently reduce its size.

Creation keeps the existing 1 GiB minimum host-space floor, rechecked immediately
before creating the new directory. Unknown/loading/failed or below-floor UI
observations cannot authorize Create. The earlier observation is informational,
not a reservation; other writers can consume space after it. Disk-full during
creation retains the incomplete new folder for inspection.

Acceptance: actual no-write directory observation, checked arithmetic and
invalid-path refusal, stale/cancelled asynchronous reply tests, both creation
surfaces compiled with their current resource gates, an actual read-only CLI
report, and native observation on the measured host. Physical picker/refresh UI,
external/remote volumes, changing capacity and install-to-disk behavior remain
separate acceptance gates. No existing VM, media, credential or network changes
are part of this slice.

The privacy manifest declares DiskSpace reasons `85F4.1` for showing capacity and
`E174.1` for observable write-space checks. The information stays local and is not
added to upload/telemetry. These uses follow Apple's [required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
This declaration does not complete the app's full release privacy audit.
