# Config Drift Noise Reduction — Requirements

**Date:** 2026-04-24
**Repo:** `TheLastShadow-B/XrayR-release`
**Scope:** Lightweight brainstorm → direct edit
**Source skill:** `ce-brainstorm` (+ `ce-doc-review` round)
**Extends:** `docs/brainstorms/2026-04-24-install-script-refresh-requirements.md` R22

## Problem

User intent: `XrayR update` should feel like "the config also gets updated." The existing R22 byte-diff drift detection (`install.sh:202-235`) already writes `/etc/XrayR/<f>.new` and prints a banner whenever the shipped template differs from the live file — but it fires on pure comment / whitespace edits too. For a low-traffic personal fork this is fine in absolute terms, but the banner carries no signal when it fires purely for a typo fix or a rewrapped comment.

## Goal

`R22`'s banner fires only when there is a content-meaningful change to the shipped template; pure comment/whitespace refreshes stay silent. `.new` sidecar behavior preserved. No new operator-facing concepts, no new maintainer discipline.

## Chosen approach

Swap the comparison primitive in `check_config_drift()` from `cmp -s` (byte-compare) to `diff -q -B -I '^[[:space:]]*#'` (ignore blank lines + full-comment lines). Everything else stays untouched.

- **YAML (`config.yml`) / shell-style text (`rulelist`)**: `#` comments ignored; non-comment edits still trigger banner.
- **JSON (`dns.json`, `route.json`, `custom_outbound.json`, `custom_inbound.json`)**: JSON has no `#` comments, so the `-I` arm never matches; only blank-line noise is suppressed. Any meaningful JSON change still triggers. Safe.
- **Exit codes**: `diff -q` returns 0 for "files same (after filters)", 1 for "differ", 2 for trouble (missing file). Existing `[[ -f "$src" && -f "$dst" ]] || continue` guard already handles the missing-file case, so the `if ! diff ...` branch stays simple.

## Non-Goals

- Schema version header on line 1 of `config.yml`. Considered and rejected — see "Alternative considered" below.
- Machine-parseable banner for cron. Out of scope; can be layered later without conflicting with this change.
- Changing what `.new` means or how it's cleaned up. R22's existing `rm -f "${dst}.new"` when files match continues to apply — `diff -B -I` simply changes what "match" means.

## Functional Requirements

- **C1** In `install.sh`, replace the single `cmp -s "$src" "$dst"` call in `check_config_drift()` with `diff -q -B -I '^[[:space:]]*#' "$src" "$dst" >/dev/null 2>&1`. The surrounding loop, file list, `.new` cleanup, and banner path are unchanged.
- **C2** Inline comment at the call site explaining intent: "ignore blank lines and full-comment lines; JSON has no `#` so only blank-line noise is suppressed for those files."
- **C3** No changes to `config/config.yml`, `XrayR.sh`, `README.md`, or any of the JSON templates.

## Success Criteria

- **Cosmetic comment update**: maintainer fixes a typo in a `# ...` line of `config/config.yml` and ships a release. Operator runs `XrayR update`. Banner does NOT fire; no `.new` file written; any stale `.new` from a prior run is cleaned (existing R22 cleanup path).
- **Blank-line reflow**: shipped template gains or loses a blank line separating two sections. No banner, no `.new`.
- **Schema-meaningful change**: shipped template adds `DisableSniffing: true` to the active V2ray block (real YAML key). Banner fires; `.new` written.
- **JSON change**: `dns.json` gains a new server entry. Banner fires; `.new` written (JSON has no `#`, so `-I` has no effect for it).
- **No regression in file-list behavior**: all six files (`config.yml`, `dns.json`, `route.json`, `custom_outbound.json`, `custom_inbound.json`, `rulelist`) continue to be checked; drifted-files banner still names all changed files.
- **Idempotent re-run**: after `.new` is written once, running `install.sh` again with no further release change produces no new `.new` and does not duplicate the banner (same as current R22 behavior).

## Open Questions

- None. `diff -B -I` is the exact semantics the stated goal wants.

## Alternative considered — schema-version header on line 1

Originally this brainstorm proposed 12 requirements (S1-S12) adding a `# XrayR-config-schema: vN` header on line 1 of `config/config.yml`, three banner variants (schema-bump / legacy-no-header / silent), a maintainer PR convention (S12), and an optional CI enforcement (OQ1). See the git history for the earlier revision.

Rejected on ce-doc-review findings:

- **Premise fragility** (product-lens F1): the stated "operators trained to ignore the banner" pattern is imported from multi-tenant OSS contexts. This fork has ≈1 primary operator; R22 has barely fired for cosmetic reasons in practice.
- **Two of three failure paths baked in** (product-lens F2): (a) maintainer forgets to bump → silent miss; (b) operator forgets to copy the header line after merging → noise returns through the same door the feature was supposed to close. Only the "everything goes right" path actually delivers improved signal.
- **Load-bearing regex ships broken** (feasibility F1, adversarial F1): S11's template `# XrayR-config-schema: v1   # bump when...` cannot match S5's anchored regex. The fresh-install template would sabotage its own parser.
- **CRLF / BOM demotion** (adversarial F2, feasibility F4): Windows-edited configs silently fall into the "legacy" branch forever.
- **Ceremony for zero consumers** (scope-guardian F3, product-lens F6): S10 README prose, S11 inline explanatory comment, S12 PR-description convention, OQ1 CI enforcement — none have a consumer in a solo-dev fork with no `.github/`.
- **Path dependency / identity inflation** (product-lens F4): versioned, PR-policed config headers are the surface of a multi-operator tool. This repo is not that.
- **Cheaper alternative delivers 80% at 5% cost** (product-lens F5): `diff -B -I '^[[:space:]]*#'` suppresses exactly the noise the plan set out to eliminate, with zero ongoing discipline, zero new concepts, zero new failure modes. That alternative is what C1-C3 above codify.

What the chosen approach gives up vs. schema versioning:
- No `v3 → v4` transition text in the banner. For a 1-operator repo the transition string has no consumer; the operator already knows what they shipped.
- No explicit "this is a legacy config" signal for fresh installs of pre-feature releases. Moot given the schema-version feature never shipped, so there is no pre-feature state to migrate from.

Re-opening conditions: if user count grows past ~5, or if cosmetic-edit noise turns out NOT to be the actual noise source (e.g., operators editing their live config in ways that match the shipped template's comments), revisit with fresh data.

## References

- Parent brainstorm: `docs/brainstorms/2026-04-24-install-script-refresh-requirements.md` (R22 at lines 136-143)
- Live R22 implementation: `install.sh:202-235`
- Management script entry: `XrayR.sh:68-91` (`update()` → `install.sh`)

---

## Review history

- **2026-04-24** — ce-brainstorm captured user's Option A (schema-version header + smarter banner).
- **2026-04-24** — ce-doc-review round 1: 5 personas (coherence / feasibility / product-lens / scope-guardian / adversarial) returned findings. Product-lens F5 identified a ~10-line alternative (comment-aware `diff` in R22) delivering the stated goal with none of the downsides; cross-persona agreement on three high-confidence blocking issues with the original plan (S11/S5 contradiction, CRLF/BOM, ceremony-without-consumer). User chose to pivot. Original 12-requirement plan moved to "Alternative considered" above; this document now specifies only C1-C3.
