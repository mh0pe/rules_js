# Yarn lockfile integration tests

Bzlmod generates normalized graphs directly from checked Yarn Classic v1,
Berry v9, and Berry v10 lockfiles with checksum-pinned Yarn runtimes. The Berry
v9 lock is genuinely produced by Yarn 4.14.1 and exported by the reviewed Yarn
4.18.0 runtime. The tests consume each cleaned graph repository, extract its
verified cache archive, link the package and bin into the caller workspace, and
run the linked package.

Six real Berry v10 projects cover PnP strict and loose modes, fallback modes
`none` and `all`, `node-modules`, and `pnpm`. Classic and Berry producer
outputs also prove `no_dev`, `no_optional`, and combined reachability filters.
