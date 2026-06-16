#ifndef SORBET_MAIN_LOAD_STATE_DIRTY_SET_H
#define SORBET_MAIN_LOAD_STATE_DIRTY_SET_H

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace sorbet::realmain::load_state {

struct SnapshotMeta;

// The set of workspace files that differ from a loaded snapshot's base commit. When `--load-state`
// points Sorbet at a fully-resolved GlobalState, Phase 3 trusts that GlobalState for every unchanged
// file and only re-indexes/re-resolves the dirty set, instead of re-reading + re-hashing the whole
// monorepo (the 35.7s index phase measured at github/github scale).
struct DirtySet {
    // Repo-relative paths that differ from the snapshot's base commit: committed changes since the
    // base, plus uncommitted (staged + unstaged) changes, plus untracked files. Sorted + de-duplicated.
    std::vector<std::string> paths;

    // When false, callers MUST fall back to a full index (today's behavior, no regression): the base
    // SHA was unknown/invalid, git was unavailable, or the delta was too large/structural to trust as
    // a single incremental update.
    bool usable = false;

    // Human-readable reason recorded when `usable == false`, for logs/telemetry.
    std::string fallbackReason;
};

// Parses the NUL-separated output of `git diff --name-only -z <base>` into a list of paths.
// Exposed for unit testing; `computeDirtySet` is the real entry point.
std::vector<std::string> parseDiffNameOnlyZ(std::string_view diffOutput);

// Parses the NUL-separated output of `git status --porcelain -z -uall` into a list of paths, including
// BOTH sides of a rename/copy (so a file that moved away from its snapshot path is captured).
// Exposed for unit testing; `computeDirtySet` is the real entry point.
std::vector<std::string> parseStatusPorcelainZ(std::string_view statusOutput);

// Merges + sorts + de-duplicates the parsed outputs of the two git commands above.
// Exposed for unit testing; `computeDirtySet` is the real entry point.
std::vector<std::string> mergeDirtyPaths(std::string_view diffOutput, std::string_view statusOutput);

// Computes the dirty set by shelling out to git in `repoRoot`, diffing against `meta.gitSha`.
// Returns `usable == false` (with a reason) when the snapshot has no recorded base commit, git is
// unavailable or errors (e.g. the base SHA is not present in this checkout), or when the delta exceeds
// `maxDirtyFiles` (the structural-delta cap that forces a clean full-index fallback).
DirtySet computeDirtySet(const SnapshotMeta &meta, std::string_view repoRoot, size_t maxDirtyFiles);

} // namespace sorbet::realmain::load_state

#endif // SORBET_MAIN_LOAD_STATE_DIRTY_SET_H
