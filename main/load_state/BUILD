cc_library(
    name = "load_state",
    srcs = [
        "DirtySet.cc",
        "SnapshotMeta.cc",
    ],
    hdrs = [
        "DirtySet.h",
        "SnapshotMeta.h",
    ],
    linkstatic = select({
        "//tools/config:linkshared": 0,
        "//conditions:default": 1,
    }),
    visibility = ["//visibility:public"],
    deps = [
        "//common",
        "@com_google_absl//absl/algorithm:container",
        "@com_google_absl//absl/strings",
        "@spdlog",
    ],
)

cc_test(
    name = "load_state_test",
    size = "small",
    srcs = glob(["test/*.cc"]),
    linkstatic = select({
        "//tools/config:linkshared": 0,
        "//conditions:default": 1,
    }),
    visibility = ["//tools:__pkg__"],
    deps = [
        "//main/load_state",
        "@doctest//doctest",
        "@doctest//doctest:main",
    ],
)
