#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture_subprocess.sh"

# =====================================================================
# A: MAX_QUEUE odrizne NEJSTARSI a fronta se vejde pod strop
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=2\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260828 030000
subproc_mk_snap 260829 040000

subproc_run_hunter

sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)
ms=$(cat "$FIX/mailsend.log" 2>/dev/null)

assert_contains "A: log rekl, ze fronta prerostla strop" \
                "$(cat "$HDIR/log.txt")" "fronta pres strop"
assert_not_contains "A: nejstarsi se NEODESLALA" "$ms" "010000"
assert_not_contains "A: druha nejstarsi se NEODESLALA" "$ms" "020000"
assert_contains "A: novejsi se odeslala" "$ms" "030000"
assert_contains "A: nejnovejsi se odeslala" "$ms" "040000"
assert_contains "A: preskocena nejstarsi je v sent_list" "$sl" "010000"
assert_contains "A: preskocena druha je v sent_list" "$sl" "020000"
assert_eq "A: preskocene soubory zustaly na karte" \
          "$([ -f "$SDCARD/snaps/260828/010000_000_65535_P.jpg" ] && echo ano)" "ano"

subproc_fixture_teardown

# =====================================================================
# B: pod stropem se neodrezava nic
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=100\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260829 020000

subproc_run_hunter

assert_not_contains "B: pod stropem se o odrezavani vubec nemluvi" \
                    "$(cat "$HDIR/log.txt")" "fronta pres strop"

subproc_fixture_teardown
finish
