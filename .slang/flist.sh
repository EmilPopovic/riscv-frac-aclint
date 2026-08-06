#!/usr/bin/env sh
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1

if ! bender script flist-plus -t src -t synthesis; then
    echo "$0: bender failed; falling back to local RTL only." >&2
    echo "$0: run 'bender checkout' to lint the testbench." >&2
    for f in aclint_reg_pkg frac_tick aclint_core aclint_flat aclint; do
        echo "$root/src/$f.sv"
    done
fi

echo "$root/test/aclint_tb.sv"
