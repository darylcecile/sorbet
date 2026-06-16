#!/bin/bash
set -e

# Phase 3 spike oracle: --load-state incremental-from-snapshot for batch `srb tc` (issue #1).
#
# When a fully-resolved snapshot is loaded with --load-state, Sorbet re-typechecks ONLY the files
# that changed relative to the snapshot, trusting the (green) snapshot for everything else, instead
# of re-running the whole index+name+resolve+typecheck pipeline. This must be correct-by-construction:
# its emitted errors must be BYTE-IDENTICAL to a normal cold run on the same files.
#
# The incremental path engages only when every changed file's change is body-local (its symbol table
# is byte-identical to the snapshot's, so no other file can depend on it) and parse-clean. Any symbol
# change, new/removed file, or parse error declines to a cold boot (exit 1) rather than risk diverging.
#
# All diagnostics go to stderr; stdout stays empty, so the expected output (test.out) is empty.

sorbet() { main/sorbet --silence-dev-message "$@"; }

# ----- green V1 corpus: a (sig-full) + b (sig-less) + app (cross-file callers) -----
write_v1() {
  cat > a.rb <<'RB'
# typed: true
class A
  extend T::Sig
  sig {returns(Integer)}
  def foo
    42
  end
end
RB
  cat > b.rb <<'RB'
# typed: true
class B
  def bar
    "hello"
  end
end
RB
  cat > app.rb <<'RB'
# typed: true
class App
  extend T::Sig
  sig {returns(Integer)}
  def use_a
    A.new.foo
  end
  sig {returns(String)}
  def use_b
    B.new.bar
  end
end
RB
}

FILES="a.rb b.rb app.rb"

write_v1
# V1 must be green so the snapshot is trustworthy.
sorbet $FILES >/dev/null 2>err_v1.txt
if [ -s err_v1.txt ]; then echo "V1 corpus should be green" >&2; cat err_v1.txt >&2; exit 1; fi

# Build the LSP-flavored (Normal-files) snapshot from V1.
sorbet --store-state s.sym,s.name,s.file --store-state-lsp $FILES >/dev/null 2>/dev/null

# Helper: assert that the --load-state run is byte-identical to a cold run on the current files.
# $1 = label; reads the current on-disk files.
assert_identical() {
  local label="$1"
  local cex iex
  set +e
  sorbet $FILES >/dev/null 2>cold.txt; cex=$?
  sorbet --load-state s.sym,s.name,s.file $FILES >/dev/null 2>incr.txt; iex=$?
  set -e
  if ! diff -u cold.txt incr.txt >diff.txt; then
    echo "[$label] load-state output diverged from cold:" >&2
    cat diff.txt >&2
    exit 1
  fi
  if [ "$cex" != "$iex" ]; then
    echo "[$label] exit codes differ: cold=$cex incr=$iex" >&2
    exit 1
  fi
}

# Helper: assert that --load-state declines to a cold boot (exit 1 + message).
assert_decline() {
  local label="$1"
  local iex
  set +e
  sorbet --load-state s.sym,s.name,s.file $FILES >/dev/null 2>incr.txt; iex=$?
  set -e
  if [ "$iex" != "1" ]; then echo "[$label] expected decline (exit 1), got $iex" >&2; cat incr.txt >&2; exit 1; fi
  if ! grep -q "cold boot is required" incr.txt; then
    echo "[$label] expected a 'cold boot is required' message" >&2; cat incr.txt >&2; exit 1
  fi
}

# ----- Case: nothing changed -> zero work, still green (matches cold) -----
write_v1
assert_identical "all-unchanged"

# ----- Case: body-only edit that stays green (a.foo 42 -> 7); sig unchanged -----
write_v1
perl -0pi -e 's/  def foo\n    42\n  end/  def foo\n    7\n  end/' a.rb
assert_identical "body-only-green"

# ----- Case: body-only edit that introduces a LOCAL inference error (a.foo -> String) -----
# Sig unchanged => symbol table unchanged => no downstream dependents => incremental, same error.
write_v1
perl -0pi -e 's/  def foo\n    42\n  end/  def foo\n    "str"\n  end/' a.rb
assert_identical "body-only-local-error"

# ----- Case: body-only edit to a SIG-LESS method (b.bar -> 42) -----
# Sig-less methods return untyped, so a body change can't change callers' errors => incremental.
write_v1
perl -0pi -e 's/  def bar\n    "hello"\n  end/  def bar\n    42\n  end/' b.rb
assert_identical "sigless-body-change"

# ----- Case: SIG change (a.foo Integer -> String) -> a DOWNSTREAM dependent (app.use_a) would
# now error, so the incremental path must DECLINE rather than typecheck a.rb alone. -----
write_v1
perl -0pi -e 's/  sig \{returns\(Integer\)\}\n  def foo\n    42\n  end/  sig {returns(String)}\n  def foo\n    "str"\n  end/' a.rb
assert_decline "sig-change"

# ----- Case: NEW file not in the snapshot -> hierarchy change -> decline -----
write_v1
cat > c.rb <<'RB'
# typed: true
class C; end
RB
set +e
sorbet --load-state s.sym,s.name,s.file a.rb b.rb app.rb c.rb >/dev/null 2>incr.txt; iex=$?
set -e
if [ "$iex" != "1" ] || ! grep -q "cold boot is required" incr.txt; then
  echo "[new-file] expected decline" >&2; cat incr.txt >&2; exit 1
fi
rm -f c.rb

# ----- Case: REMOVED file (snapshot file omitted from inputs) -> decline -----
write_v1
set +e
sorbet --load-state s.sym,s.name,s.file a.rb app.rb >/dev/null 2>incr.txt; iex=$?
set -e
if [ "$iex" != "1" ] || ! grep -q "cold boot is required" incr.txt; then
  echo "[removed-file] expected decline" >&2; cat incr.txt >&2; exit 1
fi

# ----- Case: parse error in a changed file -> decline (avoids any error-ordering ambiguity) -----
write_v1
cat > b.rb <<'RB'
# typed: true
class B
  def bar
    "hello" +
  end
end
RB
assert_decline "parse-error"

# ----- Read-elision: --load-state-dirty names the changed set; unchanged files are NEVER read.
# Corrupt b.rb on disk but mark only a.rb dirty: the corrupt b.rb must not be read, so we stay green
# (proving the unchanged tree is elided -- the whole point of Phase 3). -----
write_v1
perl -0pi -e 's/  def foo\n    42\n  end/  def foo\n    7\n  end/' a.rb
cat > b.rb <<'RB'
this is deliberately corrupt @@@ ###
RB
set +e
sorbet --load-state s.sym,s.name,s.file --load-state-dirty a.rb $FILES >/dev/null 2>incr.txt; iex=$?
set -e
if [ "$iex" != "0" ] || [ -s incr.txt ]; then
  echo "[read-elision] corrupt unchanged b.rb should have been elided (stay green)" >&2
  echo "exit=$iex" >&2; cat incr.txt >&2; exit 1
fi

echo "all incremental-from-snapshot oracle cases passed" >&2
