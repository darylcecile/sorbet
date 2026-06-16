# Phase 4 — Codespaces prebuild-bake wiring (DRAFT, ready to apply)

These files land in the **github/github** repo (READ-ONLY from this fork, so they are
drafted here in `tmp/phase4/` ready to copy into a github/github PR). They wire the
Sorbet `--load-state` boot into Codespaces **without any registry or token** — the
snapshot is built in `onCreateCommand` and baked into the prebuild image.

## Why prebuild-bake instead of oras→GHCR (design change)

The earlier draft mirrored `.devcontainer/preindex-rubymine.sh`: a PREINDEX worker built
an index and `oras push`ed it to `ghcr.io/github/github/...`, and dev codespaces
`oras pull`ed it. That needs a **GHCR/packages push token**, which the user cannot get.

RubyMine needs that registry round-trip because its index build is a ~10-min warmup
worker. **Our snapshot build is ~40s** — cheap enough to just run in `onCreateCommand`,
whose filesystem output is **baked into the Codespaces prebuild image** (the same
mechanism the existing on-create relies on when it waits for background jobs "so its
filesystem output is included in the prebuild image"). So we drop oras, GHCR, the
registry, the token, and the separate PREINDEX worker entirely.

Bonus correctness/perf: the snapshot is pinned to the **prebuild commit**, so a dev
codespace created from the prebuild starts with a **near-empty git dirty set** — the
best-case load-state win out of the box.

## The files

1. **`.devcontainer/build-loadstate-snapshot.sh`** (NEW) — runs in on-create.
   - **Guard (already baked):** if `tmp/sorbet/loadstate/state.{sym,name,file,meta}`
     already exist (inherited from the prebuild image), skip — nothing to do.
   - **Ensure binary:** if the fork binary is missing, call `fetch-loadstate-binary.sh`.
   - **Build:** the fork `srb` with `--store-state <sym,name,file> --store-state-lsp
     --store-state-meta <meta> --snapshot-commit $(git rev-parse HEAD)`, writing under
     `tmp/sorbet/loadstate/` (alongside the existing `--cache-dir tmp/sorbet`).
   - **No-op on ANY failure:** not `set -e`; every failure path logs and `exit 0`, and a
     failed build cleans up its partial output. It can NEVER break codespace/prebuild
     creation (non-green tree, missing binary, git error, …).

2. **`.devcontainer/fetch-loadstate-binary.sh`** (NEW) — gets the Linux x86_64 fork
   binary into `vendor/sorbet-loadstate/sorbet`. See "The one remaining dependency".

3. **`.devcontainer/on-create-command.sh`** (PATCH, see `on-create-command.snippet.sh`)
   — replace the existing `# Run sorbet to seed the cache` / `.vscode/run-sorbet || true`
   with: build the snapshot first, then run-sorbet. No PREINDEX branch.

4. **`.vscode/run-sorbet`** (REPLACE, see `run-sorbet`) — when the snapshot + fork
   binary are present, `exec` the fork with `--load-state <3 paths> --load-state-meta
   <meta> --disable-watchman`; otherwise `exec bin/bundle exec srb typecheck` exactly as
   today. The extension already launches this with `--lsp`
   (`.vscode/settings.json` `sorbet.lspConfigs[].command`), so no extension change.

## The one remaining dependency — the Linux x86_64 fork binary

The snapshot must be built (and later loaded) by the fork `srb`, which must exist at
prebuild time. With no packages token, two ways to get it there:

- **(b) PRIMARY — download on-create from a GitHub Release** of `darylcecile/sorbet`
  using the built-in Codespaces `GITHUB_TOKEN`. This needs **no extra scope** and mirrors
  the repo's own `.devcontainer/install-gh-extensions.sh`, which uses `gh release
  download` precisely because the prebuild bot token lacks the scope `gh extension
  install` wants. `fetch-loadstate-binary.sh` implements this (resolve latest/pinned
  tag → `gh release download --repo darylcecile/sorbet --pattern "*linux*amd64*"` →
  `vendor/sorbet-loadstate/sorbet`). The download bakes into the prebuild image too, so
  dev codespaces inherit it. **Action item:** publish the Linux x86_64 binary as a
  release asset on `darylcecile/sorbet` (the fork build artifact is ready — see the
  Codespace runbook).

- **(a) FALLBACK — vendor the binary** in github/github at
  `vendor/sorbet-loadstate/sorbet` (like `vendor/oras/oras`) and delete
  `fetch-loadstate-binary.sh`. Both other scripts already prefer an existing
  `vendor/sorbet-loadstate/sorbet` and only fetch when it's absent, so this works with
  no other change. Heavier repo (a ~13MB binary in git) but zero runtime dependency.

This binary is the ONLY artifact that still needs "distribution", and it rides normal
repo/release auth — no GHCR, no packages token.

## `--disable-watchman`

Watchman's fresh-instance initial sync enumerates ALL files, defeating the read-elision
win. We drive boot from the git dirty set (working tree vs the snapshot's pinned commit,
measured 0.09–1.56s on github/github) and let didOpen/didChange cover live edits.

## Boot decision (already implemented + tested in the fork, Commits A+B)

`--load-state-meta` → `realmain` validates the pin ({sorbet_version,
cacheSensitiveOptions, git_sha} vs the running binary + this checkout) → `computeDirtySet`
diffs the working tree against the pinned commit:
  - usable (base present, delta ≤ cap) ⇒ `InitFromSnapshot`: adopt the resolved GS as the
    LSP base WITHOUT re-index/name/resolve, then replay ONLY the dirty set through the
    normal indexer→fast/slow path.
  - unusable (no/foreign base commit, shallow clone, delta over cap, git error) ⇒ clear
    load-state ⇒ normal full payload boot. **No regression, ever.**

## Status

- Substrate + seam + boot edit: **DONE, committed, tested** (Commits A `6cf94b405`,
  B `2cdddf911`; durable CLI regressions `df55809af`, `7ac6b7abb`). Cold full-index vs
  warm `--load-state` boot produce byte-identical diagnostics, including a MODIFIED
  file's UNCHANGED downstream dependents; an unchanged-but-corrupted file is correctly
  elided (never read).
- Linux x86_64 fork build: **GREEN + runtime-validated** (all load-state CLI tests pass
  on the Linux binary). Opt binary staged; ready to publish as the release asset for (b).
- Headline **LSP time-to-Idle proof**: pending a real github/github Codespace
  (Linux x86_64). Turnkey steps + measurement driver: see
  `tools/scripts/sorbet_loadstate_codespace_runbook.md` + `tools/scripts/sorbet_lsp_tti.py`.
- **No GHCR token required** by this design. The only external action item is publishing
  the fork binary as a release asset (or vendoring it).
