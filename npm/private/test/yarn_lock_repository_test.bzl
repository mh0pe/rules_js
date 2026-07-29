"""Tests for Yarn graph repository configuration isolation."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//npm/private:yarn_lock_repository.bzl", "yarn_lock_repository_testonly")

def _yaml_root_keys_test_impl(ctx):
    env = unittest.begin(ctx)

    keys, error = yarn_lock_repository_testonly.yaml_root_keys("""
# supportedArchitectures: [commented]
nodeLinker: pnp
nested:
  supportedArchitectures: [nested]
'supportedArchitectures': &architectures
  os: [linux]
""")
    asserts.equals(env, None, error)
    asserts.equals(
        env,
        {
            "nested": True,
            "nodeLinker": True,
            "supportedArchitectures": True,
        },
        keys,
    )

    keys, error = yarn_lock_repository_testonly.yaml_root_keys("""
  "supportedArchitectures":
    cpu: [x64]
  enableScripts: false
""")
    asserts.equals(env, None, error)
    asserts.equals(
        env,
        {
            "enableScripts": True,
            "supportedArchitectures": True,
        },
        keys,
    )

    return unittest.end(env)

def _yaml_root_keys_ambiguity_test_impl(ctx):
    env = unittest.begin(ctx)

    _, error = yarn_lock_repository_testonly.yaml_root_keys("{supportedArchitectures: {os: [linux]}}")
    asserts.equals(env, "flow-style root mappings cannot be merged safely", error)

    _, error = yarn_lock_repository_testonly.yaml_root_keys("--- {supportedArchitectures: {os: [linux]}}")
    asserts.equals(env, "document-prefixed root content cannot be merged safely", error)

    _, error = yarn_lock_repository_testonly.yaml_root_keys("? supportedArchitectures\n: {os: [linux]}")
    asserts.equals(env, "complex root mapping keys cannot be merged safely", error)

    for source in [
        "!!str supportedArchitectures:\n  os: [linux]",
        "&architectures supportedArchitectures:\n  os: [linux]",
        "*architectures: {os: [linux]}",
    ]:
        _, error = yarn_lock_repository_testonly.yaml_root_keys(source)
        asserts.equals(env, "tagged, anchored, or aliased root mapping keys cannot be merged safely", error)

    _, error = yarn_lock_repository_testonly.yaml_root_keys("<<: *defaults")
    asserts.equals(env, "YAML root merge keys cannot be merged safely", error)

    _, error = yarn_lock_repository_testonly.yaml_root_keys("\"supported\\u0041rchitectures\": {}")
    asserts.equals(env, "escaped quoted root mapping keys cannot be merged safely", error)

    _, error = yarn_lock_repository_testonly.yaml_root_keys("\tnodeLinker: pnp")
    asserts.equals(env, "tabs are not supported in YAML indentation", error)

    for source in [
        "---\nnodeLinker: pnp",
        "nodeLinker: pnp\n...",
        "nodeLinker: pnp\n---\nenableScripts: false",
        "nodeLinker: pnp\n... # explicit document end",
    ]:
        _, error = yarn_lock_repository_testonly.yaml_root_keys(source)
        asserts.equals(env, "YAML document boundary markers cannot be merged safely", error)

    _, error = yarn_lock_repository_testonly.yaml_root_keys("%YAML 1.2\n---\nnodeLinker: pnp")
    asserts.equals(env, "YAML directives cannot be merged safely", error)

    return unittest.end(env)

yaml_root_keys_test = unittest.make(_yaml_root_keys_test_impl)
yaml_root_keys_ambiguity_test = unittest.make(_yaml_root_keys_ambiguity_test_impl)

def yarn_lock_repository_tests(name):
    unittest.suite(
        name,
        partial.make(yaml_root_keys_test, size = "small"),
        partial.make(yaml_root_keys_ambiguity_test, size = "small"),
    )
