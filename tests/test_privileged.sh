#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# execute_command <prikaz> <ma_platny_token>

# --- WIPE vyzaduje CONFIRM ---
CMD_REPLY=""; execute_command "WIPE" 1
assert_eq "WIPE bez CONFIRM se nevykona" "$CMD_REPLY" "WIPE NEEDS CONFIRM"

printf '%s\n' "$SDCARD/snaps/260828/210948_000_65535_P.jpg" > "$STATE_DIR/sent_list.txt"
fixture_snap 260828 210948
CMD_REPLY=""; execute_command "WIPE CONFIRM" 1
assert_contains "WIPE CONFIRM vykona" "$CMD_REPLY" "WIPE DONE"

# --- WIPE_BATCH: pri prekroceni stropu se hlasi PARTIAL a zbytek ceka ---
# (2026-09-23: zatezovy test namer il ~100 s na 5000 zaznamech, blizko
# RUN_DEADLINE - viz tests/stress_5000.sh a komentar u wipe_sent_snaps)
mkdir -p "$SDCARD/snaps/260829"
: > "$STATE_DIR/sent_list.txt"
i=0
while [ "$i" -lt 5 ]; do
    hh=$(printf '%06d' "$i")
    path="$SDCARD/snaps/260829/${hh}_000_65535_P.jpg"
    printf 'x' > "$path"
    printf '%s\n' "$path" >> "$STATE_DIR/sent_list.txt"
    i=$((i + 1))
done
WIPE_BATCH=2
CMD_REPLY=""; execute_command "WIPE CONFIRM" 1
assert_eq "WIPE_BATCH=2: smaze jen 2" "$WIPE_COUNT" "2"
assert_eq "WIPE_BATCH=2: 3 zbyvaji" "$WIPE_REMAINING" "3"
assert_contains "WIPE_BATCH=2: odpoved je PARTIAL" "$CMD_REPLY" "WIPE PARTIAL"
assert_contains "WIPE_BATCH=2: odpoved hlasi pocet zbylych" "$CMD_REPLY" "3 zbyva"
remaining_lines=$(grep -c . "$STATE_DIR/sent_list.txt")
assert_eq "WIPE_BATCH=2: v sent_list.txt zustaly 3 radky" "$remaining_lines" "3"

# --- druhe WIPE CONFIRM (strop zvednuty) dokonci zbytek ---
WIPE_BATCH=500
CMD_REPLY=""; execute_command "WIPE CONFIRM" 1
assert_eq "druhe WIPE CONFIRM: smaze zbylych 3" "$WIPE_COUNT" "3"
assert_eq "druhe WIPE CONFIRM: nic nezbyva" "$WIPE_REMAINING" "0"
assert_contains "druhe WIPE CONFIRM: odpoved je DONE" "$CMD_REPLY" "WIPE DONE"

# --- privilegovane prikazy vyzaduji token VZDY ---
CMD_REPLY=""; execute_command "AUTH TYPE SENDER" 0
assert_eq "AUTH TYPE bez tokenu" "$CMD_REPLY" "TOKEN REQUIRED"
assert_eq "rezim nezmenen" "$AUTH_TYPE" "TOKEN"

CMD_REPLY=""; execute_command "AUTH TYPE SENDER" 1
assert_eq "AUTH TYPE s tokenem" "$CMD_REPLY" "AUTH TYPE SET TO SENDER"
assert_eq "rezim zmenen" "$AUTH_TYPE" "SENDER"

# mirror predchoziho testu pro opacny smer (TOKEN misto SENDER) - obe
# vetve AUTH TYPE musi kontrolu tokenu vyzadovat nezavisle na sobe.
CMD_REPLY=""; execute_command "AUTH TYPE TOKEN" 0
assert_eq "AUTH TYPE TOKEN bez tokenu" "$CMD_REPLY" "TOKEN REQUIRED"
assert_eq "rezim zustava SENDER" "$AUTH_TYPE" "SENDER"

