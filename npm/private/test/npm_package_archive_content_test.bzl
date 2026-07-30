"""Runtime parity test for archive-backed npm package stores."""

load("//js:defs.bzl", _js_test = "js_test")
load("//js:libs.bzl", "js_run_binary_action")
load("//npm/private:npm_package_info.bzl", "NpmPackageInfo")
load("//npm/private:npm_package_store.bzl", "npm_package_store")
load("//npm/private:utils.bzl", "utils")

def _npm_package_archive_fixture_impl(ctx):
    fixture_root = ctx.label.name + "_root/node_modules/archive-fixture"
    archive = ctx.actions.declare_file(ctx.label.name + ".tar")
    archive_root = "{}/{}".format(ctx.label.package, fixture_root)
    args = ctx.actions.args()
    args.add(archive.short_path)
    args.add(archive_root)
    js_run_binary_action(
        ctx,
        executable = ctx.executable._generator,
        outputs = [archive],
        arguments = [args],
        mnemonic = "NpmPackageArchiveFixture",
    )

    return [
        DefaultInfo(files = depset([archive])),
        NpmPackageInfo(
            archive_format = "tar",
            archive_root = archive_root,
            archive_strip_components = len(archive_root.split("/")),
            package = "archive-fixture",
            version = "1.0.0",
            src = archive,
            npm_package_store_infos = depset(),
        ),
    ]

_npm_package_archive_fixture = rule(
    implementation = _npm_package_archive_fixture_impl,
    attrs = {
        "_generator": attr.label(
            default = Label("//npm/private/test:npm_package_archive_fixture_generator"),
            executable = True,
            cfg = "exec",
        ),
    },
    provides = [DefaultInfo, NpmPackageInfo],
)

def _npm_package_archive_content_validation_impl(ctx):
    sources = ctx.attr.src[DefaultInfo].files.to_list()
    if len(sources) != 1 or not sources[0].is_directory:
        fail("expected one extracted package TreeArtifact")

    src = sources[0]
    stamp = ctx.actions.declare_file(ctx.label.name + ".validated")
    args = ctx.actions.args()
    args.add(src.short_path)
    args.add(stamp.short_path)
    js_run_binary_action(
        ctx,
        executable = ctx.executable._validator,
        inputs = [src],
        outputs = [stamp],
        arguments = [args],
        mnemonic = "NpmPackageArchiveContentValidation",
    )
    return DefaultInfo(files = depset([stamp]))

_npm_package_archive_content_validation = rule(
    implementation = _npm_package_archive_content_validation_impl,
    attrs = {
        "src": attr.label(mandatory = True),
        "_validator": attr.label(
            default = Label("//npm/private/test:npm_package_archive_content_validator"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def npm_package_archive_content_test(name):
    """Asserts content parity after extracting an archive into a TreeArtifact."""
    fixture_name = name + "_fixture"
    store_name = name + "_store"
    directory_name = name + "_directory"
    validation_name = name + "_validation"
    unix_compatibility = select({
        "@platforms//os:windows": ["@platforms//:incompatible"],
        "//conditions:default": [],
    })

    _npm_package_archive_fixture(
        name = fixture_name,
        target_compatible_with = unix_compatibility,
    )
    npm_package_store(
        name = store_name,
        package = "archive-fixture",
        src = ":" + fixture_name,
        target_compatible_with = unix_compatibility,
        version = "1.0.0",
    )
    native.filegroup(
        name = directory_name,
        srcs = [":" + store_name],
        output_group = utils.package_directory_output_group,
        target_compatible_with = unix_compatibility,
    )
    _npm_package_archive_content_validation(
        name = validation_name,
        src = ":" + directory_name,
        target_compatible_with = unix_compatibility,
    )
    _js_test(
        name = name,
        args = [
            "$(rootpath :{})".format(directory_name),
            "$(rootpath :{})".format(validation_name),
        ],
        data = [
            ":" + directory_name,
            ":" + validation_name,
        ],
        entry_point = "//npm/private/test:npm_package_archive_content_test.js",
        size = "small",
        target_compatible_with = unix_compatibility,
    )
