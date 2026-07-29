"""Hermetically downloads an official Yarn CLI release."""

_DEFAULT_YARN_VERSION = "4.5.0"

# Official release metadata from exact @yarnpkg/cli tags, peeled to their
# underlying Yarn Berry commits.
_YARN_RELEASES = {
    "4.5.0": struct(
        bundle_sha256 = "cc00dce5de4f68d11450519a0f69eadf2a1cbe5cc0d8e740bfac817a31d76874",
        licenses = [
            struct(
                output = "LICENSE.yarn.md",
                sha256 = "238d933f5c226cc197bd1dae2ad0c468e157b4cba8ed844f81549ba6db777dc4",
                url = "https://raw.githubusercontent.com/yarnpkg/berry/68e10d099fb6bee03e4450bc516c0c04e24bcb96/LICENSE.md",
            ),
            struct(
                output = "LICENSE.plugin-patch",
                sha256 = "4b1c4702fc655652e3794376a734e1505dee4b297582da2dc1dcc846796db122",
                url = "https://raw.githubusercontent.com/yarnpkg/berry/68e10d099fb6bee03e4450bc516c0c04e24bcb96/packages/plugin-patch/LICENSE",
            ),
        ],
    ),
    "4.18.0": struct(
        bundle_sha256 = "fb8b1d20be72a0b544a35bcec4c7ed0ff55a9b173c01f191b02ba164b2051db5",
        licenses = [
            struct(
                output = "LICENSE.yarn.md",
                sha256 = "238d933f5c226cc197bd1dae2ad0c468e157b4cba8ed844f81549ba6db777dc4",
                url = "https://raw.githubusercontent.com/yarnpkg/berry/923f69827c77fe5cf4f6c28c0cab3c02a256abf0/LICENSE.md",
            ),
            struct(
                output = "LICENSE.plugin-patch",
                sha256 = "4b1c4702fc655652e3794376a734e1505dee4b297582da2dc1dcc846796db122",
                url = "https://raw.githubusercontent.com/yarnpkg/berry/923f69827c77fe5cf4f6c28c0cab3c02a256abf0/packages/plugin-patch/LICENSE",
            ),
        ],
    ),
}

YARN_LICENSE_FILENAMES = [
    "LICENSE.plugin-patch",
    "LICENSE.yarn.md",
]

def resolve_yarn_release(version, sha256 = ""):
    """Returns the reviewed release record for an exact Yarn version.

    Args:
        version: Exact supported Yarn release version.
        sha256: Optional assertion for the reviewed bundle SHA-256.

    Returns:
        The pinned release record.
    """
    release = _YARN_RELEASES.get(version)
    if not release:
        fail(
            "Yarn {} has no complete pinned bundle-and-license release record.".format(
                version,
            ),
        )
    if sha256 and sha256 != release.bundle_sha256:
        fail(
            "Yarn {} bundle SHA-256 override does not match the reviewed release record.".format(
                version,
            ),
        )

    return release

def download_yarn_release(rctx, version, sha256 = "", bundle_output = "yarn.js"):
    """Downloads a reviewed Yarn bundle and its pinned license files.

    Args:
        rctx: Repository context used for downloads.
        version: Exact supported Yarn release version.
        sha256: Optional assertion for the reviewed bundle SHA-256.
        bundle_output: Repository-relative output path for the Yarn bundle.

    Returns:
        The pinned release record after every artifact is downloaded.
    """
    release = resolve_yarn_release(version, sha256)
    rctx.download(
        url = "https://repo.yarnpkg.com/{}/packages/yarnpkg-cli/bin/yarn.js".format(version),
        output = bundle_output,
        sha256 = release.bundle_sha256,
        executable = False,
    )
    for license in release.licenses:
        rctx.download(
            url = license.url,
            output = license.output,
            sha256 = license.sha256,
            executable = False,
        )
    return release

def _yarn_tool_repository_impl(rctx):
    download_yarn_release(
        rctx,
        rctx.attr.version,
        rctx.attr.sha256,
    )
    rctx.file(
        "BUILD.bazel",
        """\
package(default_visibility = ["//visibility:public"])

exports_files([
    "LICENSE.plugin-patch",
    "LICENSE.yarn.md",
    "yarn.js",
])

filegroup(
    name = "licenses",
    srcs = [
        "LICENSE.plugin-patch",
        "LICENSE.yarn.md",
    ],
)
""",
    )

yarn_tool_repository = repository_rule(
    implementation = _yarn_tool_repository_impl,
    attrs = {
        "sha256": attr.string(
            doc = "Optional assertion that must equal the reviewed release SHA-256.",
        ),
        "version": attr.string(
            default = _DEFAULT_YARN_VERSION,
            doc = "Exact official Yarn release version to download.",
        ),
    },
    doc = "Downloads a checksum-pinned official Yarn CLI bundle and its licenses.",
)