# --- UTOCNY TEST (vlastni, nad ramec briefu): i v rezimu SENDER musi
# privilegovany prikaz BEZ tokenu selhat. Tohle je hlavni bezpecnostni
# pravidlo celeho tasku - execute_command se pri rozhodovani o
# privilegovanych vetvich nesmi nikdy ptat na AUTH_TYPE, jen na
# has_token, ktery predava volajici (mailcmd.sh) podle toho, jestli
# zprava skutecne nesla platny token, bez ohledu na rezim autorizace.
CMD_REPLY=""; execute_command "ADD utocnik@evil.example" 0
assert_eq "SENDER rezim: ADD bez tokenu porad vyzaduje token" "$CMD_REPLY" "TOKEN REQUIRED"
assert_not_contains "utocnikova adresa se nedostala do configu" "$(cat "$CONFIG_FILE")" "utocnik@evil.example"
assert_not_contains "utocnikova adresa se nedostala do MAIL_MASTERS v pameti" "$MAIL_MASTERS" "utocnik@evil.example"

CMD_REPLY=""; execute_command "ADD TOKEN utocnikuvtoken99" 0
assert_eq "SENDER rezim: ADD TOKEN bez tokenu porad vyzaduje token" "$CMD_REPLY" "TOKEN REQUIRED"
load_tokens
assert_eq "pocet tokenu nezmenen po odmitnutem pokusu" "$TOKEN_COUNT" "1"

CMD_REPLY=""; execute_command "AUTH TYPE TOKEN" 1
assert_eq "navrat do TOKEN" "$AUTH_TYPE" "TOKEN"

CMD_REPLY=""; execute_command "ADD TOKEN novytoken99" 0
assert_eq "ADD TOKEN bez tokenu" "$CMD_REPLY" "TOKEN REQUIRED"
load_tokens
assert_eq "ADD TOKEN bez tokenu nic neprida" "$TOKEN_COUNT" "1"

CMD_REPLY=""; execute_command "ADD TOKEN novytoken99" 1
assert_contains "ADD TOKEN s tokenem" "$CMD_REPLY" "TOKEN ADDED"
assert_not_contains "odpoved neobsahuje hodnotu tokenu" "$CMD_REPLY" "novytoken99"

# mirror "ADD TOKEN bez tokenu" pro REMOVE TOKEN - kontrola tokenu se
# musi vykonat driv, nez se soubor tokenu vubec otevre.
CMD_REPLY=""; execute_command "REMOVE TOKEN novytoken99" 0
assert_eq "REMOVE TOKEN bez tokenu" "$CMD_REPLY" "TOKEN REQUIRED"
load_tokens
assert_eq "REMOVE TOKEN bez tokenu nic neodstrani" "$TOKEN_COUNT" "2"

CMD_REPLY=""; execute_command "REMOVE TOKEN novytoken99" 1
assert_contains "REMOVE TOKEN" "$CMD_REPLY" "TOKEN REMOVED"
assert_not_contains "odpoved REMOVE TOKEN neobsahuje hodnotu tokenu" "$CMD_REPLY" "novytoken99"

# --- UTOCNY TEST: odebrani posledniho tokenu musi byt odmitnuto, i s
# platnym tokenem v pozadavku (jinak by se zarizeni dalo trvale odriznout
# od vzdaleneho ovladani - jediny token, ktery prave zbyva, ho odebira).
CMD_REPLY=""; execute_command "REMOVE TOKEN tajnytoken1" 1
assert_eq "posledni token" "$CMD_REPLY" "CANNOT REMOVE LAST TOKEN"
load_tokens
assert_eq "posledni token opravdu zustal" "$TOKEN_COUNT" "1"
is_valid_token "tajnytoken1" && r=1 || r=0
assert_eq "posledni token je porad platny" "$r" "1"

# --- ADD / REMOVE adres a cisel ---
CMD_REPLY=""; execute_command "ADD novy@example.com" 1
assert_contains "ADD e-mailu" "$CMD_REPLY" "ADDED"
assert_contains "adresa v configu" "$(cat "$CONFIG_FILE")" "novy@example.com"

CMD_REPLY=""; execute_command "REMOVE novy@example.com" 0
assert_eq "REMOVE bez tokenu take vyzaduje token" "$CMD_REPLY" "TOKEN REQUIRED"
assert_contains "adresa porad v configu po odmitnutem REMOVE" "$(cat "$CONFIG_FILE")" "novy@example.com"

