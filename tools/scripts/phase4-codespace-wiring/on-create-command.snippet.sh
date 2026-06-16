### Phase 4 DRAFT — on-create snapshot BUILD (prebuild-bake; no registry, no token)
###
### Insert into github/github's .devcontainer/on-create-command.sh immediately BEFORE
### the existing sorbet cache-seed (currently line ~276-277):
###
###     # Run sorbet to seed the cache
###     .vscode/run-sorbet || true
###
### Replace those two lines with the block below. Order matters: build the load-state
### snapshot FIRST (so the kvstore + snapshot are produced by the SAME fork binary and
### the snapshot bakes into the prebuild image), THEN run run-sorbet (which now boots
### FROM the snapshot, seeding/validating the cache on the load path).
###
### Why this works without oras/GHCR: onCreateCommand filesystem output is baked into
### the Codespaces prebuild image (the same reason on-create waits for background jobs
### "so its filesystem output is included in the prebuild image", see the github-ui wait
### near the end of on-create-command.sh). Our snapshot build is ~40s — cheap enough to
### just run here. Dev codespaces created from the prebuild inherit the baked snapshot
### and start with a near-empty git dirty set (snapshot commit == prebuild commit).

# --- Sorbet load-state: build the resolved-state snapshot (bakes into the prebuild) ---
# Both scripts hard-guarantee exit 0 (they swallow every failure), so the `|| true` is
# belt-and-braces: a missing binary / non-green tree / git error can never break
# codespace or prebuild creation. If no snapshot is produced, run-sorbet below simply
# falls back to the stock gem path — no speedup, no regression.
.devcontainer/build-loadstate-snapshot.sh || true

# Run sorbet to seed the cache (now boots from the snapshot when present)
.vscode/run-sorbet || true
# --- end Sorbet load-state ------------------------------------------------------------
