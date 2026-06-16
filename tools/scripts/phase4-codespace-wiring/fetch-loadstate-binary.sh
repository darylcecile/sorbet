#!/bin/bash
# Phase 4 DRAFT — lands in github/github as .devcontainer/fetch-loadstate-binary.sh
#
# Fetches the Linux x86_64 fork `sorbet` binary (the one with --load-state /
# --store-state-lsp support) into vendor/sorbet-loadstate/sorbet.
#
# WHY a download and not GHCR: the user cannot get a GHCR/packages push token. But the
# binary is a normal GitHub Release asset on darylcecile/sorbet, which the built-in
# Codespaces GITHUB_TOKEN can read with NO extra scope. This mirrors the repo's own
# .devcontainer/install-gh-extensions.sh, which uses `gh release download` precisely
# because the prebuild bot token lacks the scope `gh extension install` needs.
#
# OPTION (a) FALLBACK — vendoring: if you'd rather not depend on a release at prebuild
# time, commit the binary to github/github at vendor/sorbet-loadstate/sorbet (like
# vendor/oras/oras) and DELETE this script. The build/load scripts already prefer an
# existing vendor/sorbet-loadstate/sorbet and only call this fetcher when it's absent.
#
# Never breaks on-create: all failures log and exit 0.
set +e

REPO=/workspaces/github
DEST_DIR=$REPO/vendor/sorbet-loadstate
DEST="$DEST_DIR/sorbet"

# darylcecile/sorbet publishes the load-state binary as a release asset. Pin RELEASE_TAG
# to the snapshot-compatible build; leave empty to track the latest release.
FORK_REPO="${FORK_REPO:-darylcecile/sorbet}"
RELEASE_TAG="${LOADSTATE_RELEASE_TAG:-}"
# Asset name pattern. The release publishes e.g. sorbet-linux-amd64 (gzip optional).
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

log() { echo "[load-state binary] $*"; }

export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
if [[ -z "$GH_TOKEN" ]]; then
  log "no GITHUB_TOKEN available; cannot download fork binary (will fall back to stock gem)"
  exit 0
fi
if ! command -v gh >/dev/null 2>&1; then
  log "gh CLI not found; cannot download fork binary (will fall back to stock gem)"
  exit 0
fi

if [[ -x "$DEST" ]]; then
  log "binary already present at $DEST; skipping"
  exit 0
fi

if [[ -z "$RELEASE_TAG" ]]; then
  RELEASE_TAG=$(gh api "repos/${FORK_REPO}/releases/latest" --jq '.tag_name' 2>/dev/null)
fi
if [[ -z "$RELEASE_TAG" ]]; then
  log "could not resolve a release tag on ${FORK_REPO}; skipping"
  exit 0
fi

mkdir -p "$DEST_DIR"
log "downloading ${FORK_REPO}@${RELEASE_TAG} (linux/${ARCH})"
# Try a plain binary asset first, then a .gz, to keep the release format flexible.
if gh release download "$RELEASE_TAG" --repo "$FORK_REPO" \
     --pattern "*linux*${ARCH}*" --output "$DEST" 2>/dev/null; then
  chmod +x "$DEST"
elif gh release download "$RELEASE_TAG" --repo "$FORK_REPO" \
     --pattern "*linux*${ARCH}*.gz" --output "$DEST.gz" 2>/dev/null; then
  gunzip -f "$DEST.gz" && chmod +x "$DEST"
else
  log "no matching linux/${ARCH} asset on ${FORK_REPO}@${RELEASE_TAG}; skipping"
  exit 0
fi

if [[ -x "$DEST" ]]; then
  log "fork binary ready at $DEST"
  "$DEST" --version 2>/dev/null | sed 's/^/[load-state binary] /'
else
  log "download did not produce an executable; skipping"
fi
exit 0
