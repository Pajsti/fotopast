#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# --- rezim TOKEN ---
authorize_mail "paja.stindl@seznam.cz" "HUNTER tajnytoken1 STATUS"
assert_eq "TOKEN: platny token + master"        "$AUTH_OK"  "1"
assert_eq "TOKEN: prikaz bez tokenu"            "$AUTH_CMD" "STATUS"
assert_eq "TOKEN: priznak tokenu"               "$AUTH_HAS_TOKEN" "1"

authorize_mail "cizi@example.com" "HUNTER tajnytoken1 STATUS"
assert_eq "TOKEN: platny token + cizi odesilatel" "$AUTH_OK" "0"

authorize_mail "paja.stindl@seznam.cz" "HUNTER spatnytoken STATUS"
assert_eq "TOKEN: spatny token" "$AUTH_OK" "0"

authorize_mail "paja.stindl@seznam.cz" "HUNTER STATUS"
assert_eq "TOKEN: bez tokenu" "$AUTH_OK" "0"

# --- rezim SENDER ---
set_config_value AUTH_TYPE SENDER
AUTH_TYPE=SENDER

authorize_mail "paja.stindl@seznam.cz" "HUNTER STATUS"
assert_eq "SENDER: bez tokenu + master"   "$AUTH_OK"  "1"
assert_eq "SENDER: prikaz"                "$AUTH_CMD" "STATUS"
assert_eq "SENDER: priznak tokenu"        "$AUTH_HAS_TOKEN" "0"

authorize_mail "paja.stindl@seznam.cz" "HUNTER tajnytoken1 STATUS"
assert_eq "SENDER: s tokenem taky projde" "$AUTH_OK" "1"
assert_eq "SENDER: token rozpoznan"       "$AUTH_HAS_TOKEN" "1"

authorize_mail "cizi@example.com" "HUNTER STATUS"
assert_eq "SENDER: cizi odesilatel" "$AUTH_OK" "0"

set_config_value AUTH_TYPE TOKEN
AUTH_TYPE=TOKEN

# --- velikost pismen v adrese ---
authorize_mail "Paja.Stindl@Seznam.CZ" "HUNTER tajnytoken1 STATUS"
assert_eq "adresa case-insensitive" "$AUTH_OK" "1"

# --- osirela carka v MAIL_MASTERS + prazdna adresa (bezpecnostni fix) ---
# Kdyz MAIL_MASTERS konci carkou (typicky preklep pri rucni editaci
# configu), ",paja.stindl@seznam.cz,," obsahuje substring ",,", ktery by
# bez explicitni kontroly prazdneho vstupu matchoval i prazdnou adresu.
MAIL_MASTERS="paja.stindl@seznam.cz,"
is_mail_master "" && r=1 || r=0
assert_eq "prazdna adresa s osirelou carkou v MAIL_MASTERS neprojde" "$r" "0"

authorize_mail "" "HUNTER tajnytoken1 STATUS"
assert_eq "TOKEN: prazdny odesilatel s osirelou carkou neprojde" "$AUTH_OK" "0"
MAIL_MASTERS="paja.stindl@seznam.cz"

# --- sprava tokenu ---
load_tokens
assert_eq "pocet tokenu na zacatku" "$TOKEN_COUNT" "1"

add_token "druhytoken2"
assert_eq "po pridani"       "$ADD_TOKEN_RESULT" "OK"
load_tokens
assert_eq "pocet po pridani" "$TOKEN_COUNT" "2"

add_token "druhytoken2"
assert_eq "duplicitni pridani je no-op" "$ADD_TOKEN_RESULT" "EXISTS"

add_token "kratky"
assert_eq "kratky token odmitnut" "$ADD_TOKEN_RESULT" "TOO_SHORT"

add_token "token s mezerou"
assert_eq "token s mezerou odmitnut" "$ADD_TOKEN_RESULT" "BAD_CHARS"

# vlozeny newline: $(printf '\n') by se orezal na prazdny retezec, proto
# skutecny Enter v literalu - viz nl v add_token.
nl='
'
add_token "abcd${nl}efgh1234"
assert_eq "token s vlozenym newline odmitnut" "$ADD_TOKEN_RESULT" "BAD_CHARS"
load_tokens
assert_eq "pocet nezmenen po odmitnutem tokenu s newline" "$TOKEN_COUNT" "2"

is_valid_token "druhytoken2" && r=1 || r=0
assert_eq "novy token plati" "$r" "1"

remove_token "druhytoken2"
assert_eq "odebrani"       "$REMOVE_TOKEN_RESULT" "OK"
load_tokens
assert_eq "pocet po odebrani" "$TOKEN_COUNT" "1"

remove_token "tajnytoken1"
assert_eq "posledni token nelze odebrat" "$REMOVE_TOKEN_RESULT" "LAST"
load_tokens
assert_eq "pocet zustal" "$TOKEN_COUNT" "1"

remove_token "neexistujici9"
assert_eq "odebrani neexistujiciho" "$REMOVE_TOKEN_RESULT" "NOT_FOUND"

# --- fail closed ---
rm -f "$TOKEN_FILE"
load_tokens
assert_eq "chybejici soubor = 0 tokenu" "$TOKEN_COUNT" "0"
authorize_mail "paja.stindl@seznam.cz" "HUNTER tajnytoken1 STATUS"
assert_eq "TOKEN rezim bez tokenu = fail closed" "$AUTH_OK" "0"

fixture_teardown
finish