CMD_REPLY=""; execute_command "REMOVE novy@example.com" 1
assert_contains "REMOVE e-mailu" "$CMD_REPLY" "REMOVED"
assert_not_contains "adresa pryc z configu" "$(cat "$CONFIG_FILE")" "novy@example.com"

CMD_REPLY=""; execute_command "ADD +420111222333" 1
assert_contains "ADD telefonu" "$CMD_REPLY" "ADDED"
assert_contains "cislo v MASTERS" "$MASTERS" "+420111222333"

CMD_REPLY=""; execute_command "ADD nesmysl" 1
assert_eq "neplatny argument" "$CMD_REPLY" "ADD: INVALID TARGET"

# =====================================================================
# UTOCNE TESTY: vstrikovani do config.txt pres ADD/REMOVE.
#
# config.txt nacita load_config pres `.`, takze cokoli, co se do nej
# zapise, se pri pristim behu VYKONA jako shell. Tvarovy case (+[0-9]* /
# *@*.*) je kontrola TVARU, ne znaku - "e@x.cz;touch /tmp/x" mu vyhovi.
# Proto je pred nim znakovy filtr, ktery se tady overuje: prikaz musi
# skoncit na INVALID TARGET, do configu se nesmi dostat nic, a config
# musi zustat nacitatelny (`.` na nem projde).
# =====================================================================

config_sourceable() {
    ( . "$CONFIG_FILE" ) >/dev/null 2>&1 && printf '1' || printf '0'
}

INJ_MARK="$FIX/pwned"

CMD_REPLY=""; execute_command "ADD a@b.cz;touch $INJ_MARK" 1
assert_eq "ADD s ';' odmitnut" "$CMD_REPLY" "ADD: INVALID TARGET"
assert_not_contains "vstrikovany text se nedostal do configu" "$(cat "$CONFIG_FILE")" "touch"
assert_not_contains "vstrikovany text neni ani v MAIL_MASTERS v pameti" "$MAIL_MASTERS" "touch"
assert_eq "config.txt zustava nacitatelny po pokusu o ';'" "$(config_sourceable)" "1"
# a opravdu nic nespustil (marker by vytvoril `touch` pri sourcovani)
( . "$CONFIG_FILE" ) >/dev/null 2>&1
[ -e "$INJ_MARK" ] && r=1 || r=0
assert_eq "sourcovani configu nic nespustilo" "$r" "0"

# telefonni tvar: "+4;touch ..." projde vzorem +[0-9]* a normalize_phone
# by z nej udelal "+4;touch/tmp/..." - porad spustitelne
CMD_REPLY=""; execute_command "ADD +4;touch $INJ_MARK" 1
assert_eq "ADD telefonniho tvaru s ';' odmitnut" "$CMD_REPLY" "ADD: INVALID TARGET"
assert_not_contains "vstrikovany telefonni text neni v MASTERS" "$MASTERS" "touch"
assert_eq "config.txt nacitatelny i po telefonnim pokusu" "$(config_sourceable)" "1"

# $(...) a backtick - `.` provadi na prave strane prirazeni plnou expanzi
CMD_REPLY=""; execute_command "ADD a@b.cz\$(id)" 1
assert_eq "ADD s \$( ) odmitnut" "$CMD_REPLY" "ADD: INVALID TARGET"
CMD_REPLY=""; execute_command "ADD a@b.cz\`id\`" 1
assert_eq "ADD s backtickem odmitnut" "$CMD_REPLY" "ADD: INVALID TARGET"

# DOSTUPNOST: jedina nesparovana uvozovka trvale rozbije config.txt tak,
# ze uz ho load_config nikdy nenacte - a load_config bezi v hunter.sh
# JESTE PRED instalaci trapu cleanup. Zadny utocnik k tomu neni potreba,
# staci preklep opravneneho uzivatele.
CMD_REPLY=""; execute_command "ADD oops@x.cz'" 1
assert_eq "ADD s uvozovkou odmitnut" "$CMD_REPLY" "ADD: INVALID TARGET"
assert_eq "config.txt nacitatelny i po uvozovce" "$(config_sourceable)" "1"

