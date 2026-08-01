#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

bazel_bin="$(command -v bazel)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir "$test_root/path-a" "$test_root/path-b"

path_a="$test_root/path-a:${PATH:-}"
path_b="$test_root/path-b:${PATH:-}"
repo_target="@generated-yarn-graph//:yarn_graph.json"

PATH="$path_a" "$bazel_bin" query "$repo_target" >"$test_root/baseline.log" 2>&1
output_base="$(PATH="$path_a" "$bazel_bin" info output_base)"
server_pid="$(PATH="$path_a" "$bazel_bin" info server_pid)"

shopt -s nullglob
markers=("$output_base"/external/@*yarn_lock*generated-yarn-graph.marker)
if [[ ${#markers[@]} -ne 1 ]]; then
    echo "ERROR: expected exactly one generated-yarn-graph repository marker, found ${#markers[@]}"
    exit 1
fi
marker="${markers[0]}"
canonical_repo="${marker##*/}"
canonical_repo="${canonical_repo#@}"
canonical_repo="${canonical_repo%.marker}"
repo_dir="$output_base/external/$canonical_repo"
graph="$repo_dir/yarn_graph.json"

if [[ ! -f "$graph" ]]; then
    echo "ERROR: expected generated graph at $graph"
    exit 1
fi

mtime() {
    if [[ "$(uname)" == Darwin ]]; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}

marker_before="$(cksum "$marker")"
marker_mtime_before="$(mtime "$marker")"
graph_before="$(cksum "$graph")"
archive_count_before="$(find "$repo_dir/archives" -type f | wc -l | tr -d ' ')"

# Negative control: PATH changes on the same Bazel server must not refetch.
PATH="$path_b" "$bazel_bin" query "$repo_target" >"$test_root/path-variation.log" 2>&1
if [[ "$(PATH="$path_b" "$bazel_bin" info server_pid)" != "$server_pid" ]]; then
    echo "ERROR: Bazel server changed during PATH negative control"
    exit 1
fi
if [[ "$(cksum "$marker")" != "$marker_before" || "$(mtime "$marker")" != "$marker_mtime_before" ]]; then
    echo "ERROR: PATH variation refetched generated-yarn-graph"
    exit 1
fi
if [[ "$(cksum "$graph")" != "$graph_before" ]]; then
    echo "ERROR: PATH variation changed yarn_graph.json"
    exit 1
fi
if [[ "$(find "$repo_dir/archives" -type f | wc -l | tr -d ' ')" != "$archive_count_before" ]]; then
    echo "ERROR: PATH variation changed the verified archive inventory"
    exit 1
fi

# Positive control: a declared, harmless proxy-bypass change must invalidate the
# same repository marker, proving the negative control observes a live key.
control_no_proxy="${NO_PROXY:+$NO_PROXY,}rules-js-path-control.invalid"
NO_PROXY="$control_no_proxy" PATH="$path_b" "$bazel_bin" query "$repo_target" >"$test_root/declared-env-control.log" 2>&1
if [[ "$(PATH="$path_b" "$bazel_bin" info server_pid)" != "$server_pid" ]]; then
    echo "ERROR: Bazel server changed during declared-environment positive control"
    exit 1
fi
if [[ "$(cksum "$marker")" == "$marker_before" ]]; then
    echo "ERROR: declared NO_PROXY variation did not invalidate generated-yarn-graph"
    exit 1
fi
if [[ "$(cksum "$graph")" != "$graph_before" ]]; then
    echo "ERROR: declared NO_PROXY variation changed yarn_graph.json"
    exit 1
fi
if [[ "$(find "$repo_dir/archives" -type f | wc -l | tr -d ' ')" != "$archive_count_before" ]]; then
    echo "ERROR: declared NO_PROXY variation changed the verified archive inventory"
    exit 1
fi

echo "YARN_PATH_CACHE_CONTROL PASS server_pid=$server_pid archives=$archive_count_before"
