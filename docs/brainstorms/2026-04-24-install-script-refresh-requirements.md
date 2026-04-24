# Install Script Refresh — Requirements

**Date:** 2026-04-24
**Repo:** `TheLastShadow-B/XrayR-release`
**Scope:** Standard brainstorm → plan
**Source skill:** `ce-brainstorm`
**Chosen approach:** B — trim to **Debian 12 / 13** x86_64, add Hy2 awareness, harden download path, resync branding

> **Terminology.** "Hysteria 2" (with space) in prose; `Hysteria2` (no space) only when referring to the literal `NodeType` string that must match `service/controller/controller.go:104`.

## Problem

The current `install.sh` / `XrayR.sh` in `TheLastShadow-B/XrayR-release`:

1. Advertise CentOS / Ubuntu / Debian 8+ and x86_64 / arm64-v8a / s390x, but the only actual deployment targets are **Debian 12 (Bookworm) and Debian 13 (Trixie), x86_64**. The extra branches are dead code the maintainer no longer tests.
2. Do not reflect the Hysteria 2 support recently shipped in the fork's main repo (`TheLastShadow-B/XrayR`): no Hy2 example in `config/config.yml`, no surface of Hy2's new failure modes (requires TLS with `CertMode ∈ {file, http, dns}`, binds UDP).
3. Have latent robustness issues:
   - Downloaded zip is not integrity-verified.
   - `install.sh` `rm -f`'s itself on success, breaking retries.
   - GitHub API rate-limit / outage has no fallback; script just exits.
   - Upgrade path wipes `/usr/local/XrayR/` but relies on copy-only-if-missing logic for `/etc/XrayR/*`, which works for first-install but is fragile — e.g., `/etc/XrayR/cert/` (CertMode=file key material) is not explicitly protected.
   - BBR menu item pipes an external third-party Chinese script (`chiakge/Linux-NetSpeed`) straight into bash — supply-chain risk, Debian 13 kernel already ships BBR.
4. Brand/citation drift: `XrayR.sh` hardcodes `version="v1.0.0"`; wiki/readme links mostly point to the fork, but one or two still reference upstream patterns.

## Goals

- Make install/management scripts accurately describe what they actually support: **Debian 12 (Bookworm) or 13 (Trixie), x86_64 only**.
- Make Hysteria 2 node operators succeed on first try: config template + explicit pre-flight warnings that name the two Hy2-specific failure modes (self-signed TLS, UDP blocked).
- Raise robustness of the download path: integrity verification, retries, GitHub API fallback, idempotent re-run.
- Remove the external BBR dependency in favor of inline `sysctl` configuration.
- Close brand/citation drift; bump `XrayR.sh` version.

## Non-Goals

- Supporting OSes other than Debian 12 or 13. Debian 11, Ubuntu, CentOS, AlmaLinux, Rocky users keep using an earlier tag of this repo.
- Supporting non-x86_64 architectures (arm64, armv7, s390x, riscv64).
- Systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `AmbientCapabilities`) — tracked as deferred.
- `XrayR doctor` self-check subcommand — tracked as deferred.
- Weekly geoip / geosite refresh timer — tracked as deferred.
- logrotate configuration for `AccessPath` / `ErrorPath` — tracked as deferred.
- Systemd unit file rewrite (`XrayR.service`); stays as-is unless a concrete bug is found.

## Target User

Node operators deploying XrayR on a freshly provisioned Debian 12 or 13 x86_64 VPS, running V2ray / Trojan / Shadowsocks / Hysteria 2 backends behind SSpanel or compatible panels.

## User Stories

1. **Fresh install.** On a clean Debian 12 or 13 x86_64 VPS, `bash <(curl -Ls …/install.sh)` completes in under a minute, leaves `XrayR.service` enabled and started, and writes a default config.
2. **In-place upgrade.** Re-running the installer on an already-working box preserves `/etc/XrayR/config.yml`, the other JSON configs, and the `/etc/XrayR/cert/` directory. It swaps the binary + geo data and restarts the service.
3. **Hy2 pre-flight.** On a box whose `config.yml` has `NodeType: Hysteria2` (uncommented), the installer prints a yellow banner naming the two Hy2 failure modes (TLS required, UDP port must be reachable) before exit.
4. **Wrong-OS refusal.** On Ubuntu 22, CentOS Stream, or Debian 11 (and earlier), the installer exits cleanly with a message pointing to the legacy releases page, rather than proceeding into an untested branch.
5. **Flaky network.** When the release download fails partway, the script retries automatically; if the run is killed mid-way, the user can re-run the exact same command without manual cleanup.
6. **BBR enablement.** The BBR menu item in `XrayR.sh` writes the sysctl config itself and verifies `tcp_congestion_control=bbr` — no third-party script is executed.
7. **Version pinning.** `bash install.sh v0.9.5` installs that specific tag, integrity-verifies (when the release ships a `.dgst` sidecar), and upgrades in place. **Caveat:** downgrading across a config-schema-changing release may leave `/etc/XrayR/config.yml` unusable by the older binary; operator is responsible for rolling back config separately.

