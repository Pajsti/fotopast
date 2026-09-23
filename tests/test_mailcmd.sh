#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# fake mailrecv: "list unseen" vrati pripravene radky ze souboru,
# "seen" jen zapise UID do seen.log
cat > "$HUNTER_DIR/bin/mailrecv" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/listing.txt" 2>/dev/null; exit 0 ;;
    seen) shift; echo "\$@" >> "$FIX/seen.log"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$HUNTER_DIR/bin/mailrecv"

# fake mailsend: zapisuje argumenty do sent.log
cat > "$HUNTER_DIR/bin/mailsend" <<EOF
#!/bin/sh
echo "\$@" >> "$FIX/sent.log"
exit 0
EOF
chmod +x "$HUNTER_DIR/bin/mailsend"

ensure_app_frozen() { FROZEN=1; }
FROZEN=0

# --- autorizovany prikaz se vykona a odpovi ---
printf 'UIDVALIDITY|999\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_contains "klic vc. UIDVALIDITY v mail_seen" "$(cat "$STATE_DIR/mail_seen.txt")" "999|101"
assert_contains "oznaceno jako seen"      "$(cat "$FIX/seen.log")" "101"
assert_contains "odpoved odeslana"        "$(cat "$FIX/sent.log")" "HUNTER reply"
assert_eq       "aplikace zmrazena"       "$FROZEN" "1"

# --- odpoved nesmi citovat prichozi predmet (token!) ---
assert_not_contains "odpoved neobsahuje token" "$(cat "$FIX/sent.log")" "tajnytoken1"

# --- zprava bez prefixu se NEDOTKNE ---
printf 'UIDVALIDITY|999\nMSG|202|kdokoli@example.com|Newsletter: sleva 50%%\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_eq "cizi posta se neoznaci prectenou" "$(cat "$FIX/seen.log")" ""
assert_eq "na cizi postu se neodpovida"      "$(cat "$FIX/sent.log")" ""

# --- neautorizovany odesilatel: oznaci se, ale neodpovida ---
printf 'UIDVALIDITY|999\nMSG|303|cizi@example.com|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_contains "neautorizovany se oznaci prectenym" "$(cat "$FIX/seen.log")" "303"
assert_eq       "neautorizovanemu se neodpovida"     "$(cat "$FIX/sent.log")" ""

# --- deduplikace: stejne UID podruhe se nevykona ---
printf 'UIDVALIDITY|999\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 QUALITY LOW\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
QUALITY=HD
process_mail
assert_eq "duplicitni UID se nevykona" "$QUALITY" "HD"
assert_contains "ale oznaci se prectenym" "$(cat "$FIX/seen.log")" "101"

# --- jina UIDVALIDITY = jina schranka, stejne UID se vykona znovu ---
printf 'UIDVALIDITY|1000\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 QUALITY LOW\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
QUALITY=HD
process_mail
assert_eq "po zmene UIDVALIDITY se vykona" "$QUALITY" "LOW"

# --- ADD TOKEN pres mail: nova hodnota tokenu se NIKDY nezaloguje, ale
#     execute_command ji porad dostane a opravdu ji prida ---
printf 'UIDVALIDITY|999\nMSG|404|paja.stindl@seznam.cz|HUNTER tajnytoken1 ADD TOKEN novytoken99\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_contains    "ADD TOKEN se opravdu provede (execute_command dostal neredigovany AUTH_CMD)" "$(cat "$TOKEN_FILE")" "novytoken99"
assert_not_contains "hodnota noveho tokenu se nezaloguje"       "$(cat "$LOG_FILE")" "novytoken99"
assert_contains     "log obsahuje redigovanou znacku ADD TOKEN" "$(cat "$LOG_FILE")" "ADD TOKEN <redacted>"

# --- REMOVE TOKEN pres mail: odebirana hodnota tokenu se NIKDY nezaloguje ---
printf 'UIDVALIDITY|999\nMSG|505|paja.stindl@seznam.cz|HUNTER tajnytoken1 REMOVE TOKEN novytoken99\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_not_contains "novytoken99 opravdu odebran z mail.token"     "$(cat "$TOKEN_FILE")" "novytoken99"
assert_not_contains "hodnota odebirane ho tokenu se nezaloguje"    "$(cat "$LOG_FILE")" "novytoken99"
assert_contains     "log obsahuje redigovanou znacku REMOVE TOKEN" "$(cat "$LOG_FILE")" "REMOVE TOKEN <redacted>"

