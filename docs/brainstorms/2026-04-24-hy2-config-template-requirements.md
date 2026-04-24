# Hy2 config.yml Template Refresh — Requirements

**Date:** 2026-04-24
**Repo:** `TheLastShadow-B/XrayR-release`
**Scope:** Lightweight brainstorm → direct edit
**Source skill:** `ce-brainstorm`
**Companion doc:** `docs/brainstorms/2026-04-24-install-script-refresh-requirements.md` (this extends R16 of that doc)

## Problem

The install-script refresh brainstorm landed R16 ("append a commented-out Hysteria 2 example Nodes entry to `config/config.yml`"), and the minimal skeleton is already at `config/config.yml:92-117`. But that skeleton only says two things: `NodeType: Hysteria2` and "CertMode can't be `none`". A first-time Hy2 operator reading *only* this file cannot answer:

1. Where do the actually-interesting Hy2 knobs live (`up_mbps`, `down_mbps`, `obfs`, `obfs_password`, `masquerade`, `host`, `allow_insecure`)? Answer: panel `custom_config`, per `XrayR/docs/brainstorms/2026-04-24-hysteria2-revised-requirements.md`. Nothing in the XrayR-release template says so.
2. Which `ControllerConfig` features are no-ops on Hy2 (`EnableFallback`, REALITY)?
3. What's the state of per-user rate limiting on Hy2?
4. Is `allow_insecure` safe to set? (No — upstream 2026-06-01 hard removal.)
5. Why is `DisableSniffing: true` a good default for QUIC?

These are footguns that surface at deployment time, not parse time. The template is where to defuse them.

## Goals

- A Hy2 operator who copies the uncommented block, fills in `ApiHost` / `ApiKey` / `CertDomain` / DNS creds, and reads the comments can get a working Hy2 node on first try.
- Cross-repo context (panel `custom_config` shape, rate-limit spike status) is surfaced inline — operators shouldn't need to read `TheLastShadow-B/XrayR`'s brainstorm doc.
- Deprecations and non-applicable features are called out explicitly, not silently omitted.

## Non-Goals

- Refreshing the active V2ray example block (adding `DisableSniffing` / `DisableIVCheck` / REALITY fields to it). Deferred — user scoped this pass to the Hy2 block only.
- Creating a separate `config/config.hy2.example.yml`. Discussed and rejected in favor of in-place expansion.
- Moving the `custom_config` JSON snippet to `README.md`. Discussed and rejected — keeping it inline makes the template self-contained.
- Ordering spike work for the Hy2 rate-limit bridge. The template surfaces the uncertainty; fixing it is a XrayR-repo concern.
- Editing `install.sh` packaging rules or `R22` (drift detection) coverage lists. The edited block stays inside `config/config.yml`, which `install.sh` already ships and `R22` already watches.

## Functional Requirements

### `config/config.yml` — Hy2 example block (replaces current lines 92-117)

- **H1** Block stays **commented out**. Operators opt in by uncommenting; no behavior change on existing installs.
- **H2** Opening comment must list a 3-point pre-deploy checklist:
  1. UDP port firewall/security-group rule (Hy2 is QUIC-over-UDP, not TCP).
  2. `CertConfig.CertMode ∈ {file, http, dns}`; `none` is rejected at `service/controller/controller.go:104`.
  3. `ApiHost` should be HTTPS because panel `custom_config` carries `obfs_password`.
- **H3** Block must include a copy-pasteable SSPanel-UIM `custom_config` JSON sample naming every Hy2-specific field (`offset_port_node`, `offset_port_user`, `host`, `allow_insecure`, `up_mbps`, `down_mbps`, `obfs`, `obfs_password`, `masquerade.{type,url,rewrite_host,insecure}`). Use `salamander` as the obfs example value. This snippet is the single source of truth for the field shape inside this repo — do not duplicate it elsewhere.
- **H4** Call out `allow_insecure` / `allowInsecure` 2026-06-01 upstream hard-removal. Phrase as a production warning, not a blocker.
- **H5** Explicit "not applicable on Hy2, intentionally omitted" list:
  - `EnableFallback` / `FallBackConfigs` (TCP/WS-only fallback).
  - `EnableREALITY` / `REALITYConfigs` (TLS-on-TCP disguise).
