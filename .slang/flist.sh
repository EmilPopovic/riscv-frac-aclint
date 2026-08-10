#!/usr/bin/env sh
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1

if ! bender script flist-plus -t src -t synthesis; then
    echo "$0: bender failed" >&2
fi

echo "$root/test/aclint_tb.sv"