# --- kontrola, ze sirsi/benevolentnejsi redakce nerozbila normalni
#     pripad: ADD TOKEN s JEDNOU mezerou se porad vykona A redaguje ---
printf 'UIDVALIDITY|999\nMSG|910|paja.stindl@seznam.cz|HUNTER tajnytoken1 ADD TOKEN newtoken1\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
is_valid_token "newtoken1" && VALID=1 || VALID=0
assert_eq           "jedna mezera: token se skutecne prida"            "$VALID" "1"
assert_not_contains "jedna mezera: hodnota tokenu se nezaloguje"       "$(cat "$LOG_FILE")" "newtoken1"
assert_contains     "jedna mezera: log obsahuje redigovanou znacku"    "$(cat "$LOG_FILE")" "ADD TOKEN <redacted>"

# --- regrese: DVOJITA mezera mezi ADD a TOKEN je uzivatelsky preklep,
#     ktery execute_command nerozpozna jako ADD TOKEN (spadne do
#     obecneho ADD handleru, "ADD: INVALID TARGET", token SE NEPRIDA) -
#     ale AUTH_CMD porad obsahuje hodnotu tokenu jako argument, a ta se
#     NESMI zalogovat ani v tomhle "nerozpoznanem" pripade. Puvodni uzsi
#     case vzor (presne jedna mezera) tohle nechytil - overeno proti
#     realnemu volani, viz oprava v hunter/lib/mailcmd.sh. ---
printf 'UIDVALIDITY|999\nMSG|911|paja.stindl@seznam.cz|HUNTER tajnytoken1 ADD  TOKEN newtoken2\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
is_valid_token "newtoken2" && VALID=1 || VALID=0
assert_eq           "dvoji mezera: prikaz se NEVYKONA (execute_command ADD TOKEN nerozpozna)" "$VALID" "0"
assert_not_contains "dvoji mezera: hodnota tokenu se presto nezaloguje" "$(cat "$LOG_FILE")" "newtoken2"
assert_contains     "dvoji mezera: log obsahuje redigovanou znacku"    "$(cat "$LOG_FILE")" "<redacted>"

# --- ensure_app_frozen se vola AZ PO uspesne autorizaci: v davce se
#     3 zpravami (bez prefixu / neautorizovany odesilatel / legitimni)
#     se smi zmrazit jen 1x ---
FREEZE_COUNT=0
ensure_app_frozen() { FREEZE_COUNT=$((FREEZE_COUNT + 1)); FROZEN=1; }
printf 'UIDVALIDITY|999\nMSG|606|kdokoli@example.com|Newsletter: bez prefixu\nMSG|707|cizi@example.com|HUNTER tajnytoken1 STATUS\nMSG|808|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_eq           "zmrazeni jen 1x v davce s 1 legitimni zpravou ze 3" "$FREEZE_COUNT" "1"
assert_contains     "legitimni zprava oznacena precteno"                "$(cat "$FIX/seen.log")" "808"
assert_contains     "neautorizovany taky oznacen precteno"              "$(cat "$FIX/seen.log")" "707"
assert_not_contains "zprava bez prefixu NENI oznacena precteno"         "$(cat "$FIX/seen.log")" "606"

# =====================================================================
# REZIM SENDER pres CELY process_mail.
#
# Tohle je jediny scenar, ve kterem se AUTH_OK a AUTH_HAS_TOKEN lisi:
# v rezimu SENDER staci k autorizaci odesilatel, takze AUTH_OK=1, ale
# AUTH_HAS_TOKEN zustava 0. Prave tim se overuje SPOJ mezi transportem a
# vykonavacem - ze mailcmd.sh predava execute_command jako druhy
# argument AUTH_HAS_TOKEN, ne AUTH_OK.
#
# V rezimu TOKEN jsou obe promenne pro kazdou vykonanou zpravu shodne,
# takze vsechny ostatni testy v tomhle souboru by prosly uplne stejne i
# s prohozenym argumentem. Kdyby k te zamene doslo, rezim SENDER by
# komukoli, kdo umi podvrhnout hlavicku From, dal ADD TOKEN, AUTH TYPE
# i ADD/REMOVE - a sada by zustala zelena.
# =====================================================================
set_config_value AUTH_TYPE SENDER
AUTH_TYPE=SENDER

