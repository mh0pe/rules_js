"""Analysis test for generated repository output hygiene."""

def _output_hygiene_test_impl(ctx):
    if ctx.files.target:
        fail(
            "generated Yarn graph repository retained unexpected files: {}".format(
                ", ".join([file.short_path for file in ctx.files.target]),
            ),
        )
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = executable,
        content = "#!/bin/sh\nexit 0\n",
        is_executable = True,
    )
    return [DefaultInfo(executable = executable)]

output_hygiene_test = rule(
    implementation = _output_hygiene_test_impl,
    attrs = {
        "target": attr.label(
            allow_files = True,
            mandatory = True,
        ),
    },
    test = True,
)
