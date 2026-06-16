#include "main/load_state/SnapshotMeta.h"
#include "absl/strings/match.h"
#include "absl/strings/str_split.h"
#include "spdlog/fmt/fmt.h"
#include <charconv>

using namespace std;

namespace sorbet::realmain::load_state {

namespace {
constexpr string_view HEADER = "sorbet-load-state-meta v1"sv;
constexpr string_view VERSION_KEY = "version="sv;
constexpr string_view OPTIONS_KEY = "cache_sensitive_options="sv;
constexpr string_view GIT_SHA_KEY = "git_sha="sv;
} // namespace

string SnapshotMeta::serialize() const {
    // Cast the options byte to an integer so it is printed as a number, not as a (possibly
    // unprintable) character.
    return fmt::format("{}\n{}{}\n{}{}\n{}{}\n", HEADER, VERSION_KEY, sorbetVersion, OPTIONS_KEY,
                       static_cast<uint32_t>(cacheSensitiveOptions), GIT_SHA_KEY, gitSha);
}

optional<SnapshotMeta> SnapshotMeta::parse(string_view data) {
    vector<string_view> lines = absl::StrSplit(data, '\n');
    if (lines.empty() || lines[0] != HEADER) {
        return nullopt;
    }

    SnapshotMeta meta;
    bool sawVersion = false;
    bool sawOptions = false;
    bool sawGitSha = false;

    for (size_t i = 1; i < lines.size(); ++i) {
        auto line = lines[i];
        if (line.empty()) {
            continue;
        }
        if (absl::StartsWith(line, VERSION_KEY)) {
            meta.sorbetVersion = string(line.substr(VERSION_KEY.size()));
            sawVersion = true;
        } else if (absl::StartsWith(line, OPTIONS_KEY)) {
            auto value = line.substr(OPTIONS_KEY.size());
            uint32_t parsed = 0;
            auto [ptr, ec] = std::from_chars(value.data(), value.data() + value.size(), parsed);
            if (ec != std::errc() || ptr != value.data() + value.size() || parsed > 0xff) {
                return nullopt;
            }
            meta.cacheSensitiveOptions = static_cast<uint8_t>(parsed);
            sawOptions = true;
        } else if (absl::StartsWith(line, GIT_SHA_KEY)) {
            meta.gitSha = string(line.substr(GIT_SHA_KEY.size()));
            sawGitSha = true;
        }
        // Unknown keys are ignored so the format can be extended without breaking old readers.
    }

    if (!sawVersion || !sawOptions || !sawGitSha) {
        return nullopt;
    }
    return meta;
}

bool SnapshotMeta::isCompatibleWith(string_view currentVersion, uint8_t currentCacheSensitiveOptions) const {
    return sorbetVersion == currentVersion && cacheSensitiveOptions == currentCacheSensitiveOptions;
}

} // namespace sorbet::realmain::load_state
