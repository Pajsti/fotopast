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

# --- MAX_QUEUE: preklep (necislo) spadne na vychozich 100 (Finding 3) ---
# Rucne psana hodnota na zive karte (CHECKLIST faze 9) je nachylna k
# preklepu - bez pojistky by "[ "$MAX_QUEUE" -gt 0 ]" v hunter.sh
# skoncilo shellovou chybou na nesledovany stderr a strop by tise
# prestal platit.
printf 'MAX_QUEUE=1OO\n' >> "$CONFIG_FILE"
load_config
assert_eq "MAX_QUEUE preklep (1OO) spadne na vychozich 100" "$MAX_QUEUE" "100"

# --- MAX_QUEUE: vedouci nula je dvojznacna ([ ] cte 010 jako 10,
# $(( )) jako osmickove 8) - taky spadne na vychozich 100 ---
printf 'MAX_QUEUE=010\n' >> "$CONFIG_FILE"
load_config
assert_eq "MAX_QUEUE s vedouci nulou (010) spadne na vychozich 100" "$MAX_QUEUE" "100"

# --- MAX_QUEUE=0 (bez omezeni) zustava platna hodnota, i kdyz je to
# jen jedna cislice ---
printf 'MAX_QUEUE=0\n' >> "$CONFIG_FILE"
load_config
assert_eq "MAX_QUEUE=0 zustava 0 (bez omezeni)" "$MAX_QUEUE" "0"

# --- platna hodnota se pouzije beze zmeny ---
printf 'MAX_QUEUE=250\n' >> "$CONFIG_FILE"
load_config
assert_eq "platna hodnota MAX_QUEUE se respektuje" "$MAX_QUEUE" "250"

# =====================================================================
# CLEAR QUEUE (spec 2026-09-02, sekce 5)
# =====================================================================

# --- prikaz jen nastavi priznak, sam nic nemaze ani nezapisuje ---
: > "$STATE_DIR/sent_list.txt"
CLEAR_QUEUE_REQUESTED=0
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "CLEAR QUEUE" 1
assert_eq "CLEAR QUEUE odpovida bez poctu" "$CMD_REPLY" "QUEUE CLEARED"
assert_eq "CLEAR QUEUE nastavil priznak" "$CLEAR_QUEUE_REQUESTED" "1"
assert_eq "CLEAR QUEUE sam nic nezapsal do sent_list" \
          "$(cat "$STATE_DIR/sent_list.txt")" ""
assert_eq "CLEAR QUEUE nesmazal zadny soubor" "$([ -f "$S1" ] && echo ano)" "ano"

# --- funguje i bez tokenu (nemeni opravneni, stejne jako WIPE) ---
CLEAR_QUEUE_REQUESTED=0
CMD_REPLY=""
execute_command "CLEAR QUEUE" 0
assert_eq "CLEAR QUEUE nevyzaduje token" "$CMD_REPLY" "QUEUE CLEARED"
assert_eq "a priznak nastavi i bez tokenu" "$CLEAR_QUEUE_REQUESTED" "1"

# --- malymi pismeny taky ---
CLEAR_QUEUE_REQUESTED=0
CMD_REPLY=""
execute_command "clear queue" 1
assert_eq "CLEAR QUEUE je case-insensitive" "$CMD_REPLY" "QUEUE CLEARED"

fixture_teardown
finish