# a) privilegovany prikaz od autorizovaneho odesilatele BEZ tokenu
#    musi byt odmitnut az na konci retezu, uvnitr execute_command
printf 'UIDVALIDITY|999\nMSG|920|paja.stindl@seznam.cz|HUNTER ADD TOKEN pokusnytoken9\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
is_valid_token "pokusnytoken9" && V=1 || V=0
assert_eq       "SENDER bez tokenu: ADD TOKEN pres process_mail odmitnuto" "$V" "0"
assert_contains "SENDER bez tokenu: odpoved rekne TOKEN REQUIRED" "$(cat "$FIX/sent.log")" "TOKEN REQUIRED"
assert_contains "SENDER bez tokenu: zprava se presto oznaci prectenou" "$(cat "$FIX/seen.log")" "920"

# b) protejsek: bezny (neprivilegovany) prikaz od tehoz odesilatele se
#    v rezimu SENDER vykonat MA - jinak by test (a) prochazel i tehdy,
#    kdyby se v SENDER rezimu nevykonavalo vubec nic
QUALITY=HD
printf 'UIDVALIDITY|999\nMSG|921|paja.stindl@seznam.cz|HUNTER QUALITY LOW\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_eq "SENDER bez tokenu: bezny prikaz se vykona" "$QUALITY" "LOW"

set_config_value AUTH_TYPE TOKEN
AUTH_TYPE=TOKEN

# =====================================================================
# CA_FILE -> --ca pro mailrecv i mailsend.
#
# Bez --ca je TLS sifrovane, ale identita serveru se NEOVERUJE, takze
# kdokoli v pozici man-in-the-middle si precte heslo do schranky i token
# z predmetu. mailrecv --ca dlouho vubec nemel (mel v kodu natvrdo NULL).
#
# Overuje se OBOJI: ze se pri nastavenem CA_FILE preda, a ze se pri
# prazdnem NEPREDA vubec - prazdny retezec by klient vzal jako cestu k
# souboru a spojeni by skoncilo chybou, takze uz bezici instalace bez CA
# svazku na karte musi fungovat presne jako drive.
# =====================================================================

# fake mailrecv, ktery si navic zapisuje vsechny argumenty
cat > "$HUNTER_DIR/bin/mailrecv" <<EOF
#!/bin/sh
echo "\$@" >> "$FIX/recv_args.log"
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/listing.txt" 2>/dev/null; exit 0 ;;
    seen) shift; echo "\$@" >> "$FIX/seen.log"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$HUNTER_DIR/bin/mailrecv"

CA_FILE=""
printf 'UIDVALIDITY|999\nMSG|930|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"; : > "$FIX/recv_args.log"
process_mail
assert_not_contains "prazdny CA_FILE: mailrecv nedostane --ca" "$(cat "$FIX/recv_args.log")" "--ca"
assert_not_contains "prazdny CA_FILE: mailsend nedostane --ca" "$(cat "$FIX/sent.log")" "--ca"
assert_contains     "prazdny CA_FILE: prikaz se presto vykona" "$(cat "$FIX/seen.log")" "930"

CA_FILE="$HUNTER_DIR/ca-certificates.crt"
printf 'UIDVALIDITY|999\nMSG|931|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"; : > "$FIX/recv_args.log"
process_mail
assert_contains "nastaveny CA_FILE: mailrecv dostane --ca s cestou" \
                "$(cat "$FIX/recv_args.log")" "--ca $CA_FILE"
assert_contains "nastaveny CA_FILE: dostane ho i oznaceni seen (druhe volani)" \
                "$(cat "$FIX/recv_args.log")" "--ca $CA_FILE seen"
assert_contains "nastaveny CA_FILE: mailsend (odpoved) dostane --ca s cestou" \
                "$(cat "$FIX/sent.log")" "--ca $CA_FILE"
CA_FILE=""

# load_config nesmi CA_FILE vyzadovat - vychozi je prazdny
unset CA_FILE
load_config
assert_eq "vychozi CA_FILE je prazdny (klic v configu chybi)" "$CA_FILE" ""

# --- token se nikde nezaloguje (kumulativne za cely beh testu) ---
assert_not_contains "log souboru neobsahuje token" "$(cat "$LOG_FILE")" "tajnytoken1"

fixture_teardown
finish