- **H6** Rate-limit honesty block:
  - Per-user bandwidth on Hy2 today flows through panel `custom_config.up_mbps` / `down_mbps` (Xray-core `BrutalUp` / `BrutalDown`).
  - XrayR-side `WrapLink` bridge coverage on Hy2 is spike-pending (`XrayR/docs/brainstorms/2026-04-24-hysteria2-revised-requirements.md` 议题 2).
  - `AutoSpeedLimitConfig` / `GlobalDeviceLimitConfig` are **shown** in the example (per user override of original "minimal" draft) with a comment noting "parsed and wired into the inbound limiter, but real-world effect on Hy2 traffic pending spike."
- **H7** Include `DisableSniffing: true` with reason (QUIC's inner encryption makes sniff targetless).
- **H8** Placeholder values that nudge operators away from copy-paste accidents:
  - `ApiKey: "CHANGE_ME"` (not `"123"`).
  - `CertDomain: "hy2.example.com"`.
  - `Email: you@example.com`.
  - `RedisPassword: YOUR_PASSWORD`.
- **H9** `CertConfig` comments must show `CertFile` / `KeyFile` as commented hints (for `CertMode=file` users), in addition to the `dns` / Provider / DNSEnv path.
- **H10** Language: Chinese comments (matching the existing Hy2 block's style and matching the audience of this fork's Chinese-language install scripts). Keep technical identifiers in English.

### Out of scope (explicitly)

- **N1** Do not alter the active V2ray example block (lines 16-65).
- **N2** Do not alter the second commented example block (lines 66-91).
- **N3** Do not touch `install.sh` — the existing R7 (deny-list preservation) and R22 (drift detection) already cover the case where an existing `/etc/XrayR/config.yml` doesn't have the new comments.

## Success Criteria

- **First-try Hy2 deploy**: uncommenting the block, substituting real `ApiHost` / `ApiKey` / `NodeID` / `CertDomain` / DNS creds, and setting panel `custom_config` per the inline sample produces a running Hy2 node without reading any external doc.
- **Upgrade drift visible**: on a box whose `/etc/XrayR/config.yml` predates this change, the next `install.sh` run produces `/etc/XrayR/config.yml.new` with the expanded Hy2 block (per `R22` in the install-script brainstorm). Existing live config is byte-identical.
- **No behavior change on existing installs**: block stays commented; YAML parser ignores it; no existing node loses capability.
- **Cross-repo claim honesty**: the template does not claim `AutoSpeedLimitConfig` "works on Hy2" — it correctly reflects the spike-pending status from the XrayR-side brainstorm.

## Open Questions

- None blocking. Two follow-ons tracked as deferred (N-items above).

## References

- `config/config.yml:92-117` (current Hy2 skeleton to replace)
- `docs/brainstorms/2026-04-24-install-script-refresh-requirements.md` (R16: this doc extends it)
- `XrayR/docs/brainstorms/2026-04-24-hysteria2-revised-requirements.md` (source of the `custom_config` field shape and rate-limit spike status)
- Backend Hy2 TLS guard: `XrayR/service/controller/controller.go:104-106`
- Backend limiter wiring: `XrayR/service/controller/controller.go:133`

---

## Review history

- **2026-04-24** — ce-brainstorm captured Approach A (patch Hy2 block only) from user.
- **2026-04-24** — User override: include `AutoSpeedLimitConfig` / `GlobalDeviceLimitConfig` in the example after all, with explicit spike-pending uncertainty note (H6). Original draft had dropped them to avoid overclaiming; user preferred "show with honest caveat" over "hide."
