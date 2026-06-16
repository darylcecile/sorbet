#!/bin/bash
set -e

# Phase 3 oracle for the snapshot<->commit pin (--store-state-meta / --load-state-meta).
#
# --store-state-meta writes a sidecar metadata file alongside a snapshot, pinning it to the Sorbet
# version, cache-sensitive options, and source git commit it was produced from. --load-state-meta
# validates that pin before loading, refusing snapshots produced by an incompatible build/option set
# (mirroring the cache validity key in main/cache/cache.cc) and recording the base commit Phase 3
# diffs the working tree against.
#
# All diagnostics go to stderr; stdout stays empty so the expected output (test.out) is empty.

prog='class Foo; def bar; 1; end; end'
sha='0123456789abcdef0123456789abcdef01234567'

# Store an LSP-flavored snapshot together with its sidecar pin, using an explicit commit so the test
# is deterministic and does not depend on the sandbox being a git checkout.
main/sorbet --silence-dev-message -e "$prog" \
  --store-state sym,name,file --store-state-lsp \
  --store-state-meta snap.meta --snapshot-commit "$sha"

if [ ! -f snap.meta ]; then
  echo "sidecar metadata file wasn't created" >&2
  exit 1
fi

# The sidecar must carry the format header and the exact commit we pinned.
head -n1 snap.meta | grep -qx 'sorbet-load-state-meta v1' || {
  echo "sidecar is missing the expected header; got:" >&2
  cat snap.meta >&2
  exit 1
}
grep -qx "git_sha=$sha" snap.meta || {
  echo "sidecar did not record the pinned commit; got:" >&2
  cat snap.meta >&2
  exit 1
}

# A matching pin loads successfully (this binary produced the snapshot, so version + options match).
main/sorbet --silence-dev-message -e "$prog" --load-state sym,name,file --load-state-meta snap.meta >&2

# A pin whose recorded version does not match must be refused (no loading a stale snapshot).
sed 's/^version=.*/version=SOME OTHER VERSION/' snap.meta > bad-version.meta
if main/sorbet --silence-dev-message -e "$prog" \
    --load-state sym,name,file --load-state-meta bad-version.meta >/dev/null 2>&1; then
  echo "loading a snapshot with a mismatched version pin should have failed" >&2
  exit 1
fi

# A pin whose recorded cache-sensitive options do not match must also be refused.
sed 's/^cache_sensitive_options=.*/cache_sensitive_options=255/' snap.meta > bad-options.meta
if main/sorbet --silence-dev-message -e "$prog" \
    --load-state sym,name,file --load-state-meta bad-options.meta >/dev/null 2>&1; then
  echo "loading a snapshot with mismatched option pin should have failed" >&2
  exit 1
fi

# A malformed sidecar must be rejected rather than trusted.
echo 'garbage not a sidecar' > junk.meta
if main/sorbet --silence-dev-message -e "$prog" \
    --load-state sym,name,file --load-state-meta junk.meta >/dev/null 2>&1; then
  echo "loading with a malformed sidecar should have failed" >&2
  exit 1
fi
