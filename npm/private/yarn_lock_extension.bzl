"""Resolution logic for the yarn_lock Bzlmod extension."""

def resolve_yarn_lock_repositories(modules):
    """Resolves root-owned generated lock repositories.

    Args:
      modules: module_ctx.modules or compatible test doubles.

    Returns:
      A struct with `repositories` and an optional human-readable `error`.
    """
    generated_repositories = {}
    repositories = []

    for mod in modules:
        for attr in mod.tags.generate:
            if not mod.is_root:
                return struct(
                    error = (
                        "Only the root module may register yarn_lock.generate repositories; " +
                        "module '{}' attempted to register '{}'."
                    ).format(mod.name, attr.name),
                    repositories = [],
                )

            previous_module = generated_repositories.get(attr.name)
            if previous_module:
                return struct(
                    error = (
                        "yarn_lock.generate repository name '{}' was registered more than once " +
                        "(by {} and {})."
                    ).format(
                        attr.name,
                        previous_module,
                        mod.name,
                    ),
                    repositories = [],
                )

            generated_repositories[attr.name] = mod.name
            repositories.append(attr)

    return struct(
        error = None,
        repositories = repositories,
    )
