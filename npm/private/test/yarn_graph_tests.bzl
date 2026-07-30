"""Unit and analysis-failure tests for the normalized Yarn graph parser."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//npm/private:yarn_graph.bzl", "yarn_graph")

_GRAPH_LABEL = Label("//npm/private/test:yarn_graph_fixture.json")
_PACKAGE_NAME = "left-pad"
_PACKAGE_VERSION = "1.3.0_yarn_0123456789abcdef0123456789abcdef"
_PACKAGE_KEY = "{}@{}".format(_PACKAGE_NAME, _PACKAGE_VERSION)
_SOURCE_LOCK_VERSIONS = {
    "berry-v4": 4,
    "berry-v6": 6,
    "berry-v8": 8,
    "berry-v9": 9,
    "berry-v10": 10,
    "classic-v1": 1,
}

def _configuration(
        node_linker,
        pnp_mode = "strict",
        pnp_fallback_mode = "dependencies-only"):
    return {
        "cacheMigrationMode": "always",
        "checksumBehavior": "throw",
        "compressionLevel": 0,
        "defaultLanguageName": "node",
        "defaultProtocol": "npm:",
        "enableScripts": False,
        "enableStrictSettings": True,
        "enableTransparentWorkspaces": True,
        "httpRetry": 3,
        "httpTimeout": 60000,
        "networkConcurrency": 65,
        "nmHoistingLimits": "none",
        "nmMode": "classic",
        "nmSelfReferences": True,
        "nodeLinker": node_linker,
        "pnpEnableEsmLoader": False,
        "pnpEnableEsmLoaderExplicit": False,
        "pnpEnableInlining": True,
        "pnpFallbackMode": pnp_fallback_mode,
        "pnpIgnorePatterns": [],
        "pnpMode": pnp_mode,
        "pnpShebang": "#!/usr/bin/env node",
        "pnpUnpluggedFolder": ".yarn/unplugged",
        "registryPolicy": {
            "npmAlwaysAuth": False,
            "npmAuditRegistryUrl": None,
            "npmPublishRegistryUrl": None,
            "npmRegistryServerUrl": "https://registry.yarnpkg.com",
            "registries": [],
            "scopes": {},
        },
        "supportedArchitectures": {
            "cpu": ["current"],
            "libc": ["current"],
            "os": ["current"],
        },
        "winLinkType": "junctions",
    }

def _package(resolution):
    return {
        "bins": {},
        "conditions": None,
        "dependencies": {},
        "dependency_meta": {},
        "dev_only": False,
        "friendly_version": "1.3.0",
        "has_bin": False,
        "link_type": "HARD",
        "name": _PACKAGE_NAME,
        "optional": False,
        "optional_dependencies": {},
        "peer_dependencies": {},
        "peer_dependencies_meta": {},
        "prod_reachable": True,
        "requires_build": False,
        "resolution": resolution,
        "version": _PACKAGE_VERSION,
        "yarn_build_metadata": {
            "requires_build": False,
        },
    }

def _graph(
        source_format,
        node_linker = None,
        pnp_mode = "strict",
        pnp_fallback_mode = "dependencies-only",
        exporter_yarn_version = "4.5.0"):
    is_classic = source_format == "classic-v1"
    locator_hash = "b" * 128
    if is_classic:
        resolution = {
            "archive": "archives/classic-left-pad.tgz",
            "archive_sha256": "a" * 64,
            "integrity": "sha512-" + ("A" * 86) + "==",
            "legacy_sha1": "d" * 40,
            "locator": "left-pad@npm:1.3.0",
            "locator_hash": locator_hash,
            "resolved_url": "https://registry.yarnpkg.com/left-pad/-/left-pad-1.3.0.tgz#" + ("d" * 40),
            "type": "yarn-classic-tarball",
        }
        declared_version = "1.22.22"
        effective_node_linker = node_linker or "pnpm"
    else:
        resolution = {
            "archive": "archives/left-pad.zip",
            "archive_sha256": "a" * 64,
            "locator": "left-pad@npm:1.3.0",
            "locator_hash": locator_hash,
            "type": "yarn-cache",
            "yarn_checksum": "10c0/" + ("c" * 128),
        }
        declared_version = "4.5.0"
        effective_node_linker = node_linker or "pnp"

    return {
        "importers": {
            ".": {
                "dependencies": {
                    _PACKAGE_NAME: _PACKAGE_VERSION,
                },
                "dev_dependencies": {},
                "install_config": {
                    "hoistingLimits": None,
                    "selfReferences": None,
                },
                "optional_dependencies": {},
            },
        },
        "metadata": {
            "configuration": _configuration(
                effective_node_linker,
                pnp_mode,
                pnp_fallback_mode,
            ),
            "declared_package_managers": [{
                "field": "packageManager",
                "name": "yarn",
                "version": declared_version,
            }],
            "exporter_yarn_version": exporter_yarn_version,
            "lifecycle": {
                "package_manifests_inspected": True,
                "scripts_executed": False,
            },
            "pinned_yarn_compatibility_adjustments": [],
            "source_lock_version": _SOURCE_LOCK_VERSIONS[source_format],
            "source_package": "npm/private/test",
            "workspace_package_extension_adjustments": [],
        },
        "packages": {
            _PACKAGE_KEY: _package(resolution),
        },
        "patched_dependencies": {},
        "schema_version": 2,
        "source_format": source_format,
    }

def _reachability_package(
        graph,
        name,
        locator_hash_character,
        dev_only = False,
        optional = False,
        prod_reachable = False):
    version = "1.0.0"
    package = dict(graph["packages"][_PACKAGE_KEY])
    resolution = dict(package["resolution"])
    archive_extension = ".tgz" if resolution["archive"].endswith(".tgz") else ".zip"
    resolution["archive"] = "archives/{}{}".format(name, archive_extension)
    resolution["locator"] = "{}@npm:{}".format(name, version)
    resolution["locator_hash"] = locator_hash_character * 128
    package["dependencies"] = {}
    package["dev_only"] = dev_only
    package["friendly_version"] = version
    package["name"] = name
    package["optional"] = optional
    package["optional_dependencies"] = {}
    package["prod_reachable"] = prod_reachable
    package["resolution"] = resolution
    package["version"] = version
    return package

def _valid_berry_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    for source_format in ["berry-v4", "berry-v6", "berry-v8", "berry-v9", "berry-v10"]:
        exporter_yarn_versions = ["4.18.0"] if source_format in ["berry-v9", "berry-v10"] else ["4.5.0", "4.18.0"]
        for exporter_yarn_version in exporter_yarn_versions:
            importers, packages, error = yarn_graph.parse_json(
                json.encode(_graph(
                    source_format,
                    exporter_yarn_version = exporter_yarn_version,
                )),
                _GRAPH_LABEL,
            )

            asserts.equals(env, None, error)
            asserts.equals(env, [_PACKAGE_KEY], packages.keys())
            asserts.equals(env, "yarn-cache", packages[_PACKAGE_KEY]["resolution"]["type"])
            asserts.equals(
                env,
                _GRAPH_LABEL.relative("archives/left-pad.zip"),
                packages[_PACKAGE_KEY]["resolution"]["archive"],
            )
            asserts.equals(env, _PACKAGE_KEY, importers["."]["dependencies"][_PACKAGE_NAME])
    return unittest.end(env)

def _conditions_and_dependency_filtering_test_impl(ctx):
    env = unittest.begin(ctx)

    conditional_graph = _graph("berry-v8")
    conditional_graph["packages"][_PACKAGE_KEY]["conditions"] = "os=linux & cpu=x64 & libc=glibc"
    _, conditional_packages, error = yarn_graph.parse_json(
        json.encode(conditional_graph),
        _GRAPH_LABEL,
    )
    asserts.equals(env, None, error)
    asserts.equals(env, ["linux"], conditional_packages[_PACKAGE_KEY]["os"])
    asserts.equals(env, ["x64"], conditional_packages[_PACKAGE_KEY]["cpu"])
    asserts.equals(env, ["glibc"], conditional_packages[_PACKAGE_KEY]["libc"])

    grouped_graph = _graph("berry-v8")
    grouped_graph["packages"][_PACKAGE_KEY]["conditions"] = "(os=linux | os=darwin) & (!cpu=ia32 | !cpu=arm) & !libc=musl"
    _, grouped_packages, error = yarn_graph.parse_json(
        json.encode(grouped_graph),
        _GRAPH_LABEL,
    )
    asserts.equals(env, None, error)
    asserts.equals(env, ["linux", "darwin"], grouped_packages[_PACKAGE_KEY]["os"])
    asserts.equals(env, ["!ia32", "!arm"], grouped_packages[_PACKAGE_KEY]["cpu"])
    asserts.equals(env, ["!musl"], grouped_packages[_PACKAGE_KEY]["libc"])

    dev_graph = _graph("berry-v8")
    dev_graph["importers"]["."]["dependencies"] = {}
    dev_graph["importers"]["."]["dev_dependencies"] = {_PACKAGE_NAME: _PACKAGE_VERSION}
    dev_graph["packages"][_PACKAGE_KEY]["dev_only"] = True
    dev_graph["packages"][_PACKAGE_KEY]["prod_reachable"] = False
    dev_importers, dev_packages, error = yarn_graph.parse_json(
        json.encode(dev_graph),
        _GRAPH_LABEL,
        True,
        False,
    )
    asserts.equals(env, None, error)
    asserts.equals(env, {}, dev_importers["."]["dev_dependencies"])
    asserts.equals(env, {}, dev_packages)

    optional_graph = _graph("berry-v8")
    optional_graph["importers"]["."]["dependencies"] = {}
    optional_graph["importers"]["."]["optional_dependencies"] = {_PACKAGE_NAME: _PACKAGE_VERSION}
    optional_graph["packages"][_PACKAGE_KEY]["optional"] = True
    optional_graph["packages"][_PACKAGE_KEY]["prod_reachable"] = False
    optional_importers, optional_packages, error = yarn_graph.parse_json(
        json.encode(optional_graph),
        _GRAPH_LABEL,
        False,
        True,
    )
    asserts.equals(env, None, error)
    asserts.equals(env, {}, optional_importers["."]["optional_dependencies"])
    asserts.equals(env, {}, optional_packages)

    return unittest.end(env)

def _mixed_reachability_filtering_test_impl(ctx):
    env = unittest.begin(ctx)
    prod_key = "prod@1.0.0"
    dev_parent_key = "dev-parent@1.0.0"
    optional_parent_key = "optional-parent@1.0.0"
    dev_optional_key = "dev-optional@1.0.0"
    mixed_key = "mixed@1.0.0"
    unreachable_key = "unreachable@1.0.0"

    filter_matrix = [
        (
            False,
            False,
            [
                dev_optional_key,
                dev_parent_key,
                mixed_key,
                optional_parent_key,
                prod_key,
                unreachable_key,
            ],
        ),
        (True, False, [mixed_key, optional_parent_key, prod_key, unreachable_key]),
        (False, True, [dev_parent_key, mixed_key, prod_key, unreachable_key]),
        (True, True, [prod_key]),
    ]

    for source_format in ["classic-v1", "berry-v8"]:
        graph = _graph(source_format)
        prod = _reachability_package(graph, "prod", "1", prod_reachable = True)
        dev_parent = _reachability_package(graph, "dev-parent", "2", dev_only = True)
        optional_parent = _reachability_package(graph, "optional-parent", "3", optional = True)
        dev_optional = _reachability_package(
            graph,
            "dev-optional",
            "4",
            dev_only = True,
            optional = True,
        )
        mixed = _reachability_package(graph, "mixed", "5")
        unreachable = _reachability_package(graph, "unreachable", "6")
        dev_parent["dependencies"] = {"mixed": "1.0.0"}
        dev_parent["optional_dependencies"] = {"dev-optional": "1.0.0"}
        optional_parent["dependencies"] = {"mixed": "1.0.0"}
        graph["packages"] = {
            dev_optional_key: dev_optional,
            dev_parent_key: dev_parent,
            mixed_key: mixed,
            optional_parent_key: optional_parent,
            prod_key: prod,
            unreachable_key: unreachable,
        }
        graph["importers"]["."]["dependencies"] = {"prod": "1.0.0"}
        graph["importers"]["."]["dev_dependencies"] = {"dev-parent": "1.0.0"}
        graph["importers"]["."]["optional_dependencies"] = {"optional-parent": "1.0.0"}

        for no_dev, no_optional, expected_package_keys in filter_matrix:
            importers, packages, error = yarn_graph.parse_json(
                json.encode(graph),
                _GRAPH_LABEL,
                no_dev,
                no_optional,
            )
            asserts.equals(env, None, error)
            asserts.equals(env, expected_package_keys, sorted(packages.keys()))
            asserts.equals(
                env,
                {} if no_dev else {"dev-parent": dev_parent_key},
                importers["."]["dev_dependencies"],
            )
            asserts.equals(
                env,
                {} if no_optional else {"optional-parent": optional_parent_key},
                importers["."]["optional_dependencies"],
            )
            asserts.equals(env, {"prod": prod_key}, importers["."]["dependencies"])

            if dev_parent_key in packages:
                asserts.equals(
                    env,
                    {"mixed": mixed_key},
                    packages[dev_parent_key]["dependencies"],
                )
                asserts.equals(
                    env,
                    {} if no_optional else {"dev-optional": dev_optional_key},
                    packages[dev_parent_key]["optional_dependencies"],
                )
            if optional_parent_key in packages:
                asserts.equals(
                    env,
                    {"mixed": mixed_key},
                    packages[optional_parent_key]["dependencies"],
                )
            if mixed_key in packages:
                asserts.equals(
                    env,
                    False,
                    packages[mixed_key]["prod_reachable"],
                )
            if unreachable_key in packages:
                asserts.equals(
                    env,
                    False,
                    packages[unreachable_key]["prod_reachable"],
                )

    return unittest.end(env)

def _linker_pnp_matrix_test_impl(ctx):
    env = unittest.begin(ctx)
    baseline_importers = None
    baseline_packages = None

    for node_linker in ["pnp", "pnpm", "node-modules"]:
        for pnp_mode in ["strict", "loose"]:
            for pnp_fallback_mode in ["none", "dependencies-only", "all"]:
                importers, packages, error = yarn_graph.parse_json(
                    json.encode(_graph(
                        "berry-v8",
                        node_linker = node_linker,
                        pnp_mode = pnp_mode,
                        pnp_fallback_mode = pnp_fallback_mode,
                    )),
                    _GRAPH_LABEL,
                )

                asserts.equals(env, None, error)
                if baseline_importers == None:
                    baseline_importers = importers
                    baseline_packages = packages
                else:
                    asserts.equals(env, baseline_importers, importers)
                    asserts.equals(env, baseline_packages, packages)
    return unittest.end(env)

def _source_schema_rejection_test_impl(ctx):
    env = unittest.begin(ctx)

    unknown_schema = _graph("berry-v10")
    unknown_schema["source_format"] = "berry-v12"
    unknown_schema["metadata"]["source_lock_version"] = 12
    _, _, error = yarn_graph.parse_json(json.encode(unknown_schema), _GRAPH_LABEL)
    asserts.equals(
        env,
        "Yarn graph parse error: unsupported source_format berry-v12",
        error,
    )

    inconsistent_schema = _graph("berry-v6")
    inconsistent_schema["metadata"]["source_lock_version"] = 8
    _, _, error = yarn_graph.parse_json(json.encode(inconsistent_schema), _GRAPH_LABEL)
    asserts.equals(
        env,
        "Yarn graph parse error: metadata.source_lock_version 8 is inconsistent with source_format berry-v6",
        error,
    )

    for source_format in ["berry-v9", "berry-v10"]:
        unsupported_exporter = _graph(
            source_format,
            exporter_yarn_version = "4.5.0",
        )
        _, _, error = yarn_graph.parse_json(
            json.encode(unsupported_exporter),
            _GRAPH_LABEL,
        )
        asserts.equals(
            env,
            "Yarn graph parse error: metadata.exporter_yarn_version 4.5.0 is not supported for source_format {}; expected 4.18.0".format(source_format),
            error,
        )

    unsupported_classic_exporter = _graph(
        "classic-v1",
        exporter_yarn_version = "4.18.0",
    )
    _, _, error = yarn_graph.parse_json(
        json.encode(unsupported_classic_exporter),
        _GRAPH_LABEL,
    )
    asserts.equals(
        env,
        "Yarn graph parse error: metadata.exporter_yarn_version 4.18.0 is not supported for source_format classic-v1; expected 4.5.0",
        error,
    )
    return unittest.end(env)

def _valid_classic_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    importers, packages, error = yarn_graph.parse_json(
        json.encode(_graph("classic-v1")),
        _GRAPH_LABEL,
    )

    asserts.equals(env, None, error)
    asserts.equals(env, [_PACKAGE_KEY], packages.keys())
    asserts.equals(
        env,
        "yarn-classic-tarball",
        packages[_PACKAGE_KEY]["resolution"]["type"],
    )
    asserts.equals(
        env,
        _GRAPH_LABEL.relative("archives/classic-left-pad.tgz"),
        packages[_PACKAGE_KEY]["resolution"]["archive"],
    )
    asserts.equals(env, _PACKAGE_KEY, importers["."]["dependencies"][_PACKAGE_NAME])
    return unittest.end(env)

_valid_berry_graph_test = unittest.make(_valid_berry_graph_test_impl)
_valid_classic_graph_test = unittest.make(_valid_classic_graph_test_impl)
_conditions_and_dependency_filtering_test = unittest.make(_conditions_and_dependency_filtering_test_impl)
_mixed_reachability_filtering_test = unittest.make(_mixed_reachability_filtering_test_impl)
_linker_pnp_matrix_test = unittest.make(_linker_pnp_matrix_test_impl)
_source_schema_rejection_test = unittest.make(_source_schema_rejection_test_impl)

def _parse_subject_impl(ctx):
    yarn_graph.parse_json(ctx.attr.content, _GRAPH_LABEL)
    return [DefaultInfo()]

_parse_subject = rule(
    implementation = _parse_subject_impl,
    attrs = {
        "content": attr.string(mandatory = True),
    },
)

def _parse_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_message)
    return analysistest.end(env)

_parse_failure_test = analysistest.make(
    _parse_failure_test_impl,
    attrs = {
        "expected_message": attr.string(mandatory = True),
    },
    expect_failure = True,
)

def _failure_case(name, content, expected_message):
    subject = name + "_subject"
    _parse_subject(
        name = subject,
        content = content,
        tags = ["manual"],
    )
    _parse_failure_test(
        name = name,
        expected_message = expected_message,
        size = "small",
        target_under_test = ":" + subject,
    )

def yarn_graph_tests(name):
    """Instantiates the normalized Yarn graph parser test suite.

    Args:
        name: Name of the generated test suite.
    """
    tests = []

    valid_berry = name + "_valid_berry_test"
    _valid_berry_graph_test(
        name = valid_berry,
        size = "small",
    )
    tests.append(":" + valid_berry)

    valid_classic = name + "_valid_classic_test"
    _valid_classic_graph_test(
        name = valid_classic,
        size = "small",
    )
    tests.append(":" + valid_classic)

    conditions_and_filtering = name + "_conditions_and_dependency_filtering_test"
    _conditions_and_dependency_filtering_test(
        name = conditions_and_filtering,
        size = "small",
    )
    tests.append(":" + conditions_and_filtering)

    mixed_reachability_filtering = name + "_mixed_reachability_filtering_test"
    _mixed_reachability_filtering_test(
        name = mixed_reachability_filtering,
        size = "small",
    )
    tests.append(":" + mixed_reachability_filtering)

    linker_pnp_matrix = name + "_linker_pnp_matrix_test"
    _linker_pnp_matrix_test(
        name = linker_pnp_matrix,
        size = "small",
    )
    tests.append(":" + linker_pnp_matrix)

    source_schema_rejection = name + "_source_schema_rejection_test"
    _source_schema_rejection_test(
        name = source_schema_rejection,
        size = "small",
    )
    tests.append(":" + source_schema_rejection)

    malformed = name + "_malformed_json_test"
    _failure_case(malformed, "{", "unexpected end of file")
    tests.append(":" + malformed)

    missing_prod_reachable_graph = _graph("berry-v8")
    missing_prod_reachable_graph["packages"][_PACKAGE_KEY].pop("prod_reachable")
    missing_prod_reachable = name + "_missing_prod_reachable_test"
    _failure_case(
        missing_prod_reachable,
        json.encode(missing_prod_reachable_graph),
        "packages[{}] is missing required fields: prod_reachable".format(_PACKAGE_KEY),
    )
    tests.append(":" + missing_prod_reachable)

    contradictory_reachability_graph = _graph("berry-v8")
    contradictory_reachability_graph["packages"][_PACKAGE_KEY]["dev_only"] = True
    contradictory_reachability = name + "_contradictory_reachability_test"
    _failure_case(
        contradictory_reachability,
        json.encode(contradictory_reachability_graph),
        "with prod_reachable=true cannot be dev_only or optional",
    )
    tests.append(":" + contradictory_reachability)

    unknown_graph = _graph("berry-v8")
    unknown_graph["unexpected"] = True
    unknown = name + "_unknown_top_level_field_test"
    _failure_case(
        unknown,
        json.encode(unknown_graph),
        "top-level graph contains unknown fields: unexpected",
    )
    tests.append(":" + unknown)

    unsafe_archive_graph = _graph("berry-v8")
    unsafe_archive_graph["packages"][_PACKAGE_KEY]["resolution"]["archive"] = "../escape.zip"
    unsafe_archive = name + "_unsafe_archive_path_test"
    _failure_case(
        unsafe_archive,
        json.encode(unsafe_archive_graph),
        "resolution.archive escapes the graph repository",
    )
    tests.append(":" + unsafe_archive)

    unknown_reference_graph = _graph("classic-v1")
    unknown_reference_graph["importers"]["."]["dependencies"][_PACKAGE_NAME] = "9.9.9"
    unknown_reference = name + "_unknown_package_reference_test"
    _failure_case(
        unknown_reference,
        json.encode(unknown_reference_graph),
        "resolves to unknown package key left-pad@9.9.9",
    )
    tests.append(":" + unknown_reference)

    unsafe_url_graph = _graph("classic-v1")
    unsafe_url_graph["packages"][_PACKAGE_KEY]["resolution"]["resolved_url"] = (
        "https://registry.yarnpkg.com/left-pad/-/left-pad-1.3.0.tgz?token=secret#" +
        ("d" * 40)
    )
    unsafe_url = name + "_unsafe_classic_url_test"
    _failure_case(
        unsafe_url,
        json.encode(unsafe_url_graph),
        "must be a credential-free HTTPS URL with one SHA-1 fragment",
    )
    tests.append(":" + unsafe_url)

    native.test_suite(
        name = name,
        tests = tests,
    )
