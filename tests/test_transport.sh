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


# --- dispecer ---
# Falesne transporty: misto binarek jen zapisuji, ze byly zavolany, a
# vraci navratovy kod z promenne. Testuje se rozhodovani, ne odesilani.
SMTP_CALLS=""; IMAP_CALLS=""
SMTP_RC=0; IMAP_RC=0
send_via_smtp() { SMTP_CALLS="$SMTP_CALLS smtp"; return "$SMTP_RC"; }
send_via_imap() { IMAP_CALLS="$IMAP_CALLS imap"; return "$IMAP_RC"; }

reset_calls() { SMTP_CALLS=""; IMAP_CALLS=""; SMTP_RC=0; IMAP_RC=0; }

# smtp: jen SMTP
reset_calls; SEND_TRANSPORT=smtp
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp: uspech" "$r" "0"
assert_eq "smtp: volan SMTP" "$SMTP_CALLS" " smtp"
assert_eq "smtp: IMAP nevolan" "$IMAP_CALLS" ""

# imap: jen IMAP
reset_calls; SEND_TRANSPORT=imap
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "imap: uspech" "$r" "0"
assert_eq "imap: SMTP nevolan" "$SMTP_CALLS" ""
assert_eq "imap: volan IMAP" "$IMAP_CALLS" " imap"

# smtp-imap: kdyz SMTP projde, IMAP se NEvola
reset_calls; SEND_TRANSPORT=smtp-imap
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp-imap pri uspechu: uspech" "$r" "0"
assert_eq "smtp-imap pri uspechu: IMAP nevolan" "$IMAP_CALLS" ""

# smtp-imap: kdyz SMTP selze, pouzije se IMAP
reset_calls; SEND_TRANSPORT=smtp-imap; SMTP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp-imap pri selhani: uspech pres IMAP" "$r" "0"
assert_eq "smtp-imap pri selhani: IMAP volan" "$IMAP_CALLS" " imap"

# smtp-imap: kdyz selzou oba, selhani
reset_calls; SEND_TRANSPORT=smtp-imap; SMTP_RC=1; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp-imap oba selhaly: selhani" "$r" "1"

# imap-smtp: obracene poradi
reset_calls; SEND_TRANSPORT=imap-smtp; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "imap-smtp pri selhani IMAP: uspech pres SMTP" "$r" "0"
assert_eq "imap-smtp: SMTP volan" "$SMTP_CALLS" " smtp"

# smtp+imap: oba vzdy
reset_calls; SEND_TRANSPORT=smtp+imap
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp+imap: uspech" "$r" "0"
assert_eq "smtp+imap: volan SMTP" "$SMTP_CALLS" " smtp"
assert_eq "smtp+imap: volan IMAP" "$IMAP_CALLS" " imap"

# smtp+imap: uspech SMTP a selhani IMAP se PORAD pocita za odeslane -
# jinak by vypadek IMAPu poslal fotku, kterou uzivatel uz ma, znovu a
# znovu (spec 4.1)
reset_calls; SEND_TRANSPORT=smtp+imap; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp+imap: staci jeden uspech" "$r" "0"
assert_eq "smtp+imap: presto se zkusily oba" "$IMAP_CALLS" " imap"

# smtp+imap: oba selhaly
reset_calls; SEND_TRANSPORT=smtp+imap; SMTP_RC=1; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp+imap oba selhaly: selhani" "$r" "1"

# --- odpovedi na prikazy jdou stejnym kanalem jako fotky (spec 3) ---
# Kdyby send_reply_mail volalo mailsend primo, nastaveni by se rozeslo
# na dve poloviny a pri zablokovanem SMTP by uzivatel neprisel jen o
# fotky, ale i o zpetnou vazbu, jestli prikaz vubec probehl.
reset_calls; SEND_TRANSPORT=imap
send_reply_mail "a@b.c" "BAT:74%" && r=0 || r=1
assert_eq "odpoved pri imap: uspech" "$r" "0"
assert_eq "odpoved pri imap: SMTP nevolan" "$SMTP_CALLS" ""
assert_eq "odpoved pri imap: volan IMAP" "$IMAP_CALLS" " imap"

reset_calls; SEND_TRANSPORT=smtp
send_reply_mail "a@b.c" "BAT:74%" && r=0 || r=1
assert_eq "odpoved pri smtp: volan SMTP" "$SMTP_CALLS" " smtp"
assert_eq "odpoved pri smtp: IMAP nevolan" "$IMAP_CALLS" ""

fixture_teardown
finish
