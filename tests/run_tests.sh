#!/bin/sh
# tests/run_tests.sh - spusti vsechny tests/test_*.sh pres dash.
#
# dash je zastupce za busybox ash - oba jsou striktne POSIX, takze co
# projde v dash, projde i na zarizeni. Bash by propustil bashismy, ktere
# by na zarizeni spadly.

DIR=$(cd "$(dirname "$0")" && pwd)
PASS=0
FAIL=0

for t in "$DIR"/test_*.sh; do
    printf '== %s\n' "$(basename "$t")"
    if dash "$t"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

printf '\nprosly: %d   selhaly: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
