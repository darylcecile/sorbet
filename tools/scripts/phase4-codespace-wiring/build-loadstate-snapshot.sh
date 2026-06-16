#!/bin/bash
# Phase 4 DRAFT — lands in github/github as .devcontainer/build-loadstate-snapshot.sh
#
# Builds a Sorbet --load-state snapshot (LSP-flavored: files stay Type::Normal,
# FileHashes preserved) of the whole repo at the current commit, so a Codespace can
# boot Sorbet from the resolved GlobalState instead of re-indexing the monorepo.
#
# Prebuild-bake distribution (NO registry, NO token):
#   onCreateCommand output is baked into the Codespaces prebuild image. Our snapshot
#   build is ~40s — cheap enough to just run in on-create, so it bakes straight into
#   the prebuild image. Dev codespaces created from the prebuild inherit the baked
#   snapshot AND start with a near-empty git dirty set (snapshot commit == prebuild
#   commit), i.e. the best-case load-state win. No oras, no GHCR, no PREINDEX worker.
#
# This script is wired into .devcontainer/on-create-command.sh as:
#     .devcontainer/build-loadstate-snapshot.sh || true
# inserted just BEFORE the existing `.vscode/run-sorbet || true` cache-seed.
#
# HARD REQUIREMENT: it must NEVER break codespace/prebuild creation. Every failure
# path (no binary, non-green tree, git error, anything) logs and exits 0. The load
# path (.vscode/run-sorbet) independently falls back to the stock gem when the
# snapshot is absent, so a no-op here simply means "no speedup", never a broken box.

# Deliberately NOT `set -e`: we want to swallow failures, not abort on-create.
set +e

REPO=/workspaces/github
SNAP_DIR=$REPO/tmp/sorbet/loadstate          # alongside the existing --cache-dir tmp/sorbet
CACHE_DIR=$REPO/tmp/sorbet
# Fork binary (Linux x86_64) with --store-state-lsp / --store-state-meta /
# --snapshot-commit support. Provided by fetch-loadstate-binary.sh (release download,
# primary) or vendored at vendor/sorbet-loadstate/sorbet (fallback). See README.
SORBET_BIN=${SORBET_BIN:-$REPO/vendor/sorbet-loadstate/sorbet}

log() { echo "[load-state snapshot] $*"; }

cd "$REPO" 2>/dev/null || { log "repo not found at $REPO; skipping"; exit 0; }

# --- guard 1: already baked from the prebuild? then there is nothing to do. ---------
if [[ -f "$SNAP_DIR/state.sym" && -f "$SNAP_DIR/state.name" && \
      -f "$SNAP_DIR/state.file" && -f "$SNAP_DIR/state.meta" ]]; then
  log "snapshot already present (baked from prebuild); skipping build"
  exit 0
fi

# --- guard 2: ensure the fork binary is available (download if missing) -------------
if [[ ! -x "$SORBET_BIN" ]]; then
  if [[ -x "$REPO/.devcontainer/fetch-loadstate-binary.sh" ]]; then
    log "fork binary missing; fetching"
    "$REPO/.devcontainer/fetch-loadstate-binary.sh" || true
  fi
fi
if [[ ! -x "$SORBET_BIN" ]]; then
  log "no fork binary available; skipping snapshot (run-sorbet will use the stock gem)"
  exit 0
fi

# --- build the snapshot at the current tree -----------------------------------------
mkdir -p "$SNAP_DIR" "$CACHE_DIR"
SNAP_SHA=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
if [[ -z "$SNAP_SHA" ]]; then
  log "could not resolve HEAD; skipping snapshot"
  exit 0
fi

log "building snapshot at $SNAP_SHA (binary: $SORBET_BIN)"
# @sorbet/config supplies --dir=. and the full --ignore set; we only append our flags.
#   --store-state      : the 3 resolved-GS blobs (sym/name/file).
#   --store-state-lsp  : keep files Type::Normal + preserve FileHashes (NOT markAsPayload)
#                        — REQUIRED so the boot fast path can diff changed files.
#   --store-state-meta : write the {sorbet_version, cacheSensitiveOptions, git_sha} sidecar.
#   --snapshot-commit  : pin the sidecar so computeDirtySet diffs the tree against it at boot.
"$SORBET_BIN" \
  --max-threads "$(nproc)" \
  --cache-dir "$CACHE_DIR" \
  --store-state "$SNAP_DIR/state.sym,$SNAP_DIR/state.name,$SNAP_DIR/state.file" \
  --store-state-lsp \
  --store-state-meta "$SNAP_DIR/state.meta" \
  --snapshot-commit "$SNAP_SHA"
rc=$?

if [[ $rc -ne 0 ]]; then
  # Most likely cause: the tree isn't green under THIS binary (version skew between the
  # fork = upstream master and github/github's pinned Sorbet); the snapshot store
  # ENFORCEs a green tree. Clean up the partial output so the load path falls back
  # cleanly to the stock gem, and never fail on-create.
  log "snapshot build failed (rc=$rc; tree may be non-green for this binary); cleaning up partial output"
  rm -f "$SNAP_DIR/state.sym" "$SNAP_DIR/state.name" "$SNAP_DIR/state.file" "$SNAP_DIR/state.meta"
  exit 0
fi

log "snapshot ready:"
ls -lah "$SNAP_DIR" 2>/dev/null | sed 's/^/[load-state snapshot] /'
exit 0
