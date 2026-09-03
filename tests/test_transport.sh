#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# --- vychozi hodnoty ---
assert_eq "vychozi SEND_TRANSPORT je smtp" "$SEND_TRANSPORT" "smtp"
assert_eq "vychozi IMAP_SAVE_FOLDER je Fotopast" "$IMAP_SAVE_FOLDER" "Fotopast"

# --- platne hodnoty projdou beze zmeny ---
for v in smtp imap smtp-imap imap-smtp smtp+imap; do
    SEND_TRANSPORT="$v"; IMAP_HOST="imap.example.com"
    validate_transport
    assert_eq "platna hodnota $v se nemeni" "$SEND_TRANSPORT" "$v"
done

# --- neznama hodnota spadne na smtp ---
SEND_TRANSPORT="posta"; IMAP_HOST="imap.example.com"
validate_transport
assert_eq "neznama hodnota spadne na smtp" "$SEND_TRANSPORT" "smtp"

SEND_TRANSPORT=""; IMAP_HOST="imap.example.com"
validate_transport
assert_eq "prazdna hodnota spadne na smtp" "$SEND_TRANSPORT" "smtp"

# --- IMAP rezim bez IMAP_HOST spadne na smtp ---
SEND_TRANSPORT="imap"; IMAP_HOST=""
validate_transport
assert_eq "imap bez IMAP_HOST spadne na smtp" "$SEND_TRANSPORT" "smtp"

SEND_TRANSPORT="smtp-imap"; IMAP_HOST=""
validate_transport
assert_eq "smtp-imap bez IMAP_HOST spadne na smtp" "$SEND_TRANSPORT" "smtp"

# --- smtp bez IMAP_HOST je v poradku, IMAP nepotrebuje ---
SEND_TRANSPORT="smtp"; IMAP_HOST=""
validate_transport
assert_eq "smtp bez IMAP_HOST zustava smtp" "$SEND_TRANSPORT" "smtp"

# --- INBOX se odmita, at je napsany jakkoli ---
IMAP_HOST="imap.example.com"
for f in INBOX inbox InBoX; do
    SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER="$f"
    validate_transport
    assert_eq "slozka $f se odmita" "$IMAP_SAVE_FOLDER" "Fotopast"
done

# --- prazdna slozka spadne na vychozi ---
SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER=""
validate_transport
assert_eq "prazdna slozka spadne na Fotopast" "$IMAP_SAVE_FOLDER" "Fotopast"

# --- jina slozka projde ---
SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER="Archiv/Fotopast"
validate_transport
assert_eq "vlastni slozka projde" "$IMAP_SAVE_FOLDER" "Archiv/Fotopast"

fixture_teardown
finish
