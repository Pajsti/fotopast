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

# --- IMAP_REPLY_FOLDER: prazdna spadne na IMAP_SAVE_FOLDER ---
SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER="Fotopast"; IMAP_REPLY_FOLDER=""
validate_transport
assert_eq "prazdny IMAP_REPLY_FOLDER pouzije IMAP_SAVE_FOLDER" \
    "$IMAP_REPLY_FOLDER" "Fotopast"

# --- IMAP_REPLY_FOLDER: vlastni hodnota projde ---
SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER="Fotopast"; IMAP_REPLY_FOLDER="Odpovedi"
validate_transport
assert_eq "vlastni IMAP_REPLY_FOLDER projde" "$IMAP_REPLY_FOLDER" "Odpovedi"

# --- IMAP_REPLY_FOLDER: INBOX se odmita a spadne na IMAP_SAVE_FOLDER ---
SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER="Fotopast"; IMAP_REPLY_FOLDER="InBoX"
validate_transport
assert_eq "INBOX v IMAP_REPLY_FOLDER se odmita" "$IMAP_REPLY_FOLDER" "Fotopast"


# --- dispecer ---
# Falesne transporty: misto binarek jen zapisuji, ze byly zavolany, a
# vraci navratovy kod z promenne. Testuje se rozhodovani, ne odesilani.
SMTP_CALLS=""; IMAP_CALLS=""; IMAP_FOLDER_CALLS=""
SMTP_RC=0; IMAP_RC=0
send_via_smtp() { SMTP_CALLS="$SMTP_CALLS smtp"; return "$SMTP_RC"; }
send_via_imap() {
    IMAP_CALLS="$IMAP_CALLS imap"
    IMAP_FOLDER_CALLS="$IMAP_FOLDER_CALLS $1"
    return "$IMAP_RC"
}

reset_calls() {
    SMTP_CALLS=""; IMAP_CALLS=""; IMAP_FOLDER_CALLS=""
    SMTP_RC=0; IMAP_RC=0
}

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

# imap: 5. parametr (slozka) se preda do send_via_imap beze zmeny -
# send_snap posila IMAP_SAVE_FOLDER, send_reply_mail IMAP_REPLY_FOLDER,
# send_message samo o sobe zadnou slozku nevybira
reset_calls; SEND_TRANSPORT=imap
send_message "a@b.c" "predmet" "telo" "" "Vlastni/Slozka" && r=0 || r=1
assert_eq "imap: slozka se preda do send_via_imap" "$IMAP_FOLDER_CALLS" " Vlastni/Slozka"

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

# --- fotky a odpovedi jdou do ruznych IMAP slozek (bounded design 2026-09-21) ---
# Fotka pouziva IMAP_SAVE_FOLDER, odpoved IMAP_REPLY_FOLDER - i kdyz
# jsou nastavene na ruzne hodnoty, kazda skonci ve sve slozce.
reset_calls
SEND_TRANSPORT=imap; IMAP_SAVE_FOLDER="Fotopast"; IMAP_REPLY_FOLDER="Prikazy"
send_snap "/tmp/mnt/sdcard/snaps/260921/120000_000_65535_N.jpg" >/dev/null 2>&1
assert_eq "fotka pres imap: slozka Fotopast" "$IMAP_FOLDER_CALLS" " Fotopast"

reset_calls
SEND_TRANSPORT=imap; IMAP_SAVE_FOLDER="Fotopast"; IMAP_REPLY_FOLDER="Prikazy"
send_reply_mail "a@b.c" "BAT:74%" >/dev/null 2>&1
assert_eq "odpoved pres imap: slozka Prikazy" "$IMAP_FOLDER_CALLS" " Prikazy"

# --- prazdny IMAP_REPLY_FOLDER: odpoved skonci ve stejne slozce jako fotky ---
# Fallback na IMAP_SAVE_FOLDER dela validate_transport (viz testy vyse) -
# zavola se tu rucne, protoze mimo load_config nebehala sama.
reset_calls
SEND_TRANSPORT=imap; IMAP_SAVE_FOLDER="Fotopast"; IMAP_REPLY_FOLDER=""
validate_transport
send_reply_mail "a@b.c" "BAT:74%" >/dev/null 2>&1
assert_eq "prazdny IMAP_REPLY_FOLDER: odpoved do Fotopast" "$IMAP_FOLDER_CALLS" " Fotopast"

fixture_teardown
finish
