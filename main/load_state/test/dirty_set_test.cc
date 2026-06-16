#include "doctest/doctest.h"
// violates our requirements, thus has to go first
#include "main/load_state/DirtySet.h"
#include "main/load_state/SnapshotMeta.h"
#include <string>

using namespace std;

namespace sorbet::realmain::load_state {

TEST_CASE("SnapshotMeta round-trips through serialize/parse") {
    SnapshotMeta meta;
    meta.sorbetVersion = "Sorbet 0.6.0 git deadbeef (non-release)";
    meta.cacheSensitiveOptions = 0b1010'1100;
    meta.gitSha = "0123456789abcdef0123456789abcdef01234567";

    auto parsed = SnapshotMeta::parse(meta.serialize());
    REQUIRE(parsed.has_value());
    CHECK_EQ(parsed->sorbetVersion, meta.sorbetVersion);
    CHECK_EQ(parsed->cacheSensitiveOptions, meta.cacheSensitiveOptions);
    CHECK_EQ(parsed->gitSha, meta.gitSha);
}

TEST_CASE("SnapshotMeta tolerates an empty git sha") {
    SnapshotMeta meta;
    meta.sorbetVersion = "v";
    meta.cacheSensitiveOptions = 0;
    meta.gitSha = "";

    auto parsed = SnapshotMeta::parse(meta.serialize());
    REQUIRE(parsed.has_value());
    CHECK(parsed->gitSha.empty());
}

TEST_CASE("SnapshotMeta::parse rejects junk and missing keys") {
    CHECK_FALSE(SnapshotMeta::parse("").has_value());
    CHECK_FALSE(SnapshotMeta::parse("not a snapshot").has_value());
    // Missing the git_sha key.
    CHECK_FALSE(SnapshotMeta::parse("sorbet-load-state-meta v1\nversion=v\ncache_sensitive_options=0\n").has_value());
    // Non-numeric options byte.
    CHECK_FALSE(
        SnapshotMeta::parse("sorbet-load-state-meta v1\nversion=v\ncache_sensitive_options=x\ngit_sha=a\n").has_value());
    // Options byte out of uint8 range.
    CHECK_FALSE(
        SnapshotMeta::parse("sorbet-load-state-meta v1\nversion=v\ncache_sensitive_options=999\ngit_sha=a\n")
            .has_value());
}

TEST_CASE("SnapshotMeta::parse ignores unknown forward-compatible keys") {
    auto parsed = SnapshotMeta::parse(
        "sorbet-load-state-meta v1\nversion=v\nfuture_key=whatever\ncache_sensitive_options=3\ngit_sha=abc\n");
    REQUIRE(parsed.has_value());
    CHECK_EQ(parsed->sorbetVersion, "v");
    CHECK_EQ(parsed->cacheSensitiveOptions, 3);
    CHECK_EQ(parsed->gitSha, "abc");
}

TEST_CASE("SnapshotMeta::isCompatibleWith requires matching version and options") {
    SnapshotMeta meta;
    meta.sorbetVersion = "v1";
    meta.cacheSensitiveOptions = 5;

    CHECK(meta.isCompatibleWith("v1", 5));
    CHECK_FALSE(meta.isCompatibleWith("v2", 5));
    CHECK_FALSE(meta.isCompatibleWith("v1", 4));
}

TEST_CASE("parseDiffNameOnlyZ splits NUL-separated paths and ignores blanks") {
    CHECK(parseDiffNameOnlyZ("").empty());
    auto paths = parseDiffNameOnlyZ(string("a/b.rb\0c/d.rb\0", 14));
    REQUIRE_EQ(paths.size(), 2);
    CHECK_EQ(paths[0], "a/b.rb");
    CHECK_EQ(paths[1], "c/d.rb");

    // Tolerates a missing trailing NUL.
    auto noTrailing = parseDiffNameOnlyZ("only.rb");
    REQUIRE_EQ(noTrailing.size(), 1);
    CHECK_EQ(noTrailing[0], "only.rb");
}

TEST_CASE("parseStatusPorcelainZ handles modified, untracked, and rename entries") {
    // " M tracked.rb" (unstaged modify), "?? new.rb" (untracked).
    auto simple = parseStatusPorcelainZ(string(" M tracked.rb\0?? new.rb\0", 24));
    REQUIRE_EQ(simple.size(), 2);
    CHECK_EQ(simple[0], "tracked.rb");
    CHECK_EQ(simple[1], "new.rb");

    // "R  dest.rb" followed by the rename source "src.rb": both sides are dirty.
    auto rename = parseStatusPorcelainZ(string("R  dest.rb\0src.rb\0", 18));
    REQUIRE_EQ(rename.size(), 2);
    CHECK_EQ(rename[0], "dest.rb");
    CHECK_EQ(rename[1], "src.rb");
}

TEST_CASE("mergeDirtyPaths unions, sorts, and de-duplicates") {
    auto diff = string("b.rb\0a.rb\0", 10);
    auto status = string(" M a.rb\0?? c.rb\0", 16);
    auto merged = mergeDirtyPaths(diff, status);
    REQUIRE_EQ(merged.size(), 3);
    CHECK_EQ(merged[0], "a.rb");
    CHECK_EQ(merged[1], "b.rb");
    CHECK_EQ(merged[2], "c.rb");
}

TEST_CASE("computeDirtySet falls back when the snapshot has no base commit") {
    SnapshotMeta meta;
    meta.gitSha = "";
    auto result = computeDirtySet(meta, ".", 1000);
    CHECK_FALSE(result.usable);
    CHECK_FALSE(result.fallbackReason.empty());
}

} // namespace sorbet::realmain::load_state