# REMOVE zapisuje do config.txt take (prepisuje cely radek) - stejny filtr
CMD_REPLY=""; execute_command "REMOVE a@b.cz;touch $INJ_MARK" 1
assert_eq "REMOVE s ';' odmitnut" "$CMD_REPLY" "REMOVE: INVALID TARGET"
assert_eq "config.txt nacitatelny i po pokusu pres REMOVE" "$(config_sourceable)" "1"

# legitimni tvary MUSI porad projit (filtr nesmi byt prisnejsi, nez je
# potreba) - adresa s tagem/pomlckou i cislo s pomlckami
CMD_REPLY=""; execute_command "ADD user+tag@sub.domain-name.co.uk" 1
assert_contains "adresa s '+' a '-' porad projde" "$CMD_REPLY" "ADDED"
assert_contains "a opravdu se zapsala" "$(cat "$CONFIG_FILE")" "user+tag@sub.domain-name.co.uk"
CMD_REPLY=""; execute_command "REMOVE user+tag@sub.domain-name.co.uk" 1
assert_contains "a jde zase odebrat" "$CMD_REPLY" "REMOVED"

CMD_REPLY=""; execute_command "ADD +420-603-284-431" 1
assert_contains "cislo s pomlckami porad projde" "$CMD_REPLY" "ADDED"
assert_contains "cislo se ulozilo normalizovane" "$MASTERS" "+420603284431"

# =====================================================================
# UTOCNE TESTY: odebrani POSLEDNI adresy z MAIL_MASTERS.
#
# Stejna trida chyby jako "posledni token": s prazdnym MAIL_MASTERS
# vrati is_mail_master 1 pro kohokoli, takze authorize_mail selze pro
# vsechny a v OBOU rezimech - a zadny prikaz uz nejde poslat, protoze
# kazdy musi nejdriv projit autorizaci. Zpatky uz jen fyzicky ke karte.
# Navic se drive hlasilo REMOVED i kdyz se nic neodebralo, takze
# operator nemel signal, ze prave udelal neco nevratneho.
# =====================================================================

CMD_REPLY=""; execute_command "ADD druhy@example.com" 1
assert_contains "druha adresa pridana" "$CMD_REPLY" "ADDED"

# neexistujici adresa uz nesmi hlasit uspech
CMD_REPLY=""; execute_command "REMOVE vubec.tam.neni@example.com" 1
assert_contains "REMOVE neexistujici adresy hlasi NOT FOUND" "$CMD_REPLY" "MAIL MASTER NOT FOUND"
assert_contains "seznam adres se nezmenil" "$MAIL_MASTERS" "druhy@example.com"

# predposledni jde odebrat normalne
CMD_REPLY=""; execute_command "REMOVE druhy@example.com" 1
assert_contains "predposledni adresa jde odebrat" "$CMD_REPLY" "REMOVED"
assert_eq "zbyva presne posledni adresa" "$MAIL_MASTERS" "paja.stindl@seznam.cz"

# a ted ta posledni - musi byt odmitnuta
CMD_REPLY=""; execute_command "REMOVE paja.stindl@seznam.cz" 1
assert_eq "posledni adresa se odebrat NESMI" "$CMD_REPLY" "CANNOT REMOVE LAST MAIL MASTER"
assert_eq "posledni adresa opravdu zustala v pameti" "$MAIL_MASTERS" "paja.stindl@seznam.cz"
assert_contains "posledni adresa zustala i v configu" "$(cat "$CONFIG_FILE")" "MAIL_MASTERS=paja.stindl@seznam.cz"
# a kanal je porad ovladatelny: pravoplatny majitel projde autorizaci
authorize_mail "paja.stindl@seznam.cz" "HUNTER tajnytoken1 STATUS"
assert_eq "majitel je po odmitnutem REMOVE porad autorizovan" "$AUTH_OK" "1"

# --- prikazy bez zmeny opravneni token nevyzaduji (zpetna kompatibilita) ---
CMD_REPLY=""; execute_command "QUALITY LOW" 0
assert_eq "QUALITY beze tokenu porad funguje" "$CMD_REPLY" "QUALITY SET TO LOW"

# --- STATUS obsahuje pocet tokenu ---
CMD_REPLY=""; execute_command "STATUS" 1
assert_contains "STATUS ma TOKENS" "$CMD_REPLY" "TOKENS:"

fixture_teardown
finish
