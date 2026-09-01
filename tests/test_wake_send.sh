#!/bin/sh
# tests/test_wake_send.sh - vlastni utocne/hranicni testy nad ramec
# briefu Tasku 13 (integrace hunter.sh). Overuje CELY realny beh
# hunter.sh (jako podproces, viz tests/fixture_subprocess.sh), ne jen
# jednotlive funkce - protoze slucovani REQUESTED_SNAPS s automatickymi
# kandidaty, strop MAX_SEND_PER_WAKE a vyjimka ze sent_list.txt zijou
# primo v tele hunter.sh, ne ve funkci.
#
# --- KRITICKY MECHANISMUS (viz task-13-brief.md + kontext Tasku 13) ---
# Vyzadana fotka (LAST/DATE/GET) se NESMI zapsat do sent_list.txt, jinak
# by ji find_ready_candidates() priste povazovala za "uz odeslanou" a uz
# by nikdy nedosla AUTOMATICKY. Testy nize overuji:
#   1) vyzadana fotka, ktera ESTE NEBYLA odeslana (tedy je SOUCASNE i
#      platnym automatickym kandidatem), se posle PRESNE JEDNOU (ne
#      dvakrat - viz nalez nize) a po odeslani zustane MIMO
#      sent_list.txt,
#   2) stejna davka obsahuje i fotku nalezenou VYHRADNE automaticky -
#      ta se DO sent_list.txt zapise normalne,
#   3) MAX_SEND_PER_WAKE je spolecny strop pro obe kategorie dohromady,
#      ne zvlast pro kazdou - vyzadane maji prednost (jsou v seznamu
#      prvni), ale jakmile je strop vycerpan, dalsi (ani automaticke,
#      ani dalsi vyzadane) uz neodejdou.
#
# --- NALEZ NAD RAMEC BRIEFU --------------------------------------------
# Kod z briefu (Krok 4) spojuje $REQUESTED_SNAPS s vysledkem
# wait_for_candidates() BEZ odstraneni duplicit. Vyzadana fotka, ktera
# jeste nebyla odeslana, je ale SOUCASNE platnym automatickym
# kandidatem (find_ready_candidates hleda vse mimo sent_list.txt a o
# vyzadani nic nevi) - bez dedup kroku by se tak objevila v $snap_list
# DVAKRAT, poslala by se e-mailem dvakrat a OBE kopie by (spravne, viz
# case test) skoncily mimo sent_list.txt, protoze obe matchuji
# REQUESTED_SNAPS. Vysledek: duplicitni e-mail a fotka navzdy oznacovana
# jako "neodeslana" pro automatiku. hunter.sh proto ted PRED spojenim
# odstranuje z automatickeho seznamu kazdy radek, ktery uz je mezi
# vyzadanymi (viz komentar u "POZOR na prekryv" v hunter.sh). Scenar A
# nize tohle primo overuje (attach count == 2, ne 3).
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture_subprocess.sh"

attach_count() { grep -c -- '--attach' "$FIX/mailsend.log" 2>/dev/null; }
attach_has() { grep -qF -- "$1" "$FIX/mailsend.log" 2>/dev/null && echo 1 || echo 0; }
sent_list_lines() { [ -f "$HDIR/state/sent_list.txt" ] && grep -c . "$HDIR/state/sent_list.txt" || echo 0; }
sent_list_has() { [ -f "$HDIR/state/sent_list.txt" ] && grep -qF -- "$1" "$HDIR/state/sent_list.txt" && echo 1 || echo 0; }

# =====================================================================
# Scenar A: vyzadana + automaticka fotka v jedne davce, prekryv mnozin
# =====================================================================
subproc_fixture_setup 3
subproc_mk_snap 260828 100000   # A - vyzada se pres GET, jeste neodeslana
subproc_mk_snap 260828 110000   # B - cisty automaticky kandidat
printf 'UIDVALIDITY|999\nMSG|1|paja.stindl@seznam.cz|HUNTER tajnytoken1 GET 100000_000_65535_P.jpg\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

assert_eq "A: presne 2 prilohy odeslany (ne 3 - zadna duplicita A)" \
          "$(attach_count)" "2"
