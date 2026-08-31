#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

fixture_snap 260828 210948
fixture_snap 260828 220000
fixture_snap 260829 080000

count_lines() { printf '%s' "$1" | grep -c . ; }

# --- LAST ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 2" 1
assert_eq "LAST 2 vrati 2 cesty" "$(count_lines "$REQUESTED_SNAPS")" "2"
assert_contains "LAST odpoved" "$CMD_REPLY" "SENDING 2"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 99" 1
assert_eq "LAST nad strop orizne na REQUEST_MAX" \
          "$(count_lines "$REQUESTED_SNAPS")" "3"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST abc" 1
assert_eq "LAST s necislem" "$CMD_REPLY" "LAST: INVALID COUNT"

# --- DATE ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "DATE 260828" 1
assert_eq "DATE vrati fotky z daneho dne" \
          "$(count_lines "$REQUESTED_SNAPS")" "2"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "DATE 999999" 1
assert_eq "DATE bez fotek" "$CMD_REPLY" "DATE: NOT FOUND"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "DATE 26-08-28" 1
assert_eq "DATE spatny format" "$CMD_REPLY" "DATE: INVALID FORMAT"

# --- GET ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET 210948_000_65535_P.jpg" 1
assert_eq "GET vrati 1 cestu" "$(count_lines "$REQUESTED_SNAPS")" "1"
assert_contains "GET odpoved" "$CMD_REPLY" "SENDING 1"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET neexistuje.jpg" 1
assert_eq "GET neexistujici" "$CMD_REPLY" "GET: NOT FOUND"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET ../../etc/passwd" 1
assert_eq "GET s ../ odmitnut" "$CMD_REPLY" "GET: INVALID NAME"
assert_eq "nic se nepridalo" "$REQUESTED_SNAPS" ""

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET /etc/passwd" 1
assert_eq "GET s lomitkem odmitnut" "$CMD_REPLY" "GET: INVALID NAME"

# --- vyzadane fotky obchazeji sent_list ---
printf '%s\n' "$SDCARD/snaps/260828/210948_000_65535_P.jpg" > "$STATE_DIR/sent_list.txt"
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET 210948_000_65535_P.jpg" 1
assert_eq "jiz odeslana fotka se preposle" \
          "$(count_lines "$REQUESTED_SNAPS")" "1"

# =====================================================================
# UTOCNE TESTY (nad ramec briefu) - path traversal pres GET.
#
# Poucne z revizi Tasku 8-9: nestaci overit presne ty dva tvary z
# briefu (../../etc/passwd a /etc/passwd), zkusit i dalsi tvary, kterymi
# by se dalo sahnout mimo snaps/, a explicitne overit, ze REQUESTED_SNAPS
# zustava prazdny (ne jen ze CMD_REPLY "vypada spravne").
# =====================================================================

# --- jen ".." samotne ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET .." 1
assert_eq "GET s holym .. odmitnut" "$CMD_REPLY" "GET: INVALID NAME"
assert_eq "nic se nepridalo (..)" "$REQUESTED_SNAPS" ""

# --- absolutni cesta bez ../ (jen /) na jiny soubor v ramci sdcard ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET /sdcard/HDPIC/260828/210948_000_65535_PH.jpg" 1
assert_eq "GET s absolutni cestou na HDPIC odmitnut" "$CMD_REPLY" "GET: INVALID NAME"
assert_eq "nic se nepridalo (absolutni cesta na HDPIC)" "$REQUESTED_SNAPS" ""

# --- vnorena ../ uprostred jinak platneho jmena ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET 260828/../../../etc/passwd" 1
assert_eq "GET s vnorenym ../ odmitnut" "$CMD_REPLY" "GET: INVALID NAME"
assert_eq "nic se nepridalo (vnorene ../)" "$REQUESTED_SNAPS" ""

