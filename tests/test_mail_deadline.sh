#!/bin/sh
# tests/test_mail_deadline.sh - kontrola posty nesmi sezrat cely beh.
#
# 2026-09-23, rozbor 195 behu z karty: 121 ze 132 nedokoncenych behu
# umrelo JESTE PRED ensure_app_frozen, tedy nikdy se nedostalo k
# odesilani, a 46 z nich trvalo presne >= RUN_DEADLINE. Posledni radek
# takoveho behu je vzdycky "mailrecv: VAROVANI..." - tedy zaseknuta
# kontrola posty (process_mail bezi PRED odesilanim, viz hunter.sh).
#
# Pricina v C: tlsnet_write i smycka handshaku toci donekonecna na
# MBEDTLS_ERR_SSL_WANT_WRITE, ktery mbedtls_net_send vraci po vyprseni
# SO_SNDTIMEO. Tenhle test ale netestuje C - testuje SHELLOVOU pojistku,
# ktera musi fungovat BEZ OHLEDU na to, proc mailrecv visi.
#
# Bez pojistky: zaseknuty mailrecv drzi beh az do RUN_DEADLINE a fotka
# se neodesle vubec. S pojistkou: kontrola posty se utne po
# MAIL_DEADLINE a beh pokracuje k odeslani.
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture_subprocess.sh"

subproc_fixture_setup 3

# Zaseknuty mailrecv. "exec" je nosne ze stejneho duvodu jako v
# test_deadline.sh: skutecny mailrecv je C binarka BEZ potomku, u ktere
# zabiti zavre rouru. Atrapa s vnukem by drzela zapisovy konec roury
# otevreny a prikazova substituce by cekala na EOF i po zabiti - to je
# situace, ktera v provozu nenastane.
cat > "$HDIR/bin/mailrecv" <<MR
#!/bin/sh
echo \$\$ > "$FIX/mailrecv.pid"
exec sleep 60
MR
chmod +x "$HDIR/bin/mailrecv"

# Fake pidof musi umet OBOJI: najit visici mailrecv (aby ho mela
# pojistka cim zabit) i ubia_first (aby ensure_app_frozen mela co
# zmrazit a beh se dostal az k odeslani).
sleep 600 &
APP_VICTIM=$!
printf '%s\n' "$APP_VICTIM" > "$FIX/app.pid"
cat > "$FIX/fakebin/pidof" <<PD
#!/bin/sh
case "\$1" in
    mailrecv) [ -s "$FIX/mailrecv.pid" ] || exit 1; cat "$FIX/mailrecv.pid" ;;
    ubia_first) cat "$FIX/app.pid" ;;
    *) exit 1 ;;
esac
exit 0
PD
chmod +x "$FIX/fakebin/pidof"

# Je co poslat.
subproc_mk_snap 260828 101010

# Rozpocet kontroly posty vyrazne pod RUN_DEADLINE (ten je 30 z fixture).
printf 'MAIL_DEADLINE=3\n' >> "$HDIR/config.txt"

start=$(date +%s)
subproc_run_hunter
elapsed=$(( $(date +%s) - start ))

# --- klicove tvrzeni: fotka odesla i pres zaseknutou kontrolu posty ---
assert_eq "fotka se odeslala i kdyz mailrecv visel" \
    "$([ -s "$FIX/mailsend.log" ] && echo ano || echo ne)" "ano"

assert_contains "odeslal se spravny snimek" \
    "$(cat "$FIX/mailsend.log" 2>/dev/null)" "101010_000_65535_P.jpg"

# --- beh dobehl ciste, ne pres RUN_DEADLINE ---
assert_contains "beh dobehl az na konec" \
    "$(cat "$HDIR/log.txt" 2>/dev/null)" "hunter konec"

assert_eq "zamek je po behu uvolneny" \
    "$([ -d "$HDIR/state/.lock" ] && echo je || echo neni)" "neni"

# --- a stihl to vyrazne driv nez RUN_DEADLINE=30 ---
# Bez pojistky by beh trval cely RUN_DEADLINE. S ni je ohraniceny
# MAIL_DEADLINE=3 plus vlastni prace, tedy radove sekundy.
assert_eq "beh skoncil pred RUN_DEADLINE (trval ${elapsed}s)" \
    "$([ "$elapsed" -lt 25 ] && echo ano || echo ne)" "ano"

# --- v logu je videt, ze pojistka zasahla ---
assert_contains "log rika, ze se kontrola posty utla" \
    "$(cat "$HDIR/log.txt" 2>/dev/null)" "kontrola posty"

kill -KILL "$APP_VICTIM" 2>/dev/null
subproc_fixture_teardown
finish
