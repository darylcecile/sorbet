#!/usr/bin/env bash
set -euo pipefail

# Phase 3 (issue #1) SOUNDNESS oracle for the LSP --load-state seam: a MODIFIED file with a downstream
# dependent in ANOTHER (unchanged) file. This is the case that a naive "typecheck only the dirty file"
# shortcut gets wrong -- it would miss the dependent's diagnostics (fastPathExtraFiles) and diverge from
# a cold run. Booting from a snapshot must instead route the dirty set through the SAME production
# fast-path machinery, so the dependent is pulled in and re-typechecked.
#
# Setup: lib.rb defines Lib.value (sig => Integer); consumer.rb (sig => Integer) returns Lib.value. Green.
# After the snapshot is built, lib.rb is edited so Lib.value returns String. lib.rb stays green on its
# own, but consumer.rb -- UNCHANGED on disk, NOT in the dirty set -- now has a method-result-type error.
#
# Assertion: a cold LSP boot and a warm `--load-state` boot (dirty = lib.rb only) must publish the SAME
# set of diagnostics, and that set must include consumer.rb's downstream error. If the warm set is empty
# or differs, the seam is unsound (it missed the dependent) -- the test fails loudly.
#
# Hermetic: uses the explicit --load-state-dirty list (computeDirtySet's git path is unit-tested
# separately). All diagnostics go to capture files; the script's own stdout stays empty (empty test.out).

work="$(mktemp -d)"
sorbet_pid=""
cleanup() {
  if [ -n "${sorbet_pid:-}" ]; then kill "$sorbet_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup exit

# --- Green corpus: consumer.rb depends on Lib.value's (Integer) result type. -------------------------
cat > "$work/lib.rb" <<'RB'
# typed: true
class Lib
  extend T::Sig
  sig {returns(Integer)}
  def self.value
    42
  end
end
RB
cat > "$work/consumer.rb" <<'RB'
# typed: true
class Consumer
  extend T::Sig
  sig {returns(Integer)}
  def self.use
    Lib.value
  end
end
RB

# --- Build the LSP-flavored, fully-resolved snapshot from the GREEN corpus. ---------------------------
main/sorbet --silence-dev-message "$work" \
  --store-state "$work/snap.sym,$work/snap.name,$work/snap.file" --store-state-lsp >/dev/null

# --- Edit lib.rb so Lib.value now returns String. lib.rb is still green standalone, but consumer.rb
#     (unchanged on disk) now returns String where its sig promises Integer -> a downstream error. -----
cat > "$work/lib.rb" <<'RB'
# typed: true
class Lib
  extend T::Sig
  sig {returns(String)}
  def self.value
    "x"
  end
end
RB

# run_lsp <out_file> [extra sorbet args...]
# Boots an LSP server over a FIFO, drives initialize/initialized, waits (deterministically) for the
# downstream diagnostic to be published, then shuts down. Returns non-zero if it never appeared.
run_lsp() {
  local out_file="$1"; shift
  local in_pipe; in_pipe="$(mktemp -u)"
  mkfifo -m 600 "$in_pipe"

  main/sorbet --silence-dev-message --lsp --disable-watchman "$@" \
    --dir "$work" < "$in_pipe" > "$out_file" 2>/dev/null &
  sorbet_pid=$!

  # Hold the input pipe open (older bash on macOS lacks `exec {fd}>`).
  exec 100>"$in_pipe"
  send() { printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1" >&100; }

  send "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"processId\":1,\"rootPath\":\"$work\",\"rootUri\":\"file://$work\",\"capabilities\":{},\"trace\":\"off\"}}"
  send '{"jsonrpc":"2.0","method":"initialized","params":{}}'

  local ok=""
  local _i
  for _i in $(seq 1 200); do
    if grep -q "for method result type" "$out_file"; then ok=1; break; fi
    sleep 0.1
  done

  send '{"jsonrpc":"2.0","id":1,"method":"shutdown","params":null}'
  send '{"jsonrpc":"2.0","method":"exit","params":null}'
  exec 100>&-
  wait "$sorbet_pid" || true
  sorbet_pid=""
  rm -f "$in_pipe"

  [ -n "$ok" ]
}

cold_out="$work/cold.out"
warm_out="$work/warm.out"

# Cold reference: a normal LSP boot (no snapshot) must report the downstream error.
if ! run_lsp "$cold_out"; then
  echo "FAIL: cold LSP boot never reported consumer.rb's downstream error" >&2
  cat "$cold_out" >&2
  exit 1
fi

# Warm: boot from the snapshot, marking ONLY lib.rb dirty. The seam must pull consumer.rb in as a
# fast-path extra file and report the identical error.
if ! run_lsp "$warm_out" \
      --load-state "$work/snap.sym,$work/snap.name,$work/snap.file" \
      --load-state-dirty lib.rb; then
  echo "FAIL: warm --load-state boot did NOT report the downstream dependent error." >&2
  echo "      The seam missed a fastPathExtraFiles dependent of the modified file (UNSOUND)." >&2
  cat "$warm_out" >&2
  exit 1
fi

# Diagnostics-equivalence: the sorted, de-duplicated set of error messages must match exactly.
msgs() { grep -o '"message":"[^"]*"' "$1" | sort -u; }
cold_set="$(msgs "$cold_out")"
warm_set="$(msgs "$warm_out")"

if [ -z "$cold_set" ]; then
  echo "FAIL: cold run produced no diagnostics -- test did not exercise an error" >&2
  exit 1
fi
if [ "$cold_set" != "$warm_set" ]; then
  echo "FAIL: warm --load-state diagnostics diverge from cold:" >&2
  diff <(printf '%s\n' "$cold_set") <(printf '%s\n' "$warm_set") >&2 || true
  exit 1
fi

echo "OK: warm --load-state boot reproduced cold diagnostics exactly, including the modified-file" >&2
echo "    downstream dependent (consumer.rb) pulled in via the production fast path." >&2
