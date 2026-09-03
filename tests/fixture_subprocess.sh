# tests/fixture_subprocess.sh - stavi izolovanou kopii CELEHO adresare
# hunter/ (hunter.sh + lib/) a spousti ji jako SKUTECNY podproces
# (dash hunter.sh), na rozdil od tests/fixture.sh, ktere jen zdrojuje
# lib/*.sh primo do bezicho testovaciho shellu.
#
# Proc dva ruzne pristupy: slucovaci/dedup/stropovaci/odesilaci smycka v
# hunter.sh NENI zabalena do funkce (je to primo telo orchestracniho
# skriptu, viz konec hunter.sh) - jedine spolehlive overeni jeji
# SKUTECNE zapojene logiky (vc. poradi kroku a globalnich promennych
# jako REQUESTED_SNAPS/STOPPED_APP/APP_PID) je spustit hunter.sh jako
# opravdovy proces, ne prepisovat useky jeho kodu znovu do testu (to by
# testovalo kopii, ne realitu, a casem by se od sebe mohly rozejit).
#
# hunter.sh natvrdo nastavuje SDCARD=/tmp/mnt/sdcard (skutecny mountpoint
# na zarizeni) - v IZOLOVANE KOPII skriptu (nikdy v repozitari!) se tenhle
# radek prepise na docasny testovaci sdcard pres sed, ciste pro ucely
# testu na vyvojovem/CI stroji (sed neni soucasti toho, co bezi na
# zarizeni - tam se pouziva jen puvodni, nezmeneny hunter.sh).
#
# Fake "pidof" bezi jako SAMOSTATNY spustitelny soubor v $FIX/fakebin,
# ktery se predsadi do PATH - `pidof` je v hunter.sh volany jako beznyy
# externi prikaz (na rozdil od `kill`, ktery je v dash builtin a nejde
# takhle prepsat zvenku). Kdyz test potrebuje realne overit SIGSTOP/
# SIGCONT (ne jen "nespadlo to"), fake pidof vraci PID skutecneho
# pozadi-beziciho procesu (napr. `sleep 600 &`), aby `kill -STOP/-CONT`
# mely co delat a nehlasily chybu na neexistujici PID.

# subproc_fixture_setup <MAX_SEND_PER_WAKE> [REQUEST_MAX]
# Vytvori $FIX/hunter (kopie hunter.sh+lib, s prepsanym SDCARD),
# $FIX/sdcard (SDCARD), fake bin/ nastroje vracejici "nic se nedeje"
# vychozi hodnoty (zadne SMS, zadny mail, ubia_first nebezi). Konkretni
# scenar (mail_listing.txt, sms_listing.txt, snapky) si doplni volajici
# test sam pred volanim subproc_run_hunter.
#
# REQUEST_MAX je parametr, protoze load_config vynucuje invariant
# MAX_SEND_PER_WAKE >= REQUEST_MAX (viz lib/common.sh) - scenar, ktery
# chce testovat NIZKY strop na probuzeni, musi snizit i REQUEST_MAX,
# jinak by mu load_config strop zvedl zpatky. Vychozi hodnota je stejna
# jako strop, aby fixture nikdy invariant neporusila sama od sebe.
subproc_fixture_setup() {
    max_send="${1:-3}"
    req_max="${2:-$max_send}"

    SROOT=$(cd "$(dirname "$0")/.." && pwd)
    FIX=$(mktemp -d)
    HDIR="$FIX/hunter"
    SDCARD="$FIX/sdcard"
    mkdir -p "$HDIR/lib" "$HDIR/bin" "$HDIR/state" "$SDCARD/snaps" "$FIX/fakebin"

    cp "$SROOT/hunter/hunter.sh" "$HDIR/hunter.sh"
    cp "$SROOT/hunter/lib/"*.sh "$HDIR/lib/"
    sed -i "s#^SDCARD=.*#SDCARD=\"$SDCARD\"#" "$HDIR/hunter.sh"

    cat > "$HDIR/config.txt" <<EOF
MASTERS=+420603284430
MAIL_MASTERS=paja.stindl@seznam.cz
QUALITY=LOW
CONFIRM=ON
AUTH_TYPE=TOKEN
SMTP_HOST=smtp.example.cz
SMTP_PORT=465
SMTP_USER=fotopast@example.cz
SMTP_TO=paja.stindl@seznam.cz
SMTP_TLS=implicit
IMAP_HOST=imap.example.cz
IMAP_PORT=993
AT_PORT=/dev/null
AT_BAUD=115200
SNAP_WAIT=1
MAX_SEND_PER_WAKE=$max_send
REQUEST_MAX=$req_max
RUN_DEADLINE=30
EOF

    printf 'tajnytoken1\n' > "$HDIR/mail.token"
    printf 'fakepass\n' > "$HDIR/smtp.pass"

    printf '#!/bin/sh\nexit 0\n' > "$HDIR/bin/snapready"
    chmod +x "$HDIR/bin/snapready"
    printf '#!/bin/sh\nexit 1\n' > "$HDIR/bin/atcmd"
    chmod +x "$HDIR/bin/atcmd"

    # vychozi: zadna SMS
    printf '#!/bin/sh\nexit 0\n' > "$HDIR/bin/smsrecv"
    chmod +x "$HDIR/bin/smsrecv"
    cat > "$HDIR/bin/smssend" <<EOF
#!/bin/sh
echo "\$@" >> "$FIX/smssent.log"
exit 0
EOF
    chmod +x "$HDIR/bin/smssend"

    # mailrecv cte z $FIX/mail_listing.txt (vychozi prazdny = zadny mail)
    : > "$FIX/mail_listing.txt"
    : > "$FIX/append.log"
    cat > "$HDIR/bin/mailrecv" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/mail_listing.txt" 2>/dev/null; exit 0 ;;
    seen) shift; echo "\$@" >> "$FIX/mail_seen.log"; exit 0 ;;
    append) echo "\$@" >> "$FIX/append.log"; exit \$(cat "$FIX/append_rc" 2>/dev/null || echo 0) ;;
  esac
