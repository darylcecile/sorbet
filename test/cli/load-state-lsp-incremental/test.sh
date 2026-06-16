#!/usr/bin/env bash
set -euo pipefail

# Phase 3 (issue #1) end-to-end LSP oracle: booting `--lsp --load-state` adopts the loaded resolved
# GlobalState WITHOUT re-indexing the workspace, then re-syncs ONLY the files named as dirty. Unchanged
# files are trusted from the snapshot and never read -- that read-elision is the win.
#
# This exercises the full Commit A + B path with the real binary:
#   - realmain: --load-state + explicit --load-state-dirty => opts.loadStateInitFromSnapshot.
#   - LSPTypechecker::initialize: fast-init (initializeFromSnapshot) instead of runSlowPath(Init).
#   - LSPLoop::runLSP: the one-shot boot thread replays the dirty set as a SorbetWatchmanFileChange.
#
# We use the explicit --load-state-dirty list (not the git oracle) so the test is hermetic in the bazel
# sandbox; computeDirtySet's git path is covered separately by main/load_state unit tests.
#
# All diagnostics from the LSP server are captured to a file and asserted with grep; the script's own
# stdout stays empty so the expected output (test.out) is empty.

# The sandbox cwd is writable; the test directory in runfiles is read-only. Build the corpus here.
work="$(mktemp -d)"
in_pipe="$(mktemp -u)"
out_file="$(mktemp)"
mkfifo -m 600 "$in_pipe"
cleanup() {
  if [ -n "${sorbet_pid:-}" ]; then kill "$sorbet_pid" 2>/dev/null || true; fi
  rm -rf "$work" "$out_file"
  rm -f "$in_pipe"
}
trap cleanup exit

# Green corpus: A#foo: Integer, B#bar: String, App#use_a calls A#foo. No errors.
cat > "$work/a.rb" <<'RB'
# typed: true
class A
  extend T::Sig
  sig {returns(Integer)}
  def foo
    42
  end
end
RB
cat > "$work/b.rb" <<'RB'
# typed: true
class B
  def bar
    "hello"
  end
end
RB
cat > "$work/app.rb" <<'RB'
# typed: true
class App
  extend T::Sig
  sig {returns(Integer)}
  def use_a
    A.new.foo
  end
end
RB

# 1) Build an LSP-flavored, fully-resolved snapshot from the GREEN corpus. Files are keyed by the path
#    Sorbet sees them at ("$work/a.rb", ...), which is what the LSP rootPath + dirty replay reproduces.
main/sorbet --silence-dev-message "$work" \
  --store-state "$work/snap.sym,$work/snap.name,$work/snap.file" --store-state-lsp >/dev/null

# 2) Mutate the on-disk corpus AFTER the snapshot was built:
#    a) app.rb (which we WILL mark dirty) gains a local type error -> must surface.
cat >> "$work/app.rb" <<'RB'
T.assert_type!(A.new.foo, String)
RB
#    b) b.rb (which we will NOT mark dirty) is corrupted with a standalone error. If the load path
#       wrongly re-reads unchanged files, this error would surface; read-elision requires it does NOT.
cat > "$work/b.rb" <<'RB'
# typed: true
class B
  extend T::Sig
  sig {returns(String)}
  def bar
    42
  end
end
RB

# 3) Boot LSP against the snapshot, marking ONLY app.rb dirty (relative to --dir, the rootPath).
main/sorbet --silence-dev-message --lsp --disable-watchman \
  --load-state "$work/snap.sym,$work/snap.name,$work/snap.file" \
  --load-state-dirty app.rb \
  --dir "$work" < "$in_pipe" > "$out_file" 2>/dev/null &
sorbet_pid=$!

# Hold the input pipe open (older bash on macOS lacks `exec {fd}>`).
exec 100>"$in_pipe"
IN_FD=100

send() {
  # $1 = JSON body. Frame with Content-Length per the LSP wire protocol.
  printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1" >&"$IN_FD"
}

send "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"processId\":1,\"rootPath\":\"$work\",\"rootUri\":\"file://$work\",\"capabilities\":{},\"trace\":\"off\"}}"
send '{"jsonrpc":"2.0","method":"initialized","params":{}}'

# Wait (deterministically, up to ~15s) for the dirty-file diagnostic to be published before shutting
# down. This both proves the dirty replay ran and removes any race with the async boot thread.
ok=""
for _ in $(seq 1 150); do
  if grep -q "Argument does not have asserted type" "$out_file"; then ok=1; break; fi
  sleep 0.1
done

send '{"jsonrpc":"2.0","id":1,"method":"shutdown","params":null}'
send '{"jsonrpc":"2.0","method":"exit","params":null}'
wait "$sorbet_pid" || true
sorbet_pid=""

if [ -z "$ok" ]; then
  echo "FAIL: dirty app.rb type error never appeared in LSP diagnostics" >&2
  cat "$out_file" >&2
  exit 1
fi

# Read-elision: the unchanged-but-corrupted b.rb must NEVER have been read, so its standalone error
# must be absent from all diagnostics.
if grep -q "for method result type" "$out_file"; then
  echo "FAIL: an unchanged file (b.rb) was re-read despite not being dirty -- read-elision is broken" >&2
  cat "$out_file" >&2
  exit 1
fi

echo "OK: dirty file re-typechecked from disk; unchanged files trusted from snapshot (elided)" >&2
