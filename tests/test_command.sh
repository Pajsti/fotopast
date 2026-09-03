#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

CMD_REPLY=""
execute_command "STATUS"
assert_contains "STATUS vraci BAT" "$CMD_REPLY" "BAT:"

CMD_REPLY=""
execute_command "status"
assert_contains "STATUS je case-insensitive" "$CMD_REPLY" "BAT:"

CMD_REPLY=""
execute_command "QUALITY LOW"
assert_eq "QUALITY LOW odpoved" "$CMD_REPLY" "QUALITY SET TO LOW"
assert_eq "QUALITY LOW v pameti" "$QUALITY" "LOW"
assert_contains "QUALITY LOW v configu" "$(cat "$CONFIG_FILE")" "QUALITY=LOW"

CMD_REPLY=""
execute_command "neznamy prikaz"
assert_eq "neznamy prikaz" "$CMD_REPLY" "UNKNOWN CMD"

# =====================================================================
# load_config: invariant MAX_SEND_PER_WAKE >= REQUEST_MAX
#
# Vyzadane fotky (LAST/DATE/GET) jsou v odesilaci davce PRVNI. Kdyby byl
# strop na probuzeni nizsi nez REQUEST_MAX, vytlacily by automaticke
# kandidaty a zbytek vyzadanych by se ZTRATIL - REQUESTED_SNAPS se mezi
# probuzenimi neuchovava, takze se uz nikdy nedoposlou. Uzivatel pritom
# uz dostal odpoved "SENDING N". Pravidlo bylo popsane v
# config.txt.example i v CHECKLISTu, ale nic ho nevynucovalo - a vychozi
# hodnoty v load_config ho samy porusovaly (3 < 5).
# =====================================================================

# a) config, ktery invariant porusuje, se srovna nahoru
set_config_value MAX_SEND_PER_WAKE 2
set_config_value REQUEST_MAX 5
load_config
assert_eq "nizky strop se zvedne na REQUEST_MAX" "$MAX_SEND_PER_WAKE" "5"
assert_eq "REQUEST_MAX zustava beze zmeny"       "$REQUEST_MAX" "5"

# b) config, ktery invariant splnuje, se NESMI menit
set_config_value MAX_SEND_PER_WAKE 8
set_config_value REQUEST_MAX 5
load_config
assert_eq "vyssi strop zustava, jak je" "$MAX_SEND_PER_WAKE" "8"

# c) vychozi hodnoty (klice v configu chybi uplne) invariant taky splnuji
grep -v '^MAX_SEND_PER_WAKE=' "$CONFIG_FILE" > "$CONFIG_FILE.noc"
grep -v '^REQUEST_MAX=' "$CONFIG_FILE.noc" > "$CONFIG_FILE"
rm -f "$CONFIG_FILE.noc"
unset MAX_SEND_PER_WAKE REQUEST_MAX
load_config
assert_eq "vychozi REQUEST_MAX"  "$REQUEST_MAX" "5"
assert_eq "vychozi strop neni pod vychozim REQUEST_MAX" \
          "$MAX_SEND_PER_WAKE" "5"

# --- STATUS hlasi hloubku fronty (spec 2026-09-02, sekce 10) ---
: > "$STATE_DIR/sent_list.txt"
rm -f "$STATE_DIR/cursor.txt"
fixture_snap 260828 111111
fixture_snap 260828 222222
CMD_REPLY=""
execute_command "STATUS" 1
assert_contains "STATUS hlasi frontu" "$CMD_REPLY" "FRONTA:"

# a cislo odpovida skutecnemu poctu kandidatu
q=$(find_ready_candidates | grep -c .)
assert_contains "STATUS hlasi spravny pocet" "$CMD_REPLY" "FRONTA:$q"

fixture_teardown
finish
