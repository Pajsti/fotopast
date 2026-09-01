#!/bin/sh
# tests/test_wake_freeze.sh - vlastni utocny/integracni test nad ramec
# briefu Tasku 13. tests/test_frozen.sh (podle briefu) overuje
# ensure_app_frozen izolovane, s vyfingovanymi kill/pidof funkcemi v
# JEDNOM shellu. Tenhle test overuje totez v REALNEM behu cele hunter.sh
# (viz tests/fixture_subprocess.sh) - ze tri NEZAVISLA volaci mista
# (process_sms, process_mail, fotkova vetev), ktera si o
# ensure_app_frozen nic navzajem nevi, se v jednom probuzeni skutecne
# sdili JEDNU promennou STOPPED_APP a zmrazi aplikaci dohromady jen
# jednou - a ze po dokonceni behu se aplikace spolehlive odmrazi
# (kill -CONT), i kdyz zbytek behu (mail, foto) uz probehl s aplikaci
# zmrazenou.
#
# Fake pidof vraci PID SKUTECNE pozadi bezicicho procesu (subproc_use_
# real_pid), takze kill -STOP/-CONT provadi opravdovou praci, ne jen
# tise selze na neexistujici PID - jinak by test proslo i kdyby
# STOPPED_APP vubec nefungovalo.
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture_subprocess.sh"

freeze_count() { grep -c "zmrazen" "$HDIR/log.txt" 2>/dev/null; }
resume_count() { grep -c "pokracuje" "$HDIR/log.txt" 2>/dev/null; }

subproc_fixture_setup 5
subproc_use_real_pid

# process_sms: 1 autorizovana SMS (STATUS) - prvni prilezitost zmrazit.
cat > "$HDIR/bin/smsrecv" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/sms_listing.txt" 2>/dev/null; exit 0 ;;
    del) shift; echo "\$@" >> "$FIX/sms_del.log"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$HDIR/bin/smsrecv"
printf 'MSG|1|REC UNREAD|+420603284430|26/08/28,21:09:48|STATUS\n' > "$FIX/sms_listing.txt"

# process_mail: 1 autorizovany mail prikaz (STATUS) - druha prilezitost.
printf 'UIDVALIDITY|999\nMSG|1|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' \
    > "$FIX/mail_listing.txt"

# fotkova vetev: 1 pripraveny snimek - treti prilezitost (explicitni
# volani ensure_app_frozen pred odesilaci smyckou v hunter.sh).
subproc_mk_snap 260828 220000

subproc_run_hunter

assert_eq "3 volaci mista (SMS/mail/foto) -> presne 1 zmrazeni v logu" \
          "$(freeze_count)" "1"
assert_eq "presne 1 odmrazeni na konci behu" "$(resume_count)" "1"
assert_contains "SMS prikaz se opravdu vykonal (log obsahuje SMS radek)" \
                 "$(cat "$HDIR/log.txt")" "SMS od +420603284430: STATUS"
assert_contains "mail prikaz se opravdu vykonal (log obsahuje mail radek)" \
                 "$(cat "$HDIR/log.txt")" "mail prikaz od paja.stindl@seznam.cz: STATUS"
assert_contains "foto se opravdu poslalo (log obsahuje odeslano)" \
                 "$(cat "$HDIR/log.txt")" "odeslano:"
assert_eq "stderr je prazdny (zadna chyba z kill na realny PID)" \
          "$(cat "$FIX/stderr.log")" ""

# realny pozadi bezici proces prezil CONT (nebyl omylem zabit) - overuje,
# ze cleanup() i sama odesilaci smycka pouzivaji spravny PID a spravny
# signal (jmenem, ne cislem).
if kill -0 "$SUBPROC_REAL_PID" 2>/dev/null; then r=alive; else r=gone; fi
assert_eq "aplikace po CONT porad bezi (nebyla omylem zabita)" "$r" "alive"

subproc_fixture_teardown

# =====================================================================
# Druhy beh: ubia_first VUBEC nebezi (pidof nic nevrati) - overuje, ze
# se v REALNEM behu (ne jen v izolovane funkci test_frozen.sh) vsechna
# tri volaci mista chovaji stejne "nespadlo to" a beh normalne dokonci
# vc. odeslani fotky bez SIGSTOP/SIGCONT.
# =====================================================================
subproc_fixture_setup 5
# vychozi fake pidof (bez subproc_use_real_pid) uz vraci "nic" -
# ubia_first "nebezi".
cat > "$HDIR/bin/smsrecv" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/sms_listing.txt" 2>/dev/null; exit 0 ;;
    del) shift; echo "\$@" >> "$FIX/sms_del.log"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$HDIR/bin/smsrecv"
printf 'MSG|1|REC UNREAD|+420603284430|26/08/28,21:09:48|STATUS\n' > "$FIX/sms_listing.txt"
printf 'UIDVALIDITY|999\nMSG|1|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' \
    > "$FIX/mail_listing.txt"
subproc_mk_snap 260828 220000

subproc_run_hunter
rc=$?

assert_eq "bez ubia_first: hunter.sh porad dokonci uspesne (exit 0)" "$rc" "0"
assert_eq "bez ubia_first: v logu nikdy 'zmrazen'" "$(freeze_count)" "0"
assert_contains "bez ubia_first: VAROVANI se zaloguje" \
                 "$(cat "$HDIR/log.txt")" "VAROVANI: ubia_first neni v ps"
assert_contains "bez ubia_first: foto se presto posle" \
                 "$(cat "$HDIR/log.txt")" "odeslano:"

subproc_fixture_teardown

finish
