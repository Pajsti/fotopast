#!/bin/sh
# tests/test_log_error.sh - log_error() ukladani chyb pres IMAP APPEND.
#
# 2026-09-22: uzivatel chtel, aby se pri chybe (chybejici config,
# selhani odeslani...) poslalo hlaseni do vyhrazene IMAP slozky, mimo
# obvyklou cestu fotek/odpovedi. Bez limitu na pocet - kazdy vyskyt se
# hlasi znovu, i kdyz je stejny jako minule (rozhodnuti uzivatele).
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# Falesny mailrecv_run: misto skutecneho binarky jen zapisuje, ze byl
# zavolany, a s jakymi argumenty pro append.
MAILRECV_CALLS=""
MAILRECV_FOLDER=""
MAILRECV_BODY=""
mailrecv_run() {
    MAILRECV_CALLS="$MAILRECV_CALLS 1"
    if [ "$1" = "append" ]; then
        MAILRECV_FOLDER="$2"
        shift 2
        while [ $# -gt 0 ]; do
            case "$1" in
                --body) MAILRECV_BODY="$2" ;;
            esac
            shift
        done
    fi
    return 0
}

reset_calls() { MAILRECV_CALLS=""; MAILRECV_FOLDER=""; MAILRECV_BODY=""; }

# --- vychozi: IMAP_ERROR_FOLDER prazdny, log_error nikdy nevola IMAP ---
reset_calls
IMAP_ERROR_FOLDER=""
log_error "test chyba 1"
assert_eq "vychozi (vypnuto): IMAP se nevola" "$MAILRECV_CALLS" ""
assert_contains "vychozi (vypnuto): zprava je v log.txt" \
    "$(cat "$LOG_FILE")" "test chyba 1"

# --- IMAP_ERROR_FOLDER nastaveny, ale IMAP_HOST prazdny: preskoci se ---
reset_calls
IMAP_ERROR_FOLDER="Errors"; IMAP_HOST=""
log_error "test chyba 2"
assert_eq "bez IMAP_HOST: IMAP se nevola" "$MAILRECV_CALLS" ""

# --- oboji nastaveno: IMAP se zavola se spravnou slozkou a telem ---
reset_calls
IMAP_ERROR_FOLDER="Errors"; IMAP_HOST="imap.example.cz"
log_error "test chyba 3"
assert_eq "oboji nastaveno: IMAP se zavola" "$MAILRECV_CALLS" " 1"
assert_eq "oboji nastaveno: slozka Errors" "$MAILRECV_FOLDER" "Errors"
assert_eq "oboji nastaveno: telo obsahuje hlaseni" "$MAILRECV_BODY" "test chyba 3"

# --- kazdy vyskyt se posila znovu, zadny limit ---
reset_calls
IMAP_ERROR_FOLDER="Errors"; IMAP_HOST="imap.example.cz"
log_error "opakovana chyba"
log_error "opakovana chyba"
log_error "opakovana chyba"
assert_eq "bez limitu: 3x stejna chyba = 3 volani" "$MAILRECV_CALLS" " 1 1 1"

# --- INBOX se odmita uz ve validate_transport, funkce se vypne ---
reset_calls
SEND_TRANSPORT="smtp"; IMAP_HOST="imap.example.cz"
IMAP_SAVE_FOLDER="Fotopast"; IMAP_REPLY_FOLDER="Fotopast"
IMAP_ERROR_FOLDER="InBoX"
validate_transport
assert_eq "INBOX v IMAP_ERROR_FOLDER se vypne" "$IMAP_ERROR_FOLDER" ""
log_error "test chyba 4"
assert_eq "po vypnuti INBOXem: IMAP se nevola" "$MAILRECV_CALLS" ""

fixture_teardown
finish
