#ifndef SORBET_MAIN_LOAD_STATE_SNAPSHOT_META_H
#define SORBET_MAIN_LOAD_STATE_SNAPSHOT_META_H

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace sorbet::realmain::load_state {

// Sidecar metadata that pins a `--store-state-lsp` snapshot to the exact Sorbet build, cache-sensitive
// option set, and source git commit it was produced from. It is written next to the snapshot at store
// time (`--store-state-meta`) and validated at load time (`--load-state-meta`) so that:
//
//   (1) we never deserialize a snapshot produced by an incompatible Sorbet build / option set. A
//       resolved GlobalState is only meaningful for the binary that produced it; loading a stale one
//       would silently corrupt resolution. This mirrors the cache validity key in
//       `main/cache/cache.cc` (sorbet_full_version_string + cacheSensitiveOptions.serialize()).
//
//   (2) Phase 3 knows the base commit to diff the working tree against when computing the dirty set of
//       files to re-index, trusting the loaded GlobalState for everything else.
struct SnapshotMeta {
    // `sorbet_full_version_string` captured at store time.
    std::string sorbetVersion;

    // `Options::CacheSensitiveOptions::serialize()` captured at store time.
    uint8_t cacheSensitiveOptions = 0;

    // Source commit the snapshot was built from (e.g. `git rev-parse HEAD`). May be empty when the
    // snapshot was produced outside a git checkout; the dirty-set oracle treats an empty SHA as an
    // "unknown base" and forces the full-index fallback (no regression).
    std::string gitSha;

    // Stable, human-readable, line-oriented text format. Round-trips with `parse`.
    std::string serialize() const;

    // Parses the format produced by `serialize`. Returns nullopt on a malformed payload (missing
    // header / required keys) so callers can fall back rather than trust junk.
    static std::optional<SnapshotMeta> parse(std::string_view data);

    // True iff a snapshot carrying `this` metadata is safe to load into a Sorbet build identified by
    // `currentVersion` / `currentCacheSensitiveOptions`.
    bool isCompatibleWith(std::string_view currentVersion, uint8_t currentCacheSensitiveOptions) const;
};

} // namespace sorbet::realmain::load_state

#endif // SORBET_MAIN_LOAD_STATE_SNAPSHOT_META_H