## Build / Release facts (grounding for R4–R7)

Confirmed from `TheLastShadow-B/XrayR/.github/workflows/release.yml` and `.github/build/friendly-filenames.json`:

- The release pipeline is a **hand-rolled GitHub Actions matrix** (not GoReleaser).
- For the amd64 build, friendly name is `linux-64`; the asset is `XrayR-linux-64.zip`.
- Each asset ships alongside a **`.dgst` sidecar** (e.g., `XrayR-linux-64.zip.dgst`) containing four lines: one each for md5/sha1/sha256/sha512, format `SHA256 <filename>= <hex>` (parens pre-stripped by the workflow's `sed`).
- The sidecar is always produced by the current pipeline — there is no transitional gap.
- The unchanged `XrayR.service` has `ExecStart=/usr/local/XrayR/XrayR --config /etc/XrayR/config.yml`, so the **binary lives at `/usr/local/XrayR/XrayR`**. `/usr/bin/XrayR` is only the management script (wrapper).

## Functional Requirements

### `install.sh`

- **R1** Accept only Debian 12 or 13. Detection: `ID=debian` in `/etc/os-release` (strict — reject `ID_LIKE=debian` derivatives such as Ubuntu/Kali/Devuan to keep the tested surface small) AND `VERSION_ID` equals `12`, `12.x`, `13`, or `13.x`. On failure, print a bilingual message pointing to `https://github.com/TheLastShadow-B/XrayR-release/releases` (operator picks a legacy tag themselves — named-tag resolution is OQ3) and exit non-zero immediately (no countdown).
- **R2** Reject non-x86_64. Detection: `uname -m` returns `x86_64` (or `amd64`). Map to release-asset slug `ARCH_SLUG=linux-64`; asset URL is `…/releases/download/${TAG}/XrayR-${ARCH_SLUG}.zip`.
- **R3** Run under `set -euo pipefail`; fail-fast on any error. Single `die()` helper. Add an `ERR` trap that removes the staging directory so a killed run leaves no partial state.
- **R4** Download with `curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 10`. If `curl` is missing, `apt-get install -y curl ca-certificates` before download; do **not** fall back to `wget` (dual-codepath bug surface not worth the complexity).
- **R5** Integrity-verify the downloaded `XrayR-linux-64.zip` against the release's `.dgst` sidecar:
  - Fetch `${DOWNLOAD_URL}.dgst`.
  - Extract sha256 line: `EXPECTED=$(awk '$1=="SHA256"{print $NF}' "$DGST")`.
  - Compute `ACTUAL=$(sha256sum XrayR-linux-64.zip | awk '{print $1}')`.
  - **`[ "$EXPECTED" = "$ACTUAL" ]` or `die` — fail-closed.** (Decided: sidecar is always emitted by the current release pipeline; there is no transitional warn-and-continue path. See ROUTED DECISION block below if this is overridden.)
- **R6** When `/releases/latest` GitHub API returns non-200 **or** returns 200 with a missing/empty `tag_name` field **or** returns a tag that does not match `^v[0-9]+\.[0-9]+\.[0-9]+`:
  - Fall back to probing `https://github.com/TheLastShadow-B/XrayR/releases/latest` with **`curl -sI --max-time 10`** (HEAD, no `-L`) and parse the `Location:` header.
  - Extract tag: `curl -sI ... | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | sed -n 's|^https://github\.com/TheLastShadow-B/XrayR/releases/tag/\(v[0-9][^[:space:]]*\)$|\1|p'` — the anchored path prevents accepting `/login`, `/404`, or a renamed-repo redirect.
  - If the fallback also yields no valid semver tag, `die` — never proceed with an unresolved version.
- **R7** Upgrade path must preserve `/etc/XrayR/` using a **deny-list** rule rather than an allow-list:
  - Preserved verbatim if already present: **everything under `/etc/XrayR/`** (files + subdirectories, including `cert/`, `config.yml`, `dns.json`, `route.json`, `custom_outbound.json`, `custom_inbound.json`, `rulelist`, plus any operator-added paths).
  - Always overwritten: `geoip.dat`, `geosite.dat` (extracted into `/etc/XrayR/` from the release zip).
  - `/usr/local/XrayR/` handling: snapshot nothing (no operator state lives there), wipe the directory, re-extract the zip. This matches pre-refresh behavior and prevents stale-binary drift when a future release removes a file.
  - `/etc/systemd/system/XrayR.service`: overwritten only on first install; on upgrade, preserved unless the installer has bumped its own service-file version (tracked via a comment header in `XrayR.service`). R21 freezes the current file contents.
- **R8** Must NOT self-delete (remove the `rm -f install.sh` line).
- **R9** Install the **management script** at `/usr/bin/XrayR` (the binary itself stays at `/usr/local/XrayR/XrayR` per the unchanged systemd unit). Symlink lowercase `/usr/bin/xrayr → /usr/bin/XrayR`.
- **R10** Post-install Hy2 pre-flight. Detection regex (extended regex):
  ```
  grep -Eq '^[[:space:]]*NodeType:[[:space:]]*["'\'']?Hysteria2["'\'']?[[:space:]]*(#.*)?$' /etc/XrayR/config.yml
  ```
  This requires start-of-line whitespace only (no `#`), tolerates quoting (`"Hysteria2"`, `'Hysteria2'`), and tolerates a trailing inline comment. If the regex matches, print a yellow banner:
  > ⚠️ Hysteria 2 节点检测到。请确认：
  > 1. `CertConfig.CertMode` 必须是 `file` / `http` / `dns`（`none` 会启动失败）。
  > 2. 对应监听端口（UDP）必须在防火墙与安全组放行。

  This banner is a **secondary defense**. Primary enforcement is at the controller (`service/controller/controller.go:104-106` — `Hysteria2 requires TLS: set ControllerConfig.CertConfig.CertMode to file, http, or dns`). The installer banner is advisory because the controller will refuse to start a misconfigured Hy2 node anyway.
- **R11** If `/etc/systemd/system/` is missing or not a real directory, fail with a clear message rather than creating it and writing an orphaned unit.

### `XrayR.sh` (management script)

- **R12** Bump `version` to `v1.1.0`; update all self-references to `TheLastShadow-B`.
- **R13** Replace the BBR menu action:
  - Pre-check `[ -d /etc/sysctl.d ] && [ ! -L /etc/sysctl.d ]` (guard against a symlink attack).
  - Write `net.core.default_qdisc=fq` and `net.ipv4.tcp_congestion_control=bbr` to `/etc/sysctl.d/99-bbr.conf` (overwrite).
  - Run `sysctl --system` (reloads all drop-ins).
  - Verify: `[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ] && [ "$(sysctl -n net.core.default_qdisc)" = "fq" ]` — exact match, not substring.
  - On `EPERM` (restricted VPS: OpenVZ / unprivileged LXC), print a specific message: `"⚠️ 当前容器/虚拟化方案禁止修改 sysctl (EPERM)。BBR 需在宿主机启用。"` and exit non-zero from the BBR menu action without killing the parent shell.
- **R14** Simplify the OS-detection preamble in parallel with R1 (Debian 12 or 13 only).
- **R15** All existing subcommands (`start`, `stop`, `restart`, `status`, `enable`, `disable`, `log`, `update`, `config`, `install`, `uninstall`, `version`, `update_shell`) retain current behavior. No new commands added in this pass.

### `config/config.yml` template (build-time edit)

- **R16** Append a commented-out Hysteria 2 example `Nodes` entry to `config/config.yml` in this release repo (which is packaged into the release zip and copied to `/etc/XrayR/config.yml` **only on first install**, per R7). The installer never edits an existing `/etc/XrayR/config.yml` in-place. Upgrade users who want to see the new example should read the shipped copy under `/usr/local/XrayR/config.yml` (the staging copy that gets left in the binary dir).

  The example must show:
  - `NodeType: Hysteria2`
  - `CertConfig.CertMode: file | http | dns` with inline note that `none` is rejected by the controller.
  - Comment that the `ListenIP` / node port applies to **UDP**.

### `config/` other files

- **R17** `geoip.dat` / `geosite.dat` refreshed to current upstream. These are always overwritten (per R7).
- **R18** No required changes to `dns.json`, `route.json`, `custom_outbound.json`, `custom_inbound.json`, `rulelist` unless a concrete bug is found.

### Documentation & branding

- **R19** `README.md` commands updated to reference the one-liner from `TheLastShadow-B/XrayR-release/master/install.sh`; any lingering upstream `XrayR-project` URLs removed.
- **R20** `docker-compose.yml` image reference confirmed or updated (see OQ2).
- **R21** `XrayR.service` unchanged (see Non-Goals).

### Config drift detection

- **R22** After install/upgrade, for each of `config.yml` / `dns.json` / `route.json` / `custom_outbound.json` / `custom_inbound.json` / `rulelist`:
  - If both `/etc/XrayR/<f>` and `/usr/local/XrayR/<f>` exist and differ (byte-level `cmp -s`), write the shipped template to `/etc/XrayR/<f>.new`.
  - If they are identical, remove any stale `<f>.new` left from a prior upgrade.
  - At end of install, print a yellow banner naming the `.new` paths and suggesting `diff /etc/XrayR/<f>{,.new}`.
  - The installer must never edit existing `/etc/XrayR/<f>` files in-place (per R7).

  Rationale: a user who installed when the template had no Hy2 example will, after an upgrade that adds the example, otherwise never see the new fields. Generalizes to any future template change (XTLS, TUIC, etc.) without requiring per-field checks.

## Success Criteria

- **Template drift**: on a box whose `/etc/XrayR/config.yml` predates the Hy2 example, upgrading produces `/etc/XrayR/config.yml.new` with the new template contents, original `config.yml` is byte-identical to before, and the installer prints a banner naming the `.new` path. If the box's existing `config.yml` already matches the shipped template, no `.new` file is created and any stale `.new` is removed.
- **Fresh install**: on a clean Debian 12 or 13 x86_64 VPS, one-liner finishes in < 60 s on 100 Mbps, `systemctl is-active XrayR` returns `active`.
- **Re-run with config**: running the installer a second time leaves `/etc/XrayR/config.yml` and `/etc/XrayR/cert/` byte-identical to before, and the service is running after completion.
- **Hy2 banner (upgrade path)**: a box whose `/etc/XrayR/config.yml` contains an uncommented `NodeType: Hysteria2` line receives the two-point TLS/UDP banner at the end of installer output.
- **Hy2 banner (commented template)**: a box whose `/etc/XrayR/config.yml` contains only the commented-out R16 example (leading `#`) does **not** receive the banner.
- **Wrong-OS**: on Ubuntu 22 / CentOS Stream / Debian 11 (and derivatives like Kali), installer exits non-zero within ~2 s (no countdown), message names the legacy-releases URL; no files written outside `/tmp`.
- **Version-pin with sidecar**: `bash install.sh v0.9.5` (or any tag with a `.dgst`) installs that binary, sha256-verifies, upgrades in place.
- **Retry**: killing the process mid-download and re-running succeeds without manual cleanup (ERR trap cleaned `/tmp` staging; no partial files in `/usr/local/XrayR/`).
- **BBR (root VPS)**: `sysctl -n net.ipv4.tcp_congestion_control` returns exactly `bbr`; no `curl | sh` was executed.
- **BBR (OpenVZ/LXC)**: specific EPERM message printed; installer does not falsely claim success.

## Open Questions

- **OQ1** *(resolved in doc review — was: "does goreleaser emit `.sha256`?")*. Confirmed: the pipeline is **not** GoReleaser, it is a hand-rolled matrix, and it emits `XrayR-linux-64.zip.dgst` (a combined md5/sha1/sha256/sha512 file). R5 now specifies parsing the SHA256 line from the `.dgst` sidecar and fail-closed verification.
- **OQ2** What is the intended `docker-compose.yml` image reference for this fork — a Docker image published under `TheLastShadow-B/*` (the main repo has a `docker.yml` workflow), or stay on the upstream image? *(Blocks R20.)*
- **OQ3** The "use an older release tag" pointer in R1 — should the message name a specific legacy tag known to work on CentOS/Ubuntu/older Debian, or just link to the releases page and let the operator pick? Named tag requires a one-time validation pass on Ubuntu 22; generic link requires nothing. *(Affects R1 message text, not behavior.)*

## Deferred (explicitly out of scope this pass)

- Systemd hardening (`NoNewPrivileges=true`, `ProtectSystem=strict`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, UDP buffer tuning for Hy2 throughput: `net.core.rmem_max` / `wmem_max`)
- `XrayR doctor` subcommand (one-shot self-check covering cert path, UDP bind, BBR, config syntax, Hy2 required fields)
- Weekly `geoip.dat` / `geosite.dat` refresh via systemd timer
- logrotate integration for access/error logs
- GPG-signed releases + embedded public-key fingerprint (upgrade path from SHA256 when integrity posture needs to survive GitHub-account compromise)
- Bringing `XrayR.sh` (management script) download into a verified release artifact — **see ROUTED DECISION below.**

## References

- Install script: `install.sh`
- Management script: `XrayR.sh`
- Systemd unit: `XrayR.service`
- Config templates: `config/config.yml`, `config/dns.json`, `config/route.json`, `config/custom_outbound.json`, `config/custom_inbound.json`, `config/rulelist`, `config/geoip.dat`, `config/geosite.dat`
- Release pipeline (main repo): `.github/workflows/release.yml`
- Friendly-name mapping (main repo): `.github/build/friendly-filenames.json`
- Hy2 NodeType check (main repo): `service/controller/inboundbuilder.go:99`
- Hy2 TLS-required guard (main repo): `service/controller/controller.go:104-106`
- Hy2 brainstorm (main repo): `docs/brainstorms/2026-04-24-hysteria2-revised-requirements.md`

---

## Review history

- **2026-04-24** — ce-brainstorm captured Approach B from user.
- **2026-04-24** — ce-doc-review round 1: 5 reviewers returned findings (coherence / feasibility / product-lens / security-lens / adversarial). Scope-guardian reviewed the wrong document (Hy2 plan) and was discarded. Safe-auto fixes applied: R5 rewritten around `.dgst` (FEAS-001/002); R6 exact curl-sI form + semver validation + anchored Location regex (FEAS-003, adv-5, FEAS-011, AMBIG-002); R7 switched to deny-list preservation including `cert/` (FEAS-005, adv-1, adv-2); R10 regex spec + advisory-vs-controller-enforcement note (FEAS-004, adv-7); R13 exact-match verify + symlink guard + EPERM handling (FEAS-008, adv-8, SEC-006); R4 dropped wget fallback (FEAS-009); R2 arch detection spec (FEAS-010, DEPEN-002); R16 clarified build-time vs runtime edit (FEAS-007); R3 ERR trap for atomic cleanup (CONSTRAINT-001); R9 clarified binary vs management-script paths (FEAS-006 false-positive resolved); R1 immediate exit, no countdown (P2 mitigated); terminology normalized (TERM-001). User stories 2/7 updated to reflect cert/ preservation and downgrade caveat (adv-3).
- **2026-04-24** — User override: target expanded from Debian 13 only to **Debian 12 OR 13**, x86_64 only. R1, R14, Non-Goals, User Stories, Success Criteria updated. All Debian-12 code paths are identical to Debian-13 paths (apt, systemd, bbr, sysctl drop-ins) — expansion is additive, no R-level redesign.
- **2026-04-24** — Added **R22** (config drift detection). Triggered by user question "有没有检测本地 config 文件和云端 config 文件版本不一致". Chosen approach: `.new` sidecar file + post-install banner (simplest, generalizes to any future template change, keeps R7's "existing config is sacred" invariant). Live-fire SHA bug (`SHA2-256=` vs `SHA256=`) also fixed in install.sh: R5 extraction regex changed to `/^(SHA2-256|SHA256)=/`.
- **2026-04-24** — Residual-findings routing (defaults applied, user can override):
  - **SEC-001 (R5 fail-closed)**: kept fail-closed. Rationale: `.dgst` is always emitted by the current release pipeline, there is no transitional gap that would justify warn-and-continue. The factual premise of the original warn-and-continue clause (absent sidecar) does not hold.
  - **SEC-002 (XrayR.sh in release zip)**: left in Deferred list. Rationale: bringing the management script under integrity verification requires a build-pipeline change in the main repo, out of scope for this release-repo-only refresh.
  - **P1 (Ubuntu/arm64 drop)**: not overturned. User confirmed Debian-only target and then expanded only to Debian 12 — a deliberate, narrow scope call, not a premise gap.
  - **P6 (21-req scope split)**: not adopted. Scope is bounded by design; phasing within this refresh is a `/ce-plan` concern if it emerges there.
  - **SEC-005 (R10 blocking vs advisory)**: kept advisory. Primary enforcement is the controller (`controller.go:104-106`); installer banner is secondary defense. Already noted in R10.
  - **OQ2 / OQ3**: left open, tagged as blocking R20 / affecting R1 message text only. Deferred to `/ce-plan`.
