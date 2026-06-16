# Sorbet `--load-state` — github/github Codespace time-to-Idle runbook

Turnkey, copy-paste steps to run the headline proof for issue #1 inside an **x86_64
Linux** github/github Codespace:

1. build the fork natively,
2. build a `--load-state` snapshot of the repo,
3. wire it into github/github's LSP launch,
4. measure **time-to-Idle** (TTI) for stock vs fork-with-`--load-state` with one command.

Fork branch: `darylcecile/load-state-index`. Companion driver:
[`sorbet_lsp_tti.py`](./sorbet_lsp_tti.py) (next to this file).

> **Read-only guardrail.** The github/github checkout at `/workspaces/github` is the
> authoritative measurement target. Write only under `/workspaces/github/tmp/`
> (gitignored) and a separate fork clone in `$HOME`. Run `git -C /workspaces/github
> status --porcelain` after each step — it must stay empty.

---

## 0. Prereqs (already true in a github/github Codespace)
- x86_64 Linux, ~16 cores / 32 GB (the preindex worker spec).
- `git`, `python3` (stdlib only — the driver needs nothing else), a C/C++ toolchain.
  Sorbet's `./bazel` wrapper downloads its own Bazel; the build is otherwise hermetic
  (upstream CI builds on bare `ubuntu-latest`).

## 1. Build the fork natively — NO docker/QEMU (this host is already Linux x86_64)
```bash
git clone https://github.com/darylcecile/sorbet.git ~/sorbet-fork
cd ~/sorbet-fork
git checkout darylcecile/load-state-index

# Verified-on-Linux invocation. ~10 min cold on this host class; only ~1.3k actions
# (the typechecker, not the full LLVM backend).
./bazel build //main:sorbet -c opt

# Drop the binary where github/github's run-sorbet expects it (step 3):
sudo mkdir -p /workspaces/github/vendor/sorbet-loadstate
sudo cp bazel-bin/main/sorbet /workspaces/github/vendor/sorbet-loadstate/sorbet
SORBET=/workspaces/github/vendor/sorbet-loadstate/sorbet
"$SORBET" --version   # sanity
```
Config notes (pin one; don't leave ambiguous):
- **`-c opt`** is the verified, lightest representative binary and is what these steps
  assume. It omits LTO/`-march`, so it is *conservative* — it cannot flatter the fork
  relative to github/github's released gem.
- `--config=release-linux` produces the production-equivalent binary (adds LTO +
  static-libs + `-march=sandybridge`); it links slower and would only *improve* the
  fork's TTI. Use it if you want a production-identical number.

## 2. Build the `--load-state` snapshot of github/github (the PREINDEX step)
The snapshot must be built by the **same binary** that will load it, over a **green**
tree (a non-green tree crashes the store — see version-skew note). github/github is
CI-green at HEAD, so build at the checked-out commit. This block is self-contained
(Phase 4 ships the same logic as `.devcontainer/preindex-sorbet.sh`):
```bash
cd /workspaces/github
SNAP=/workspaces/github/tmp/sorbet-loadstate
mkdir -p "$SNAP" tmp/sorbet
SNAP_SHA=$(git rev-parse HEAD)
# @sorbet/config supplies --dir=. and the full --ignore set; we only append our flags.
#   --store-state-lsp : keep files Type::Normal + preserve FileHashes (NOT markAsPayload)
#                       — REQUIRED so the boot fast path can diff changed files.
#   --store-state-meta: write the {sorbet_version, cacheSensitiveOptions, git_sha} sidecar.
#   --snapshot-commit : pin the sidecar so computeDirtySet diffs the tree against it at boot.
"$SORBET" \
  --max-threads "$(nproc)" \
  --cache-dir tmp/sorbet \
  --store-state "$SNAP/state.sym,$SNAP/state.name,$SNAP/state.file" \
  --store-state-lsp \
  --store-state-meta "$SNAP/state.meta" \
  --snapshot-commit "$SNAP_SHA"
ls -lah "$SNAP"   # expect ~246MB across the three blobs + a tiny meta
```
**Version-skew (the one real gotcha).** The fork tracks upstream master; github/github
pins a specific Sorbet. If the store crashes with an errorful-snapshot error
(`types.cc`), THIS binary sees the tree as non-green. Mitigations, in order: (a) build
the snapshot at a known-green commit; (b) add the few skewed files to `--ignore` for the
snapshot build only; (c) rebase the fork onto github/github's pinned version. Phase 4
pins the fork version to the repo, so this disappears in production.

## 3. Wire the two A/B legs
Don't edit the read-only checkout; launch each leg directly.

- **STOCK (baseline)** — github/github's current Sorbet via its launcher:
  ```bash
  STOCK_CMD=".vscode/run-sorbet --lsp"
  ```
  To instead isolate the *load-state* effect from any binary-version difference, point
  stock at the fork binary with no snapshot:
  `STOCK_CMD="$SORBET --lsp --disable-watchman --cache-dir tmp/sorbet --dir ."`

- **FORK + `--load-state`** — directly (Phase 4's `run-sorbet` wraps exactly this and
  auto-falls back to the gem if the snapshot is absent):
  ```bash
  SNAP=/workspaces/github/tmp/sorbet-loadstate
  FORK_CMD="$SORBET --lsp --disable-watchman --cache-dir tmp/sorbet --dir . \
    --load-state $SNAP/state.sym,$SNAP/state.name,$SNAP/state.file \
    --load-state-meta $SNAP/state.meta"
  ```
  `--disable-watchman` is required: we drive the boot dirty set from git (working tree
  vs the pinned commit), not watchman's fresh-instance sync, which enumerates ALL files
  and defeats read-elision. In a clean Codespace at the prebuild commit the dirty set is
  ~0.

## 4. Measure time-to-Idle — one command
```bash
cd /workspaces/github
python3 ~/sorbet-fork/tools/scripts/sorbet_lsp_tti.py ab --runs 3 --cwd . \
  --stock-cmd "$STOCK_CMD" \
  --fork-cmd  "$FORK_CMD"
```
Output: per-run TTI for each leg (interleaved), the **median** per leg, the absolute
delta, and the **% win** (flags `>=50% TARGET MET`). Example shape:
```
  stock : 41.30s
  fork  : 3.10s  (--load-state)
  delta : 38.20s faster
  win   : 92.5%   (>=50% TARGET MET)
```

**What "idle" means here.** The driver times **spawn -> idle**, where idle is detected
from Sorbet's `sorbet/showOperation` notifications (Indexing / SlowPath / FastPath
`end`, settled). Spawn-relative (not initialize-relative) is deliberate and *honest*:
the snapshot is deserialized during process startup, *before* `initialize` is read,
whereas the cold leg's full index runs *after* `initialize`. Timing from `initialize`
would hide the fork's load cost. The driver also prints the `startup->initialize` and
`initialize->idle` splits per run for transparency.

