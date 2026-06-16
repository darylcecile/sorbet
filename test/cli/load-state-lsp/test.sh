#!/bin/bash
set -e

# Phase 1b oracle for --store-state-lsp (the "LSP-flavored" store).
#
# A regular --store-state snapshot calls markAsPayload(), so every workspace file is stored as
# File::Type::Payload. On load, readFileWithStrictnessOverrides (pipeline.cc) returns nullptr for
# Payload files, silently skipping them -- they are never re-indexed or editable. --store-state-lsp
# skips markAsPayload (and the PayloadGeneration marking during indexing) so workspace files stay
# File::Type::Normal: ordinary, editable, re-indexable files, which is the substrate Phase 3 needs.
#
# All diagnostics go to stderr; stdout stays empty so the expected output (test.out) is empty.

prog='class Foo; def bar; 1; end; end'

# Store the same program twice: a regular (Payload-typed) snapshot and an LSP-flavored
# (Normal-typed) snapshot.
main/sorbet --silence-dev-message -e "$prog" --store-state sym,name,file
main/sorbet --silence-dev-message -e "$prog" --store-state sym_lsp,name_lsp,file_lsp --store-state-lsp

for f in sym name file sym_lsp name_lsp file_lsp; do
  if [ ! -f "$f" ]; then
    echo "snapshot file '$f' wasn't created" >&2
    exit 1
  fi
done

# The resolved GlobalState must be identical: --store-state-lsp changes ONLY how workspace files
# are typed, never the symbol table or name table.
diff sym sym_lsp >&2
diff name name_lsp >&2

# The file tables must differ, and differ ONLY in the workspace file's sourceType byte:
# File::Type::Payload (2) for the regular store vs File::Type::Normal (3) for the LSP store.
if cmp -s file file_lsp; then
  echo "file tables are byte-identical, but --store-state-lsp should keep workspace files Normal" >&2
  exit 1
fi
cmpout="$(cmp -l file file_lsp || true)"
ndiff="$(printf '%s\n' "$cmpout" | grep -c '[0-9]')"
if [ "$ndiff" -ne 1 ]; then
  echo "expected exactly one differing byte (the sourceType), got $ndiff:" >&2
  printf '%s\n' "$cmpout" >&2
  exit 1
fi
# cmp -l prints "<offset> <oldval> <newval>"; values are octal but 2 and 3 are octal-identical.
old="$(printf '%s\n' "$cmpout" | awk '{print $2}')"
new="$(printf '%s\n' "$cmpout" | awk '{print $3}')"
if [ "$old" != "2" ] || [ "$new" != "3" ]; then
  echo "expected sourceType byte Payload(2) -> Normal(3), got $old -> $new" >&2
  exit 1
fi

# Round-trip oracle: loading the LSP snapshot and re-storing it with --store-state-lsp must
# reproduce a byte-identical snapshot. This proves the loaded Normal files survive a
# store/load/store cycle (the same way the compiled-in payload is validated in Phase 1a).
main/sorbet --silence-dev-message --load-state sym_lsp,name_lsp,file_lsp \
  --store-state sym_lsp2,name_lsp2,file_lsp2 --store-state-lsp
diff sym_lsp sym_lsp2 >&2
diff name_lsp name_lsp2 >&2
diff file_lsp file_lsp2 >&2

# Control: loading the LSP (Normal) snapshot and re-storing WITHOUT --store-state-lsp re-applies
# markAsPayload, which must reproduce the original regular (Payload) file table byte-for-byte. This
# proves the Normal snapshot loads faithfully and the sourceType is the only thing that changed.
main/sorbet --silence-dev-message --load-state sym_lsp,name_lsp,file_lsp \
  --store-state sym_rp,name_rp,file_rp
diff file file_rp >&2
