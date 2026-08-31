# TUN DNS Bootstrap Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the stable `e388f89` behavior while making proxy-node bootstrap DNS and macOS DNS cache handling reliable after TUN restarts.

**Architecture:** Resolve a proxy node hostname once through the host resolver before generating the sing-box outbound, then place the resulting IPv4 address in the runtime configuration. Preserve the original hostname when resolution fails. On successful TUN startup, flush macOS resolver caches without changing the DNS servers supplied by DHCP.

**Tech Stack:** zsh, sing-box 1.12, jq, macOS `dscacheutil` and `mDNSResponder`.

## Global Constraints

- Never call `networksetup -setdnsservers`.
- Do not modify commit `e388f89` or delete existing stashes.
- Resolve node hostnames again on every instance generation.
- Preserve existing behavior when the node server is already an IP or cannot be resolved.

---

### Task 1: Proxy bootstrap resolution

**Files:**
- Modify: `sing-run-template.sh`
- Test: `scripts/test_tun_config.zsh`

**Interfaces:**
- Consumes: `_sing_system_resolve_ipv4(hostname)`
- Produces: `_sing_template_generate_outbound(node_line)` with an IP-valued `server` when resolution succeeds.

- [ ] Add tests for hostname resolution success, literal IP passthrough, and resolution failure fallback.
- [ ] Run `zsh scripts/test_tun_config.zsh` and confirm the new assertion fails.
- [ ] Implement `_sing_system_resolve_ipv4` and use it while generating proxy outbounds.
- [ ] Run the regression test and `sing-box check`.

### Task 2: Cache-only macOS DNS refresh

**Files:**
- Modify: `sing-run-system.sh`
- Modify: `sing-run-instance.sh`
- Test: `scripts/test_tun_config.zsh`

**Interfaces:**
- Produces: `_sing_system_flush_dns_cache()`, which flushes caches but never changes configured DNS servers.

- [ ] Add a test that intercepts `dscacheutil`, `killall`, and `networksetup`, and asserts only cache-flush commands are invoked.
- [ ] Run the test and confirm it fails before implementation.
- [ ] Implement the cache flush and invoke it after successful TUN startup while sudo credentials are available.
- [ ] Re-run regression and syntax tests.

### Task 3: Runtime verification

**Files:**
- No production file changes.

- [ ] Generate a TUN configuration and confirm the proxy outbound server is an IPv4 address.
- [ ] Confirm Wi-Fi DNS remains DHCP-provided.
- [ ] Restart one TUN instance and verify Google resolves to fakeip and returns HTTP successfully.
- [ ] Confirm company split-DNS access still works.
