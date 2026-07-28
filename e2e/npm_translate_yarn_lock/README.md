# Yarn lockfile integration tests

The Bzlmod test generates `pnpm-lock.yaml` from the checked Yarn lockfile inside
Bazel's external repository cache, then passes that generated label to
`npm_translate_lock`. This path exercises the documented pnpm 10 support. The
WORKSPACE test continues to exercise the legacy `yarn_lock` and
`update_pnpm_lock` attributes.
