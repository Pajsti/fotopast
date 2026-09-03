#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture_subprocess.sh"

# =====================================================================
# A: MAX_QUEUE odrizne NEJSTARSI a fronta se vejde pod strop
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=2\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260828 030000
subproc_mk_snap 260829 040000

subproc_run_hunter

sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)
ms=$(cat "$FIX/mailsend.log" 2>/dev/null)

assert_contains "A: log rekl, ze fronta prerostla strop" \
                "$(cat "$HDIR/log.txt")" "fronta pres strop"
assert_not_contains "A: nejstarsi se NEODESLALA" "$ms" "010000"
assert_not_contains "A: druha nejstarsi se NEODESLALA" "$ms" "020000"
assert_contains "A: novejsi se odeslala" "$ms" "030000"
assert_contains "A: nejnovejsi se odeslala" "$ms" "040000"
assert_contains "A: preskocena nejstarsi je v sent_list" "$sl" "010000"
assert_contains "A: preskocena druha je v sent_list" "$sl" "020000"
assert_eq "A: preskocene soubory zustaly na karte" \
          "$([ -f "$SDCARD/snaps/260828/010000_000_65535_P.jpg" ] && echo ano)" "ano"

subproc_fixture_teardown

# =====================================================================
# B: pod stropem se neodrezava nic
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=100\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260829 020000

subproc_run_hunter

assert_not_contains "B: pod stropem se o odrezavani vubec nemluvi" \
                    "$(cat "$HDIR/log.txt")" "fronta pres strop"

subproc_fixture_teardown

# =====================================================================
# C: KRITICKE - MAX_QUEUE orizne fotku, kterou nekdo PRAVE vyzadal pres
# GET a ktera jeste nebyla odeslana - je tedy SOUCASNE i platnym
# automatickym kandidatem, a jako nejstarsi z ni padne prave do davky
# urcene k oriznuti. Prikaz jde skutecnou cestou (mail_listing.txt ->
# process_mail -> execute_command), ne rucnim nastavenim REQUESTED_SNAPS -
# cilem je proverit MISTO VOLANI v tele hunter.sh, ne skip_snaps
# samotnou (tu uz overuje test_queue.sh na urovni funkce).
#
# Invariant 7.1 vyzaduje OBOJI zaroven: R se MUSI poslat mailem (diky
# nezavislemu slouceni REQUESTED_SNAPS PO oriznuti), ale NESMI skoncit v
# sent_list.txt - ani touhle cestou. Kdyby oriznuti obesla skip_snaps
# (napr. zapsalo by preskocene rovnou do sent_list.txt), tenhle test by
# to odhalil - viz mutation-check v hlaseni Tasku 5.
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=2\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000   # R    - vyzada se pres GET, NEJSTARSI (padne do oriznuti)
subproc_mk_snap 260828 020000   # AUT1 - druha nejstarsi, take padne do oriznuti
subproc_mk_snap 260828 030000   # AUT2 - zustava pod stropem
subproc_mk_snap 260829 040000   # AUT3 - nejnovejsi, zustava pod stropem
printf 'UIDVALIDITY|999\nMSG|1|paja.stindl@seznam.cz|HUNTER tajnytoken1 GET 010000_000_65535_P.jpg\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)
ms=$(cat "$FIX/mailsend.log" 2>/dev/null)

assert_contains "C: log rekl, ze fronta prerostla strop" \
                "$(cat "$HDIR/log.txt")" "fronta pres strop"
assert_contains "C: vyzadana fotka R BYLA odeslana (i kdyz byla mezi oriznutymi)" \
                "$ms" "010000"
assert_not_contains "C: vyzadana fotka R se NEDOSTALA do sent_list (invariant 7.1)" \
                    "$sl" "010000"
assert_contains "C: nevyzadana AUT1 (take oriznuta) je v sent_list" "$sl" "020000"
assert_contains "C: AUT2 pod stropem se odeslala" "$ms" "030000"
assert_contains "C: AUT3 pod stropem se odeslala" "$ms" "040000"

subproc_fixture_teardown

# =====================================================================
# D: MAX_QUEUE=0 nic neorizne, i kdyz je fronta velka
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=0\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260828 030000
subproc_mk_snap 260829 040000
subproc_mk_snap 260829 050000

subproc_run_hunter

assert_not_contains "D: MAX_QUEUE=0 - o oriznuti se v logu nemluvi vubec" \
                    "$(cat "$HDIR/log.txt")" "fronta pres strop"

subproc_fixture_teardown

# =====================================================================
# E/F: hranice - presne na stropu se neorizne nic, o jednu vic uz
# orizne presne jednu nejstarsi
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=3\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260828 030000

subproc_run_hunter

assert_not_contains "E: fronta presne na stropu (3=3) se neorizne" \
                    "$(cat "$HDIR/log.txt")" "fronta pres strop"
assert_contains "E: vsechny tri se presto odeslaly" \
                "$(cat "$FIX/mailsend.log" 2>/dev/null)" "010000"

subproc_fixture_teardown

subproc_fixture_setup 4 4
printf 'MAX_QUEUE=3\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260828 030000
subproc_mk_snap 260829 040000

subproc_run_hunter

sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)
ms=$(cat "$FIX/mailsend.log" 2>/dev/null)

assert_contains "F: fronta o 1 pres strop (4>3) se orizne" \
                "$(cat "$HDIR/log.txt")" "fronta pres strop"
assert_not_contains "F: preskocila se presne jen nejstarsi" "$ms" "010000"
assert_contains "F: preskocena nejstarsi je v sent_list" "$sl" "010000"
assert_contains "F: zbyle tri se odeslaly" "$ms" "020000"

subproc_fixture_teardown

# =====================================================================
# G: CLEAR QUEUE mailem - nic se neodesle, nic se nesmaze
# =====================================================================
subproc_fixture_setup 3 3

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260829 030000

printf 'UIDVALIDITY|1\nMSG|10|paja.stindl@seznam.cz|HUNTER tajnytoken1 CLEAR QUEUE\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

ms=$(cat "$FIX/mailsend.log" 2>/dev/null)
sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)

# odpoved na prikaz se posila (bez prilohy), fotky NE (ty maji --attach)
assert_eq "G: neodesla se ani jedna fotka" \
          "$(printf '%s\n' "$ms" | grep -c -- '--attach')" "0"
assert_contains "G: log rekl kolik preskocil" \
                "$(cat "$HDIR/log.txt")" "CLEAR QUEUE: preskoceno 3"
assert_contains "G: vsechny tri jsou v sent_list" "$sl" "010000"
assert_contains "G: vsechny tri jsou v sent_list (2)" "$sl" "020000"
assert_contains "G: vsechny tri jsou v sent_list (3)" "$sl" "030000"
assert_eq "G: soubory zustaly na karte" \
          "$([ -f "$SDCARD/snaps/260829/030000_000_65535_P.jpg" ] && echo ano)" "ano"

subproc_fixture_teardown

# =====================================================================
# H: INVARIANT 7.1 - CLEAR QUEUE prijde v davce DRIV nez LAST, a presto
# se vyzadana fotka musi odeslat a NESMI skoncit v sent_list.txt.
#
# Tohle je duvod, proc CLEAR QUEUE jen nastavuje priznak misto aby
# preskakoval hned. Kdyby preskakoval hned, oznacil by fotku, kterou ma
# LAST teprve vyzadat - a ta by z automatickeho odesilani vypadla
# NATRVALO, tise a bez stopy v logu.
# =====================================================================
subproc_fixture_setup 3 3

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260829 030000

printf 'UIDVALIDITY|1\nMSG|10|paja.stindl@seznam.cz|HUNTER tajnytoken1 CLEAR QUEUE\nMSG|11|paja.stindl@seznam.cz|HUNTER tajnytoken1 LAST 1\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

ms=$(cat "$FIX/mailsend.log" 2>/dev/null)
sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)

assert_contains "H: vyzadana fotka se PRESTO odeslala" "$ms" "030000"
assert_not_contains "H: a NENI v sent_list (jinak by z automatiky vypadla navzdy)" \
                    "$sl" "030000"
assert_contains "H: nevyzadane preskocene v sent_list jsou" "$sl" "010000"
assert_contains "H: nevyzadane preskocene v sent_list jsou (2)" "$sl" "020000"

subproc_fixture_teardown

# =====================================================================
# I: REGRESE - trvale nekompletni soubor (snapready ho odmita navzdy)
# lezi v nejstarsim dni, existuje novejsi den. CLEAR QUEUE musi
# vyprazdnit CELOU frontu vcetne nej, jinak den nikdy nedoteka a cursor
# se navzdy zasekne (spec 2026-09-03, oprava omezeni 9.3 bod 3).
# =====================================================================
subproc_fixture_setup 3 3

subproc_mk_snap 260828 010000   # trvale nekompletni - snapready ho vzdy odmita
subproc_mk_snap 260829 020000   # novejsi den, normalni kandidat

printf '#!/bin/sh\ncase "$1" in *010000*) exit 1 ;; esac\nexit 0\n' \
    > "$HDIR/bin/snapready"
chmod +x "$HDIR/bin/snapready"

printf 'UIDVALIDITY|1\nMSG|10|paja.stindl@seznam.cz|HUNTER tajnytoken1 CLEAR QUEUE\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)
ms=$(cat "$FIX/mailsend.log" 2>/dev/null)
cur=$(cat "$HDIR/state/cursor.txt" 2>/dev/null)

assert_eq "I: neodesla se ani jedna fotka" \
          "$(printf '%s\n' "$ms" | grep -c -- '--attach')" "0"
assert_contains "I: log rekl kolik preskocil" \
                "$(cat "$HDIR/log.txt")" "CLEAR QUEUE: preskoceno 2"
assert_contains "I: i trvale odmitany soubor se dostal do sent_list" "$sl" "010000"
assert_contains "I: normalni kandidat je take v sent_list" "$sl" "020000"
assert_eq "I: den se souborem odmitanym snapready se uzavrel, cursor se posunul" \
          "$cur" "260829"
assert_eq "I: odmitany soubor zustal na karte" \
          "$([ -f "$SDCARD/snaps/260828/010000_000_65535_P.jpg" ] && echo ano)" "ano"

subproc_fixture_teardown

finish
