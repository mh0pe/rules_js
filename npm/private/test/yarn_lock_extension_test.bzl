"""Tests for yarn_lock extension repository-name resolution."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//npm/private:yarn_lock_extension.bzl", "resolve_yarn_lock_repositories")

def _fake_generate_tag(name):
    return struct(name = name)

def _fake_mod(name, is_root, *generate_tags):
    return struct(
        is_root = is_root,
        name = name,
        tags = struct(generate = generate_tags),
    )

def _root_registration(ctx):
    env = unittest.begin(ctx)
    tag = _fake_generate_tag("generated-yarn-graph")
    result = resolve_yarn_lock_repositories([
        _fake_mod("root", True, tag),
    ])

    asserts.equals(env, None, result.error)
    asserts.equals(env, [tag], result.repositories)
    return unittest.end(env)

def _dependency_registration_rejected(ctx):
    env = unittest.begin(ctx)
    result = resolve_yarn_lock_repositories([
        _fake_mod("dependency", False, _fake_generate_tag("generated-yarn-graph")),
    ])

    asserts.equals(
        env,
        "Only the root module may register yarn_lock.generate repositories; " +
        "module 'dependency' attempted to register 'generated-yarn-graph'.",
        result.error,
    )
    asserts.equals(env, [], result.repositories)
    return unittest.end(env)

def _duplicate_registration_reports_both_modules(ctx):
    env = unittest.begin(ctx)
    result = resolve_yarn_lock_repositories([
        _fake_mod(
            "root",
            True,
            _fake_generate_tag("generated-yarn-graph"),
            _fake_generate_tag("generated-yarn-graph"),
        ),
    ])

    asserts.equals(
        env,
        "yarn_lock.generate repository name 'generated-yarn-graph' was registered " +
        "more than once (by root and root).",
        result.error,
    )
    asserts.equals(env, [], result.repositories)
    return unittest.end(env)

def _former_tool_name_collision_is_allowed(ctx):
    env = unittest.begin(ctx)
    graph = _fake_generate_tag("generated-yarn-graph")
    former_tool_name = _fake_generate_tag("generated-yarn-graph__yarn")
    result = resolve_yarn_lock_repositories([
        _fake_mod("root", True, graph, former_tool_name),
    ])

    asserts.equals(env, None, result.error)
    asserts.equals(env, [graph, former_tool_name], result.repositories)
    return unittest.end(env)

root_registration_test = unittest.make(_root_registration)
dependency_registration_rejected_test = unittest.make(_dependency_registration_rejected)
duplicate_registration_reports_both_modules_test = unittest.make(_duplicate_registration_reports_both_modules)
former_tool_name_collision_is_allowed_test = unittest.make(_former_tool_name_collision_is_allowed)

def yarn_lock_extension_tests(name):
    unittest.suite(
        name,
        root_registration_test,
        dependency_registration_rejected_test,
        duplicate_registration_reports_both_modules_test,
        former_tool_name_collision_is_allowed_test,
    )