assert_eq "A: pozadana fotka A byla poslana"    "$(attach_has "100000_000_65535_P.jpg")" "1"
assert_eq "A: automaticka fotka B byla poslana" "$(attach_has "110000_000_65535_P.jpg")" "1"
assert_eq "A: sent_list.txt ma presne 1 zaznam (jen B)" "$(sent_list_lines)" "1"
assert_eq "A: pozadana fotka NENI v sent_list.txt"      "$(sent_list_has "100000_000_65535_P.jpg")" "0"
assert_eq "A: automaticka fotka JE v sent_list.txt"     "$(sent_list_has "110000_000_65535_P.jpg")" "1"

subproc_fixture_teardown

# =====================================================================
# Scenar B: MAX_SEND_PER_WAKE=2, 2 vyzadane + 2 automaticke (celkem 4
# unikatni kandidati bez prekryvu) - strop plati DOHROMADY, vyzadane
# maji prednost (jsou v seznamu prvni) => posle se JEN 2, obe vyzadane,
# zadna automaticka se nedostane ani k pokusu o odeslani.
# =====================================================================
subproc_fixture_setup 2
subproc_mk_snap 260828 090000   # AUT1 (nejstarsi automaticky)
subproc_mk_snap 260828 100000   # AUT2
subproc_mk_snap 260828 200000   # R1 (vyzadana, novejsi)
subproc_mk_snap 260828 210000   # R2 (vyzadana, nejnovejsi)
printf 'UIDVALIDITY|999\nMSG|1|paja.stindl@seznam.cz|HUNTER tajnytoken1 LAST 2\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

assert_eq "B: strop=2 -> presne 2 prilohy odeslany" "$(attach_count)" "2"
assert_eq "B: vyzadana R1 odeslana" "$(attach_has "200000_000_65535_P.jpg")" "1"
assert_eq "B: vyzadana R2 odeslana" "$(attach_has "210000_000_65535_P.jpg")" "1"
assert_eq "B: automaticka AUT1 se NEODESLALA (strop vycerpan vyzadanymi)" \
          "$(attach_has "090000_000_65535_P.jpg")" "0"
assert_eq "B: automaticka AUT2 se NEODESLALA (strop vycerpan vyzadanymi)" \
          "$(attach_has "100000_000_65535_P.jpg")" "0"
assert_eq "B: sent_list.txt zustava prazdny (obe odeslane byly vyzadane)" \
          "$(sent_list_lines)" "0"

subproc_fixture_teardown

# =====================================================================
# Scenar C: MAX_SEND_PER_WAKE=3, 2 vyzadane + 3 automaticke (5 unikatnich
# kandidatu, strop 3) - overuje, ze strop je SPOLECNY pro obe kategorie
# (ne 3 vyzadane + 3 automaticke zvlast): posle se 2 vyzadane + JEN 1
# automaticka (ne vsechny 3 automaticke).
# =====================================================================
subproc_fixture_setup 3
subproc_mk_snap 260828 090000   # AUT1
subproc_mk_snap 260828 100000   # AUT2
subproc_mk_snap 260828 110000   # AUT3
subproc_mk_snap 260828 200000   # R1
subproc_mk_snap 260828 210000   # R2
printf 'UIDVALIDITY|999\nMSG|1|paja.stindl@seznam.cz|HUNTER tajnytoken1 LAST 2\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

assert_eq "C: strop=3, dohromady presne 3 prilohy odeslany (ne 5)" "$(attach_count)" "3"
assert_eq "C: vyzadana R1 odeslana" "$(attach_has "200000_000_65535_P.jpg")" "1"
assert_eq "C: vyzadana R2 odeslana" "$(attach_has "210000_000_65535_P.jpg")" "1"
assert_eq "C: presne 1 automaticka fotka se dostala do sent_list.txt" \
          "$(sent_list_lines)" "1"
# aspon jedna, ale ne vsechny tri automaticke smely projit (find poradi
# neni garantovane, takze nevime KTERA z AUT1/AUT2/AUT3 to bude - jen
# ze je to presne jedna z nich, ne vic).
auts_sent=0
for f in "090000_000_65535_P.jpg" "100000_000_65535_P.jpg" "110000_000_65535_P.jpg"; do
    [ "$(attach_has "$f")" = "1" ] && auts_sent=$((auts_sent + 1))
done
assert_eq "C: presne 1 z trech automatickych se skutecne poslala" "$auts_sent" "1"

subproc_fixture_teardown

finish
