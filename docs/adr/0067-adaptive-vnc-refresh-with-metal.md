# 67. Let the VNC fallback idle while Metal owns display delivery

Status: source implementation complete; launch/resource and recovery tests pass.
Native performance and fallback qualification remain pending.

## Problem and decision

The accelerated launch plan enables a 200 ms VNC active-refresh hold. Any
changed pixels renew that hold, including when the connected client has paused
pixel requests because it is receiving shared frames through Metal. VNC then
repeatedly compares the guest surface even though it has no display consumer.

Omit the active-refresh hold when the reviewed shared-frame transport is
selected. Use the runtime's existing adaptive refresh policy. Keep the 200 ms
hold for accelerated plans using VNC pixels. Shared-frame delivery, keyboard,
pointer, firmware, storage and network configuration remain unchanged.

This reduces idle fallback scans; it does not eliminate all VNC work. Input
events still wake VNC, and a standard display fallback still uses its adaptive
policy. Shared-stream failure already reconnects the RFB client, which resets
the refresh interval and requests a full frame.

## Acceptance

- Compare complete launch arguments for shared and non-shared accelerated
  transports, including both firmware layouts. Only shared transport selection
  and its VNC hold may differ; TPM arguments must be identical.
- Preserve admission rejection for invalid shared transport resources.
- Run a repeatable changing-screen workload before and after on the same VM,
  mode and host viewport. Report process sampling and delivered-frame counters
  separately, with no native-speed or game-FPS claim.
- Verify startup and reconnect display delivery at the existing native mode.
  Forced shared-stream failure coverage remains separate from a normal
  successful reconnect.
