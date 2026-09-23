#!/bin/sh
# tests/test_wipe_continue.sh - WIPE pokracuje sam pres dalsi probuzeni.
#
# 2026-09-23: davkovani po WIPE_BATCH samo o sobe znamenalo, ze uzivatel
# musel poslat WIPE CONFIRM tolikrat, kolik je davek (u 5000 zaznamu
# jedenactkrat). Rozhodnuti uzivatele: jedno potvrzeni ma stacit, dalsi
# davky si ma Hunter odbavit sam pri dalsich probuzenich a na konci
# poslat zpravu, ze je hotovo.
#
# Znacka state/wipe_pending.txt nese adresu toho, kdo WIPE vyzadal -
# bez ni by nebylo komu zaverecnou zpravu poslat.
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

mkdir -p "$SDCARD/snaps/260829"
mk_entries() {
    : > "$STATE_DIR/sent_list.txt"
    i=0
    while [ "$i" -lt "$1" ]; do
        hh=$(printf '%06d' "$i")
        p="$SDCARD/snaps/260829/${hh}_000_65535_P.jpg"
        printf 'x' > "$p"
        printf '%s\n' "$p" >> "$STATE_DIR/sent_list.txt"
        i=$((i + 1))
    done
}

# --- prvni WIPE CONFIRM: zbyva prace -> znacka + "WIPE STARTED" ---
mk_entries 5
WIPE_BATCH=2
wipe_clear_pending
CMD_REPLY=""; WIPE_CONTINUE=0
execute_command "WIPE CONFIRM" 1
assert_eq "prvni davka smazala WIPE_BATCH kusu" "$WIPE_COUNT" "2"
assert_eq "zbyva 3" "$WIPE_REMAINING" "3"
assert_eq "nastaven priznak pro transport" "$WIPE_CONTINUE" "1"
assert_contains "odpoved hlasi zahajeni, ne hotovo" "$CMD_REPLY" "WIPE STARTED"
assert_contains "odpoved rika kolik zbyva" "$CMD_REPLY" "3 zbyva"

# --- transport znacku ulozi i s adresou ---
wipe_mark_pending "pepa@example.cz"
assert_eq "znacka existuje" \
    "$([ -f "$STATE_DIR/wipe_pending.txt" ] && echo ano || echo ne)" "ano"
assert_eq "znacka nese adresu zadatele" "$(wipe_pending_addr)" "pepa@example.cz"

# --- dalsi probuzeni: jedna davka, znacka zustava ---
WIPE_DONE_NOTICE=""
wipe_continue_if_pending
assert_eq "druha davka smazala dalsi dva" "$WIPE_COUNT" "2"
assert_eq "zbyva 1" "$WIPE_REMAINING" "1"
assert_eq "znacka porad je" \
    "$([ -f "$STATE_DIR/wipe_pending.txt" ] && echo ano || echo ne)" "ano"
assert_eq "zaverecna zprava se JESTE neposila" "$WIPE_DONE_NOTICE" ""

# --- posledni davka: znacka pryc + zaverecna zprava ---
WIPE_DONE_NOTICE=""
wipe_continue_if_pending
assert_eq "treti davka domazala zbytek" "$WIPE_COUNT" "1"
assert_eq "nezbyva nic" "$WIPE_REMAINING" "0"
assert_eq "znacka je uklizena" \
    "$([ -f "$STATE_DIR/wipe_pending.txt" ] && echo ano || echo ne)" "ne"
assert_contains "zaverecna zprava hlasi WIPE DONE" "$WIPE_DONE_NOTICE" "WIPE DONE"
assert_eq "sent_list.txt je prazdny" "$(grep -c . "$STATE_DIR/sent_list.txt")" "0"

# --- bez znacky se nemaze nic ---
mk_entries 4
WIPE_COUNT=0
wipe_continue_if_pending
assert_eq "bez znacky se zadna davka nespusti" "$WIPE_COUNT" "0"
assert_eq "zaznamy zustaly netknute" "$(grep -c . "$STATE_DIR/sent_list.txt")" "4"

# --- jedina davka staci -> zadna znacka, rovnou WIPE DONE ---
mk_entries 2
WIPE_BATCH=500
wipe_clear_pending
CMD_REPLY=""; WIPE_CONTINUE=0
execute_command "WIPE CONFIRM" 1
assert_eq "vse smazano najednou" "$WIPE_COUNT" "2"
assert_eq "priznak se nenastavuje" "$WIPE_CONTINUE" "0"
assert_contains "odpoved je rovnou DONE" "$CMD_REPLY" "WIPE DONE"

fixture_teardown
finish
