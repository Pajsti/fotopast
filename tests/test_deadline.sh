#!/bin/sh
# tests/test_deadline.sh - pojistka RUN_DEADLINE musi zabit i visici dite.
#
# 2026-09-06 skoncilo 18 behu za sebou tvrdym SIGKILLem: mailrecv visel
# na zaseklem spojeni, hlavni beh cekal v prikazove substituci a SIGTERM
# poslany jen shellu se ODLOZIL (trap se zpracuje az dite skonci).
# Nasledny SIGKILL uz cleanup obesel uplne - zamek zustal na karte a
# kdyby v tu chvili byla zmrazena ubia_first, zustala by zmrazena taky.
#
# Overeno experimentem: shell zablokovany na diteti cleanup neprovede,
# shell ve vlastni smycce ano. Proto musi pojistka zabit nejdriv dite.
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# Falesny pidof, ktery hlasi nas obetni proces jako "mailrecv".
FAKEBIN="$FIX/fakebin"
mkdir -p "$FAKEBIN"

sleep 30 &
victim=$!

cat > "$FAKEBIN/pidof" <<PIDOF
#!/bin/sh
[ "\$1" = mailrecv ] && { echo $victim; exit 0; }
exit 1
PIDOF
chmod +x "$FAKEBIN/pidof"
PATH="$FAKEBIN:$PATH"

# obet opravdu bezi
kill -0 "$victim" 2>/dev/null && r=0 || r=1
assert_eq "obetni proces pred zabitim bezi" "$r" "0"

deadline_kill_tools

# dat signalu chvili
i=0
while [ "$i" -lt 20 ]; do
    kill -0 "$victim" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
done

kill -0 "$victim" 2>/dev/null && r=0 || r=1
assert_eq "deadline_kill_tools visici nastroj zabil" "$r" "1"

# nastroj, ktery nebezi, nesmi nic rozbit ani vratit chybu
deadline_kill_tools && r=0 || r=1
assert_eq "druhe volani projde i kdyz uz nic nebezi" "$r" "0"

wait "$victim" 2>/dev/null
fixture_teardown

# --- skutecny beh: visici mailrecv nesmi obejit cleanup ---
# Funkcni test vyse overuje, ze se dite zabije. Tenhle overuje, proc na
# tom zalezi: ze diky tomu probehne cleanup, tedy uvolni se zamek a
# odmrazi ubia_first. Jde to jen skutecnym procesem - pojistka i trap
# ziji v tele hunter.sh, ktere nejde nasourcovat.
. "$(dirname "$0")/fixture_subprocess.sh"

subproc_fixture_setup 3

# Falesny mailrecv modeluje ten skutecny: JEDEN proces bez potomku.
# "exec" je tu nosny. Bez nej by obalovy shell umrel na SIGTERM, ale
# vnuk (sleep) by zil dal a drzel otevreny zapisovy konec roury - a
# prikazova substituce cte do EOF, takze by se hlavni beh neodblokoval.
# Skutecny mailrecv je C binarka bez potomku, u ktere zabiti rouru
# zavre; atrapa se vnukem by testovala situaci, ktera v provozu nenastane.
cat > "$HDIR/bin/mailrecv" <<MR
#!/bin/sh
echo \$\$ > "$FIX/mailrecv.pid"
exec sleep 60
MR
chmod +x "$HDIR/bin/mailrecv"

# Pojistka hleda nastroje pres pidof; bez nej nema co zabit.
cat > "$FIX/fakebin/pidof" <<PD
#!/bin/sh
[ "\$1" = mailrecv ] || exit 1
[ -s "$FIX/mailrecv.pid" ] || exit 1
cat "$FIX/mailrecv.pid"
PD
chmod +x "$FIX/fakebin/pidof"

printf 'RUN_DEADLINE=5\n' >> "$HDIR/config.txt"

subproc_run_hunter

assert_eq "po deadline neni zamek (cleanup probehl)" \
    "$([ -d "$HDIR/state/.lock" ] && echo je || echo neni)" "neni"

subproc_fixture_teardown
finish
