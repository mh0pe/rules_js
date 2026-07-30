"""Analysis test for archive-backed npm package store actions."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _npm_package_archive_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    extract_actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "NpmPackageExtract"
    ]

    asserts.equals(env, 1, len(extract_actions), "expected exactly one npm package archive extraction action")
    if len(extract_actions) != 1:
        return analysistest.end(env)

    action = extract_actions[0]
    inputs = action.inputs.to_list()
    archive_inputs = [
        input
        for input in inputs
        if input.basename.endswith(".tgz") or input.basename.endswith(".zip")
    ]
    asserts.equals(env, 1, len(archive_inputs), "expected exactly one archive action input")
    if len(archive_inputs) == 1:
        archive = archive_inputs[0]
        asserts.equals(env, ctx.attr.expected_archive_basename, archive.basename)
        asserts.true(env, archive.is_source, "expected the retained archive to be a source artifact")
        asserts.false(env, archive.is_directory, "expected the retained archive to be a file")

    source_directories = [
        input
        for input in inputs
        if input.is_source and input.is_directory
    ]
    asserts.equals(env, [], source_directories, "source directories must not reach the extraction action")

    outputs = action.outputs.to_list()
    asserts.equals(env, 1, len(outputs), "expected exactly one extraction output")
    if len(outputs) == 1:
        asserts.true(env, outputs[0].is_directory, "expected the extraction output to be a TreeArtifact")

    return analysistest.end(env)

_npm_package_archive_action_test = analysistest.make(
    _npm_package_archive_action_test_impl,
    attrs = {
        "expected_archive_basename": attr.string(mandatory = True),
    },
)

def npm_package_archive_action_test(name, target_under_test, expected_archive_basename):
    """Instantiates an archive-backed npm package store analysis test."""
    _npm_package_archive_action_test(
        name = name,
        expected_archive_basename = expected_archive_basename,
        target_under_test = target_under_test,
    )
