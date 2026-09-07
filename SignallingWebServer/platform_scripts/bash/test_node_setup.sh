#!/bin/bash
# Copyright Epic Games, Inc. All Rights Reserved.
# Isolated portable Node installation tests; curl/tar are mocked below.
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
. "${SCRIPT_DIR}/common.sh"

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/sw-bash-node-XXXXXX") || exit 1
NODE_VERSION=v22.23.2
test_node_name="node-${NODE_VERSION}-linux-x64"

fail() { echo "FAIL: $*" >&2; exit 1; }
make_node() {
    mkdir -p "$1/bin" || return 1
    printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$2" > "$1/bin/node"
    chmod +x "$1/bin/node"
}
curl() {
    [[ "$test_download_failure" == 1 ]] && return 1
    local output=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --output ]]; then shift; output="$1"; fi
        shift
    done
    [[ "$output" == "$SCRIPT_DIR"/node-backup-download-*/node.tar.gz ]] || return 1
    : > "$output"
}
tar() {
    local target=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -C ]]; then shift; target="$1"; fi
        shift
    done
    [[ "$target" == "$SCRIPT_DIR"/node-backup-download-* ]] || return 1
    make_node "$target/$test_node_name" "$test_downloaded_version"
}

for scenario in upgrade bad-version download-failure; do
    SCRIPT_DIR="$fixture_root/$scenario with spaces"
    mkdir -p "$SCRIPT_DIR" || fail 'Could not create fixture.'
    make_node "$SCRIPT_DIR/node" v22.14.0 || fail 'Could not create old Node.'
    test_download_failure=0
    test_downloaded_version="$NODE_VERSION"
    [[ "$scenario" == bad-version ]] && test_downloaded_version=v22.14.0
    [[ "$scenario" == download-failure ]] && test_download_failure=1
    if install_node_runtime "https://example.invalid/$test_node_name.tar.gz"; then
        [[ "$scenario" == upgrade ]] || fail "$scenario unexpectedly succeeded."
        [[ "$("$SCRIPT_DIR/node/bin/node" --version)" == "$NODE_VERSION" ]] || fail 'Old portable Node remained active.'
        backups=("$SCRIPT_DIR"/node-backup-*/node/bin/node)
        [[ ${#backups[@]} == 1 && -f "${backups[0]}" ]] || fail 'Previous Node was not retained.'
        [[ "$("${backups[0]}" --version)" == v22.14.0 ]] || fail 'Previous Node changed.'
        [[ ! -e "$SCRIPT_DIR/node/$test_node_name" ]] || fail 'New Node was nested inside old Node.'
    else
        [[ "$scenario" != upgrade ]] || fail 'Upgrade failed.'
        [[ "$("$SCRIPT_DIR/node/bin/node" --version)" == v22.14.0 ]] || fail "$scenario changed original Node."
    fi
done

# setup must stop before building libraries after a Node setup failure.
setup_node() { return 1; }
setup_libraries() { fail 'Libraries ran after Node setup failed.'; }
if setup; then fail 'setup swallowed a Node setup failure.'; fi

# Only remove the exact generated fixture, with its expected temporary prefix.
case "$fixture_root" in
    "${TMPDIR:-/tmp}"/sw-bash-node-*) rm -rf -- "$fixture_root" ;;
    *) fail 'Unexpected cleanup path.' ;;
esac
echo 'Bash Node setup tests passed: exact activation, backup retention, failed download/version and setup failure propagation.'
