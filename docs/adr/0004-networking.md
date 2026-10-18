# ADR 4: explicit offline and least-exposure NAT

Status: accepted policy; native Linux NAT has experimental guest evidence.

Offline omits network devices entirely. Explicit shared mode uses VZ NAT for Linux
or QEMU user networking for its selected guest; persist locally administered
unicast MAC identity. Document backend-provided DHCP/DNS behavior using guest
tests. No firewall modifications, packet capture, helper or incoming listener by
default. Port forwarding must default to loopback with conflict checks. Bridged
mode stays blocked until entitlement, host interfaces and distribution pass.

Reject silent LAN exposure or treating configuration validation as connectivity.
Acceptance: DHCP/DNS/outbound and host exposure tests, reconnect diagnostics,
no guest payload collection, explicit interface/permission errors.

Repeated native Linux trials (private development record omitted)
retain the configured MAC and observe DHCP, route, DNS and verified outbound
HTTPS. They do not qualify inbound exposure, reconnect, forwarding, throughput
or Windows networking. QEMU user networking remains a proposed path until it
is implemented and independently verified. [ADR 21](0021-stopped-networking-settings.md)
adds explicit next-start mode editing with configuration/disk identity preserved.