# --- URL-encoded lomitko, ale ".." porad LITERALNI (case vzor *..* ho
# chyti bez ohledu na to, co je za nim) ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET ..%2Fetc%2Fpasswd" 1
assert_eq "GET s ..%2F odmitnut (.. je porad literalni)" "$CMD_REPLY" "GET: INVALID NAME"
assert_eq "nic se nepridalo (..%2F)" "$REQUESTED_SNAPS" ""

# --- URL-encoded VCETNE tecek (%2e%2e%2Fetc%2Fpasswd) - tohle case vzor
# */*|*..* NECHYTI (v retezci neni zadna literalni tecka ani lomitko).
# Bezpecne to i tak zustava, protoze:
#   1) find "$SDCARD/snaps" ... jiz OMEZUJE prohledavani na snaps/,
#   2) `-name` porovnava jen basename, ne cestu - pattern s takovymhle
#      obsahem (%, 2, e, f jako obycejne znaky) nikdy nesedne na zadny
#      skutecny soubor.
# Vysledek je tedy proste "nenalezeno", NE prolomeni hranice - k
# zadnemu ctenim mimo snaps/ nedojde, jen se to hlasi jinou hlaskou nez
# u ../. Overujeme obe veci: reply i ze se nic neprida.
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET %2e%2e%2Fetc%2Fpasswd" 1
assert_eq "GET s plne url-encodovanym ../ (case vzor ho nechyti, ale find nic nenajde)" \
          "$CMD_REPLY" "GET: NOT FOUND"
assert_eq "nic se nepridalo (%2e%2e%2F)" "$REQUESTED_SNAPS" ""

# --- prazdny nazev - pres dispatcher execute_command je nedosazitelny
# (trim() orizne koncove mezery, takze "GET " => cmd "GET" nematchne
# vzor "GET "*), ale request_get() sama o sobe musi prazdny vstup
# odmitnout taky - volana primo (napr. budoucim SMS transportem, ktery
# by mohl trimovat jinak) nesmi na prazdnem retezci provest find bez
# -name omezeni.
REQUESTED_SNAPS=""
request_get ""
rc=$?
assert_eq "primy request_get('') vraci 2" "$rc" "2"
assert_eq "primy request_get('') nic neprida" "$REQUESTED_SNAPS" ""

# --- jmeno souboru s mezerou uvnitr - nesmi spadnout, nesmi nic zvenku
# najit (zadny skutecny snimek mezeru v nazvu nema), smi se jen tvarit,
# ze soubor neexistuje ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET 210948_000 65535_P.jpg" 1
assert_eq "GET se jmenem s mezerou: nenalezeno" "$CMD_REPLY" "GET: NOT FOUND"
assert_eq "nic se nepridalo (mezera v jmenu)" "$REQUESTED_SNAPS" ""

# --- POZNAMKA (ne bezpecnostni dira, zaznamenano pro reviewera): "*"
# jako jmeno neobsahuje "/" ani "..", projde case vzorem, a find -name
# "*" tak vrati PRVNI nalezeny soubor v snaps/ - bez znalosti presneho
# jmena. Nejde o path traversal (najdene souboru je porad uvnitr
# snaps/, ne mimo nej) - stejnou fotku by uzivatel dostal i pres LAST 1,
# takze zadne noveho opravneni to nedava. Overujeme jen, ze vysledna
# cesta (pokud nejaka je) zustava uvnitr $SDCARD/snaps.
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET *" 1
case "$REQUESTED_SNAPS" in
    "")                 r=ok ;;
    "$SDCARD/snaps/"*)  r=ok ;;
    *)                  r=OUTSIDE ;;
esac
assert_eq "GET * zustava uvnitr snaps/ (nebo nic nenajde)" "$r" "ok"
assert_not_contains "GET * v kazdem pripade neobsahuje cestu mimo snaps/" "$REQUESTED_SNAPS" "etc/passwd"

fixture_teardown
finish
