"""Shared actions for materializing npm package archives."""

load("@tar.bzl//tar:tar.bzl", "tar_lib")

NPM_PACKAGE_ARCHIVE_TOOLCHAINS = [tar_lib.toolchain_type]

_EXTRACT_EXECUTION_REQUIREMENTS = {
    "supports-path-mapping": "1",
}

def extract_npm_package_archive(
        ctx,
        src,
        dst,
        archive_format,
        archive_root,
        archive_strip_components,
        exclude_package_contents,
        package,
        version):
    """Extracts a package archive into a declared TreeArtifact."""
    if archive_format not in ["tar", "zip"]:
        fail("Unsupported npm package archive format '{}' for {}@{}".format(
            archive_format,
            package,
            version,
        ))
    if archive_strip_components < 0:
        fail("archive_strip_components must be non-negative for {}@{}".format(package, version))

    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    args = ctx.actions.args()
    args.add_all(
        [
            "--extract",
            "--no-same-owner",
            "--no-same-permissions",
            "--strip-components",
            str(archive_strip_components),
            "--file",
            src,
            "--directory",
            dst,
        ],
        expand_directories = False,
    )
    if exclude_package_contents:
        args.add_all(exclude_package_contents, before_each = "--exclude")
    if archive_root:
        # Include both the root and its descendants explicitly. The descendant
        # pattern also works for ZIPs that omit directory entries, while the
        # slash boundary prevents similarly named siblings from leaking into
        # the package TreeArtifact.
        args.add_all(
            [
                archive_root,
                archive_root + "/*",
            ],
            before_each = "--include",
        )

    ctx.actions.run(
        executable = bsdtar.tarinfo.binary,
        inputs = [src],
        outputs = [dst],
        arguments = [args],
        mnemonic = "NpmPackageExtract",
        progress_message = "Extracting npm package {}@{}".format(package, version),
        execution_requirements = _EXTRACT_EXECUTION_REQUIREMENTS,
        toolchain = Label("@tar.bzl//tar/toolchain:type"),

        # Always override the locale to give better hermeticity.
        # See https://github.com/aspect-build/rules_js/issues/2039
        env = getattr(bsdtar.tarinfo, "default_env", {}),
    )
