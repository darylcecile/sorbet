#!/bin/bash
set -e

# Store a fully-resolved snapshot from a small program.
main/sorbet --silence-dev-message -e 'class Foo; def bar; 1; end; end' --store-state symtab,names,files
if [ ! -f symtab ] || [ ! -f names ] || [ ! -f files ]; then
  echo "snapshot wasn't created"
  exit 1
fi

# Round-trip oracle: loading the snapshot with --load-state and re-storing it must reproduce a
# byte-identical snapshot. This proves --load-state faithfully reconstructs the GlobalState (the
# same way the compiled-in payload is validated), and it sidesteps the non-determinism of running
# `srb tc` over a large corpus.
main/sorbet --silence-dev-message --load-state symtab,names,files --store-state symtab2,names2,files2
if [ ! -f symtab2 ] || [ ! -f names2 ] || [ ! -f files2 ]; then
  echo "round-trip snapshot wasn't created"
  exit 1
fi

diff symtab symtab2 # there should be no difference
diff names names2 # there should be no difference
diff files files2 # there should be no difference
