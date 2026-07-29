# Yarn lockfile integration tests

Both Bzlmod and WORKSPACE generate a normalized graph directly from the checked
Yarn Berry lockfile with the checksum-pinned Yarn runtime. The tests consume the
cleaned graph repository, extract its verified cache archive, link the package
and bin into the caller workspace, and run the linked package.
