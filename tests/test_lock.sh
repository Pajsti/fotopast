#!/bin/sh
# tests/test_lock.sh - zamek proti dvema soubeznym behum hunter.sh.
#
# 2026-09-01 zustal na karte zamek po behu, ktery zabil SIGKILL behem
# restartovaci smycky. Po restartu dostal jeho pid systemovy proces,
# kill -0 uspelo a Hunter dva dny jen zapisoval "jina instance uz bezi"
# a koncil. Nic to nehlasilo. Tenhle soubor hlida, aby se to nevratilo.
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

LOCKDIR="$STATE_DIR/.lock"

# --- ciste prostredi: zamek se vezme ---
rm -rf "$LOCKDIR"
acquire_lock && r=0 || r=1
assert_eq "na cistem stavu se zamek vezme" "$r" "0"
assert_eq "zamek existuje" "$([ -d "$LOCKDIR" ] && echo ano || echo ne)" "ano"
assert_eq "v zamku je nas pid" "$(cat "$LOCKDIR/pid" 2>/dev/null)" "$$"

# --- release_lock ho uklidi ---
release_lock
assert_eq "release_lock zamek smazal" \
    "$([ -d "$LOCKDIR" ] && echo ano || echo ne)" "ne"

# --- KLICOVE: zamek drzi ZIVY pid, ktery ale NENI hunter.sh ---
# Presne to, co se stalo na karte: pid 235 po restartu patril
# systemovemu procesu, kill -0 uspelo a zamek uz nikdy nikdo neuvolnil.
#
# Pouzivame cizi bezici proces, ne $$ - kdybychom zapsali vlastni pid,
# assert na zotaveni by byl bezobsazny, protoze by v zamku bylo $$ uz
# pred volanim acquire_lock.
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"
sleep 30 &
alien_pid=$!
echo "$alien_pid" > "$LOCKDIR/pid"
acquire_lock && r=0 || r=1
assert_eq "zivy pid, ktery neni hunter.sh, zamek nedrzi" "$r" "0"
assert_eq "po zotaveni je v zamku nas pid, ne cizi" \
    "$(cat "$LOCKDIR/pid" 2>/dev/null)" "$$"
kill "$alien_pid" 2>/dev/null
wait "$alien_pid" 2>/dev/null
release_lock

# --- mrtvy pid: zamek se zotavi ---
# Pid, ktery skoro jiste nebezi. Kdyby nahodou bezel, kontrola cmdline
# ho stejne odmitne, takze test nemuze byt flaky z obou stran zaroven.
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"
echo 999999 > "$LOCKDIR/pid"
acquire_lock && r=0 || r=1
assert_eq "mrtvy pid zamek nedrzi" "$r" "0"
release_lock

# --- prazdny soubor pid: zamek se zotavi ---
# Stava se, kdyz mkdir projde, ale zapis pidu selze (plna karta, I/O
# chyba). Puvodni kod na tohle nemel zadnou cestu k zotaveni a zamek
# by drzel navzdy.
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"
: > "$LOCKDIR/pid"
acquire_lock && r=0 || r=1
assert_eq "prazdny pid soubor zamek nedrzi" "$r" "0"
release_lock

# --- uplne chybejici soubor pid: zamek se zotavi ---
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"
acquire_lock && r=0 || r=1
assert_eq "chybejici pid soubor zamek nedrzi" "$r" "0"
release_lock

# --- necitelny obsah: zamek se zotavi ---
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"
echo 'neco-co-neni-cislo' > "$LOCKDIR/pid"
acquire_lock && r=0 || r=1
assert_eq "necislo v pid souboru zamek nedrzi" "$r" "0"
release_lock

# --- pid "0": zamek se zotavi ---
# Zradne: "kill -0 0" miri na vlastni skupinu procesu a VZDY uspeje,
# ale /proc/0 neexistuje, takze by to spadlo do vetve "neumim
# rozhodnout, ber to jako zive" a zamek by drzel navzdy. Cislo 0 zadny
# proces nema, takze je to vzdycky zbytek.
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"
echo 0 > "$LOCKDIR/pid"
acquire_lock && r=0 || r=1
assert_eq "pid 0 zamek nedrzi" "$r" "0"
release_lock

# --- pid rovny nasemu vlastnimu ---
# Po restartu se pidy recykluji od nizkych cisel, takze zamek muze nest
# tetez cislo, jake dostane novy beh. Na zarizeni by pak kill -0 i
# cmdline nutne odpovedely "zije hunter.sh" - je to totiz nas vlastni
# proces. Jenze dva procesy nemuzou drzet tentyz pid zaroven, takze
# takovy zamek je vzdycky zbytek po mrtvem predchudci.
#
# Nestaci zavolat lock_owner_alive "$$" primo z tohohle testu: cmdline
# testovaciho shellu je "dash tests/test_lock.sh", takze by odpoved
# "nezije" prisla uz z kontroly cmdline a pojistka na vlastni pid by
# se vubec nezavadila. Test by prosel, i kdyby v kodu nebyla.
#
# Reprodukujeme to tedy poctive: skriptem, ktery se JMENUJE hunter.sh,
# takze jeho cmdline vypada presne jako na zarizeni.
mkdir -p "$FIX/self"
cat > "$FIX/self/hunter.sh" <<EOF
. "$ROOT/hunter/lib/common.sh"
lock_owner_alive \$\$ && exit 0
exit 1
EOF
dash "$FIX/self/hunter.sh" && r=0 || r=1
assert_eq "vlastni pid se nepovazuje za ziveho drzitele" "$r" "1"

# --- poctive odmitnuti: zamek drzi skutecny bezici hunter.sh ---
# Spustime skutecny proces, jehoz cmdline obsahuje "hunter.sh", a
# zapiseme jeho pid do zamku. Tenhle pripad se zotavit NESMI.
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"
cp /dev/null "$FIX/hunter.sh"
printf 'sleep 30\n' > "$FIX/hunter.sh"
sh "$FIX/hunter.sh" &
real_pid=$!
echo "$real_pid" > "$LOCKDIR/pid"
acquire_lock && r=0 || r=1
assert_eq "bezici hunter.sh zamek DRZI" "$r" "1"
assert_eq "cizi zamek zustal nedotcen" \
    "$(cat "$LOCKDIR/pid" 2>/dev/null)" "$real_pid"
kill "$real_pid" 2>/dev/null
wait "$real_pid" 2>/dev/null
rm -rf "$LOCKDIR"

fixture_teardown
finish
