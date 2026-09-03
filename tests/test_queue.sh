#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

fixture_snap 260828 010000
fixture_snap 260828 020000
fixture_snap 260829 030000

S1="$SDCARD/snaps/260828/010000_000_65535_P.jpg"
S2="$SDCARD/snaps/260828/020000_000_65535_P.jpg"
S3="$SDCARD/snaps/260829/030000_000_65535_P.jpg"

: > "$STATE_DIR/sent_list.txt"

# --- skip_snaps zapisuje do sent_list.txt ---
REQUESTED_SNAPS=""
n=$(skip_snaps "$S1
$S2")
assert_eq "skip_snaps hlasi pocet" "$n" "2"
assert_contains "prvni cesta je v sent_list" "$(cat "$STATE_DIR/sent_list.txt")" "010000"
assert_contains "druha cesta je v sent_list" "$(cat "$STATE_DIR/sent_list.txt")" "020000"

# --- KLICOVE: vyzadane fotky skip_snaps NESMI zapsat (spec 7.1) ---
: > "$STATE_DIR/sent_list.txt"
REQUESTED_SNAPS="$S1"
n=$(skip_snaps "$S1
$S2")
assert_eq "skip_snaps preskoci jen nevyzadane" "$n" "1"
assert_not_contains "vyzadana fotka se NEDOSTALA do sent_list" \
                    "$(cat "$STATE_DIR/sent_list.txt")" "010000"
assert_contains "nevyzadana fotka do sent_list patri" \
                "$(cat "$STATE_DIR/sent_list.txt")" "020000"

# --- vychozi hodnota MAX_QUEUE ---
assert_eq "MAX_QUEUE ma vychozi hodnotu" "$MAX_QUEUE" "100"

fixture_teardown
finish
