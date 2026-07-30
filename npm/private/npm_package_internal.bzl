"npm_package_internal rule"

load(":npm_package_info.bzl", "NpmPackageInfo")

_ATTRS = {
    "archive_format": attr.string(
        doc = "Format of src when it is an archive.",
        values = ["", "tar", "zip"],
    ),
    "archive_root": attr.string(
        doc = "Archive path prefix containing the package.",
    ),
    "archive_strip_components": attr.int(
        doc = "Number of leading archive path components to strip.",
    ),
    "src": attr.label(
        doc = "A source directory or output directory to use for this package.",
        allow_single_file = True,
        mandatory = True,
    ),
    "package": attr.string(
        doc = """The package name.""",
        mandatory = True,
    ),
    "version": attr.string(
        doc = """The package version.""",
        mandatory = True,
    ),
}

def _npm_package_internal_impl(ctx):
    if ctx.file.src.is_source or ctx.file.src.is_directory:
        # pass the source archive, source directory or TreeArtifact through
        dst = ctx.file.src
    else:
        fail("Expected src to be a source directory or an output directory")

    if ctx.attr.archive_format:
        if ctx.file.src.is_directory:
            fail("archive_format may only be set when src is an archive file")
        if ctx.attr.archive_strip_components < 0:
            fail("archive_strip_components must be non-negative")
    elif ctx.attr.archive_root or ctx.attr.archive_strip_components:
        fail("archive_root and archive_strip_components require archive_format")

    return [
        DefaultInfo(
            files = depset([dst]),
        ),
        NpmPackageInfo(
            archive_format = ctx.attr.archive_format,
            archive_root = ctx.attr.archive_root,
            archive_strip_components = ctx.attr.archive_strip_components,
            package = ctx.attr.package,
            version = ctx.attr.version,
            src = dst,
            npm_package_store_infos = depset(),
        ),
    ]

npm_package_internal = rule(
    implementation = _npm_package_internal_impl,
    attrs = _ATTRS,
    provides = [DefaultInfo, NpmPackageInfo],
)
