#include "main/load_state/DirtySet.h"
#include "absl/algorithm/container.h"
#include "common/Subprocess.h"
#include "main/load_state/SnapshotMeta.h"
#include "spdlog/fmt/fmt.h"

using namespace std;

namespace sorbet::realmain::load_state {

vector<string> parseDiffNameOnlyZ(string_view diffOutput) {
    vector<string> paths;
    size_t start = 0;
    while (start < diffOutput.size()) {
        auto nul = diffOutput.find('\0', start);
        if (nul == string_view::npos) {
            // Tolerate a trailing record without a NUL terminator.
            nul = diffOutput.size();
        }
        if (nul > start) {
            paths.emplace_back(diffOutput.substr(start, nul - start));
        }
        start = nul + 1;
    }
    return paths;
}

vector<string> parseStatusPorcelainZ(string_view statusOutput) {
    // `git status --porcelain -z` emits NUL-separated records. Each entry begins with a two-character
    // status code (XY) followed by a space and the (destination) path. Rename/copy entries (X or Y is
    // 'R' or 'C') are followed by a second NUL-separated record holding the original path.
    vector<string> fields;
    {
        size_t start = 0;
        while (start < statusOutput.size()) {
            auto nul = statusOutput.find('\0', start);
            if (nul == string_view::npos) {
                nul = statusOutput.size();
            }
            fields.emplace_back(statusOutput.substr(start, nul - start));
            start = nul + 1;
        }
    }

    vector<string> paths;
    for (size_t i = 0; i < fields.size(); ++i) {
        auto &field = fields[i];
        // A well-formed entry is "XY <path>": at least 2 status chars, a separator, and a path.
        if (field.size() < 4) {
            continue;
        }
        char x = field[0];
        char y = field[1];
        // field[2] is a space separator.
        paths.emplace_back(field.substr(3));

        if (x == 'R' || x == 'C' || y == 'R' || y == 'C') {
            // The next record is the rename/copy source; capture it too so a file that moved away from
            // its snapshot path is treated as dirty at BOTH paths.
            if (i + 1 < fields.size()) {
                ++i;
                if (!fields[i].empty()) {
                    paths.emplace_back(fields[i]);
                }
            }
        }
    }
    return paths;
}

vector<string> mergeDirtyPaths(string_view diffOutput, string_view statusOutput) {
    auto paths = parseDiffNameOnlyZ(diffOutput);
    auto statusPaths = parseStatusPorcelainZ(statusOutput);
    paths.insert(paths.end(), make_move_iterator(statusPaths.begin()), make_move_iterator(statusPaths.end()));
    absl::c_sort(paths);
    paths.erase(unique(paths.begin(), paths.end()), paths.end());
    return paths;
}

namespace {
optional<Subprocess::Result> runGit(string_view repoRoot, vector<string> args) {
    vector<string> argv;
    argv.reserve(args.size() + 2);
    argv.emplace_back("-C");
    argv.emplace_back(repoRoot);
    for (auto &arg : args) {
        argv.emplace_back(std::move(arg));
    }
    return Subprocess::spawn("git", std::move(argv), nullopt);
}
} // namespace

DirtySet computeDirtySet(const SnapshotMeta &meta, string_view repoRoot, size_t maxDirtyFiles) {
    DirtySet result;

    if (meta.gitSha.empty()) {
        result.fallbackReason = "snapshot has no recorded base commit";
        return result;
    }

    // Verify the base commit is actually present in this checkout before trusting a diff against it.
    // A shallow clone or a force-push could leave us without the snapshot's base, in which case the
    // diff would be meaningless and we must fall back.
    auto verify = runGit(repoRoot, {"cat-file", "-e", fmt::format("{}^{{commit}}", meta.gitSha)});
    if (!verify.has_value() || verify->status != 0) {
        result.fallbackReason = fmt::format("base commit {} not found in checkout", meta.gitSha);
        return result;
    }

    // Tracked changes between the base commit and the current working tree (committed-since + staged +
    // unstaged), in one shot.
    auto diff = runGit(repoRoot, {"diff", "--name-only", "-z", meta.gitSha});
    if (!diff.has_value() || diff->status != 0) {
        result.fallbackReason = "git diff against base commit failed";
        return result;
    }

    // Untracked files (e.g. generated RBIs that aren't committed) are invisible to `git diff`; -uall
    // surfaces every one of them. Also re-covers staged/unstaged tracked changes for belt-and-braces.
    auto status = runGit(repoRoot, {"status", "--porcelain", "-z", "-uall"});
    if (!status.has_value() || status->status != 0) {
        result.fallbackReason = "git status failed";
        return result;
    }

    result.paths = mergeDirtyPaths(diff->output, status->output);

    if (result.paths.size() > maxDirtyFiles) {
        result.fallbackReason =
            fmt::format("delta of {} files exceeds cap of {}", result.paths.size(), maxDirtyFiles);
        result.paths.clear();
        return result;
    }

    result.usable = true;
    return result;
}

} // namespace sorbet::realmain::load_state
