"""Analysis tests for libc-aware pnpm platform config settings."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_LibcSelectInfo = provider(
    doc = "The values selected for a configured libc test platform.",
    fields = {
        "values": "The selected arity and libc values.",
    },
)

def _libc_select_probe_impl(ctx):
    return [_LibcSelectInfo(values = ctx.attr.values)]

_libc_select_probe = rule(
    implementation = _libc_select_probe_impl,
    attrs = {
        "values": attr.string_list(),
    },
)

def _libc_select_resolution_test_impl(ctx):
    env = analysistest.begin(ctx)
    target_under_test = analysistest.target_under_test(env)

    asserts.equals(
        env,
        sorted(ctx.attr.expected),
        sorted(target_under_test[_LibcSelectInfo].values),
    )

    return analysistest.end(env)

_linux_x64_unconstrained_test = analysistest.make(
    _libc_select_resolution_test_impl,
    attrs = {
        "expected": attr.string_list(),
    },
    config_settings = {
        "//command_line_option:platforms": "@@//npm/private/test:libc_select_linux_x64_unconstrained_platform",
    },
)

_linux_x64_glibc_test = analysistest.make(
    _libc_select_resolution_test_impl,
    attrs = {
        "expected": attr.string_list(),
    },
    config_settings = {
        "//command_line_option:platforms": "@@//npm/private/test:libc_select_linux_x64_glibc_platform",
    },
)

_linux_x64_musl_test = analysistest.make(
    _libc_select_resolution_test_impl,
    attrs = {
        "expected": attr.string_list(),
    },
    config_settings = {
        "//command_line_option:platforms": "@@//npm/private/test:libc_select_linux_x64_musl_platform",
    },
)

def libc_select_resolution_test_suite(name):
    """Tests libc select resolution for every supported constraint arity.

    Args:
        name: Name of the test suite.
    """
    native.platform(
        name = "libc_select_linux_x64_unconstrained_platform",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        testonly = True,
    )

    native.platform(
        name = "libc_select_linux_x64_glibc_platform",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
            "@aspect_rules_js//platforms/libc:glibc",
        ],
        testonly = True,
    )

    native.platform(
        name = "libc_select_linux_x64_musl_platform",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
            "@aspect_rules_js//platforms/libc:musl",
        ],
        testonly = True,
    )

    _libc_select_probe(
        name = "libc_select_resolution_subject",
        testonly = True,
        values = select({
            "@aspect_rules_js//platforms/pnpm:unconstrained": ["libc:unconstrained"],
            "@aspect_rules_js//platforms/pnpm:glibc": ["libc:glibc"],
            "@aspect_rules_js//platforms/pnpm:musl": ["libc:musl"],
            "//conditions:default": [],
        }) + select({
            "@aspect_rules_js//platforms/pnpm:linux_unconstrained": ["os_libc:unconstrained"],
            "@aspect_rules_js//platforms/pnpm:linux_glibc": ["os_libc:glibc"],
            "@aspect_rules_js//platforms/pnpm:linux_musl": ["os_libc:musl"],
            "//conditions:default": [],
        }) + select({
            "@aspect_rules_js//platforms/pnpm:x64_unconstrained": ["cpu_libc:unconstrained"],
            "@aspect_rules_js//platforms/pnpm:x64_glibc": ["cpu_libc:glibc"],
            "@aspect_rules_js//platforms/pnpm:x64_musl": ["cpu_libc:musl"],
            "//conditions:default": [],
        }) + select({
            "@aspect_rules_js//platforms/pnpm:linux_x64_unconstrained": ["os_cpu_libc:unconstrained"],
            "@aspect_rules_js//platforms/pnpm:linux_x64_glibc": ["os_cpu_libc:glibc"],
            "@aspect_rules_js//platforms/pnpm:linux_x64_musl": ["os_cpu_libc:musl"],
            "//conditions:default": [],
        }),
    )

    _linux_x64_unconstrained_test(
        name = "libc_select_linux_x64_unconstrained_test",
        expected = [
            "libc:unconstrained",
            "os_libc:unconstrained",
            "cpu_libc:unconstrained",
            "os_cpu_libc:unconstrained",
        ],
        size = "small",
        target_under_test = ":libc_select_resolution_subject",
    )

    _linux_x64_glibc_test(
        name = "libc_select_linux_x64_glibc_test",
        expected = [
            "libc:glibc",
            "os_libc:glibc",
            "cpu_libc:glibc",
            "os_cpu_libc:glibc",
        ],
        size = "small",
        target_under_test = ":libc_select_resolution_subject",
    )

    _linux_x64_musl_test(
        name = "libc_select_linux_x64_musl_test",
        expected = [
            "libc:musl",
            "os_libc:musl",
            "cpu_libc:musl",
            "os_cpu_libc:musl",
        ],
        size = "small",
        target_under_test = ":libc_select_resolution_subject",
    )

    native.test_suite(
        name = name,
        tests = [
            ":libc_select_linux_x64_unconstrained_test",
            ":libc_select_linux_x64_glibc_test",
            ":libc_select_linux_x64_musl_test",
        ],
    )