done
exit 0
EOF
    chmod +x "$HDIR/bin/mailrecv"

    cat > "$HDIR/bin/mailsend" <<EOF
#!/bin/sh
echo "\$@" >> "$FIX/mailsend.log"
exit \$(cat "$FIX/mailsend_rc" 2>/dev/null || echo 0)
EOF
    chmod +x "$HDIR/bin/mailsend"

    # vychozi: ubia_first "nebezi" (pidof nic nevrati) - scenare, ktere
    # potrebuji realne overit SIGSTOP/SIGCONT, si fake pidof pretvori
    # samy (viz subproc_use_real_pid).
    cat > "$FIX/fakebin/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$FIX/fakebin/pidof"
}

# subproc_mk_snap <YYMMDD> <HHMMSS>
subproc_mk_snap() {
    mkdir -p "$SDCARD/snaps/$1"
    printf 'jpegdata' > "$SDCARD/snaps/$1/${2}_000_65535_P.jpg"
}

# subproc_use_real_pid
# Prepne fake pidof na skutecny PID pozadi bezicicho `sleep`, aby
# ensure_app_frozen opravdu mohla provest SIGSTOP/SIGCONT (a testy tak
# mohly overit skutecnou idempotenci mezi vice volacimi misty, ne jen
# "nespadlo to bez ubia_first"). Uklizi se pres subproc_kill_real_pid.
subproc_use_real_pid() {
    sleep 600 &
    SUBPROC_REAL_PID=$!
    printf '%s\n' "$SUBPROC_REAL_PID" > "$FIX/pidfile"
    cat > "$FIX/fakebin/pidof" <<EOF
#!/bin/sh
cat "$FIX/pidfile" 2>/dev/null
exit 0
EOF
    chmod +x "$FIX/fakebin/pidof"
}

subproc_kill_real_pid() {
    [ -n "${SUBPROC_REAL_PID:-}" ] && kill -KILL "$SUBPROC_REAL_PID" 2>/dev/null
    SUBPROC_REAL_PID=""
}

# subproc_run_hunter - spusti izolovanou kopii hunter.sh jako podproces.
# stdout/stderr se zachyti do $FIX/stdout.log a $FIX/stderr.log pro
# pripadnou diagnostiku (napr. kdyz test selze).
subproc_run_hunter() {
    PATH="$FIX/fakebin:$PATH" dash "$HDIR/hunter.sh" >"$FIX/stdout.log" 2>"$FIX/stderr.log"
}

subproc_fixture_teardown() {
    subproc_kill_real_pid
    [ -n "${FIX:-}" ] && rm -rf "$FIX"
}