**Cross-check the fork actually took the load-state path** (optional, recommended once):
append `--web-trace-file tmp/tti.json` to `$FORK_CMD`, run it once, then
```bash
grep -o 'read_global_state.load_state\|read_global_state.binary' tmp/tti.json | sort -u
```
`read_global_state.load_state` = booted from the snapshot; `read_global_state.binary` =
fell back to the cold payload (e.g. incompatible meta / missing base commit). The trace
flushes only on a clean shutdown, which the driver always does.

## 5. Expected shape (from the github/github-scale analysis)
Cold ≈ index 35.7s (89%) + name/resolve ~1.0s + infer. The `--load-state` leg elides the
35.7s index of unchanged files, leaving ~deserialize (~0.7s) + the dirty-set fast path,
so TTI should land in the low single-digit seconds. On weaker Codespace CPU /
network-backed storage the absolute *cold* number is larger, so the **% win holds or
improves**. The one-time ~246MB snapshot pull happens at Codespace create, not during
TTI.

## 6. Cleanup + verify read-only
```bash
git -C /workspaces/github status --porcelain   # MUST be empty
rm -rf /workspaces/github/tmp/sorbet-loadstate /workspaces/github/tmp/tti.json
```
(The snapshot + cache live under the gitignored `tmp/`, so they never dirty the repo;
the `rm` is just housekeeping.)

## 7. Phase 4 — prebuild wiring (after the number lands; needs GHCR creds)
Apply the drafts in `tmp/phase4/` to a github/github PR: `preindex-sorbet.sh` (PREINDEX
worker builds the snapshot + `oras push ghcr.io/github/github/sorbet-loadstate-index`),
the on-create `oras pull`, and the `.vscode/run-sorbet` replacement. Ship the ~246MB
snapshot only (drop the 465MB kvstore — unchanged files are never re-read at load time).

---

## Correctness already proven locally (so the Codespace step is purely the perf number)
- Deserialized snapshot GS ≡ fresh resolve — Phase 1a round-trip oracle (byte-identical).
- The boot seam routes the dirty set through the **production** fast path; a MODIFIED
  file's UNCHANGED downstream dependents are correctly re-typechecked —
  `test/cli/load-state-lsp-downstream` (warm == cold diagnostics, fast path, no slow path).
- Read-elision: an unchanged-but-corrupted file outside the dirty set is never read —
  `test/cli/load-state-lsp-incremental`.
- Unusable/incompatible pin ⇒ clean fallback to a full boot (no regression) — realmain
  boot-decision block + the trace cross-check in step 4.
