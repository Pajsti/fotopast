# mail.sh - cela fotka-pipeline: najit kandidaty, pockat na novy snimek,
# sestavit predmet/telo, odeslat. Detekce noveho snimku a odeslani jsou
# tady spolu zamerne - obe pracuji nad stejnou mnozinou "snaps/ minus
# sent_list.txt" a rozdeleni do dvou souboru by jen rozjelo definici
# "kandidat" na dve mista.
#
# Zadne hlidani slozky pres inotify - busybox ho nema (viz spec sekce 5).
# Detekce je rozdil mnozin omezeny cursorem: kandidati = snaps/<den
# OD CURSORU DAL>/**/*.jpg - sent_list.txt, kazdy proveren snapready
# (viz test_files/snapready.c) na kompletnost.

# find_ready_candidates
# Vypise (radek na soubor) cesty ke snimkum, ktere jeste nejsou v
# sent_list.txt a jsou kompletni.
#
# Prochazi jen dny OD CURSORU dal (spec 2026-09-02, sekce 3) - starsi
# dny jsou vyrizene a znovu se do nich nekouka. To je duvod, proc tohle
# neroste s celkovym poctem fotek na karte, ale jen s tim, co pribylo.
#
# Druha polovina zrychleni: JEDEN fgrep na den misto jednoho na soubor.
# Puvodni verze spoustela novy proces pro kazdy soubor, coz pri tisicich
# fotek delalo tisice forku na probuzeni.
#
# Vystup je chronologicky VZESTUPNY (glob nad YYMMDD i nad HHMMSS_...
# radi lexikograficky, coz je tady zaroven chronologicky). MAX_QUEUE na
# to spoleha, kdyz odrezava nejstarsi.
find_ready_candidates() {
    _cur=$(cursor_read)
    [ -n "$_cur" ] || return 0
    _nl='
'

    for _d in $(list_snap_days); do
        snap_num6 "$_d" || continue
        [ "$_d" -lt "$_cur" ] && continue

        _slice=""
        if [ -f "$STATE_DIR/sent_list.txt" ]; then
            _slice=$(fgrep "/snaps/$_d/" "$STATE_DIR/sent_list.txt" 2>/dev/null)
        fi

        for _f in "$SDCARD/snaps/$_d"/*.jpg; do
            [ -f "$_f" ] || continue
            case "$_nl$_slice$_nl" in
                *"$_nl$_f$_nl"*) continue ;;
            esac
            if "$HUNTER_DIR/bin/snapready" "$_f" >/dev/null 2>&1; then
                printf '%s\n' "$_f"
            fi
        done
    done
}

# day_fully_sent <YYMMDD>
# 0, kdyz je KAZDY *.jpg toho dne v sent_list.txt.
#
# Ridi se VYHRADNE clenstvim v sent_list.txt, ne kandidaturou. Soubor,
# ktery snapready odmita (neuplny, poskozeny), tedy den drzi otevreny -
# schvalne: "neumim ho poslat" neni totez co "je vyrizeny"
# (spec 2026-09-02, 3.2 a omezeni 9.3).
day_fully_sent() {
    _d="$1"
    _nl='
'
    _slice=""
    if [ -f "$STATE_DIR/sent_list.txt" ]; then
        _slice=$(fgrep "/snaps/$_d/" "$STATE_DIR/sent_list.txt" 2>/dev/null)
    fi

    for _f in "$SDCARD/snaps/$_d"/*.jpg; do
        [ -f "$_f" ] || continue
        case "$_nl$_slice$_nl" in
            *"$_nl$_f$_nl"*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# cursor_advance
# Posune cursor na nejstarsi den, ktery jeste neni cely odeslany -
# nejvys ale na NEJNOVEJSI existujici den, ten se neuzavira nikdy.
#
# Podminka "existuje novejsi slozka dne" je zamerne strukturalni, ne
# podle hodin: hodiny zarizeni nemaji zalohovany RTC a mezi probuzenimi
# plavou (spec 2026-08-27, 2.1). Do nejnovejsi slozky se porad zapisuje,
# takze rozepsany snimek nemuze propadnout.
#
# Cursor se nikdy neposouva ZPET - jen tak ma "tenhle den je vyrizeny"
# trvalou platnost.
cursor_advance() {
    _newest=""
    for _d in $(list_snap_days); do
        snap_num6 "$_d" || continue
        if [ -z "$_newest" ] || [ "$_d" -gt "$_newest" ]; then
            _newest="$_d"
        fi
    done
    [ -n "$_newest" ] || return 0

    _cur=$(cursor_read)

    _open=""
    for _d in $(list_snap_days); do
        snap_num6 "$_d" || continue
        [ "$_d" -ge "$_newest" ] && continue
        [ -n "$_cur" ] && [ "$_d" -lt "$_cur" ] && continue
        day_fully_sent "$_d" && continue
        if [ -z "$_open" ] || [ "$_d" -lt "$_open" ]; then
            _open="$_d"
        fi
    done

    if [ -n "$_open" ]; then
        _new="$_open"
    else
        _new="$_newest"
    fi

    [ -n "$_cur" ] && [ "$_new" -le "$_cur" ] && return 0
    cursor_write "$_new"
    log "cursor posunut na $_new"
}

# wait_for_candidates
# Sjednocuje "dozenani nedodelku" a "cekani na novy snimek z tohoto
# probuzeni" do jedine smycky: pri kazdem kole hleda kandidaty, a jakmile
# nejaky najde (treba uz existujici nedodelek), okamzite konci - zbytecne
# necekat, kdyz uz je co poslat. Kdyz nic neni, pooli do SNAP_WAIT (nebo
# do celkoveho RUN_DEADLINE, podle toho, co nastane driv), pak vraci
# prazdno a hlavni beh pokracuje bez odesilani.
#
# Vystup: seznam pripravenych cest (radek na soubor) na stdout, exit 0
# kdyz neco naslo, exit 1 kdyz nic do vyprseni casu.
wait_for_candidates() {
    deadline=$(($(date +%s) + SNAP_WAIT))

    while :; do
        candidates=$(find_ready_candidates)
        if [ -n "$candidates" ]; then
            printf '%s\n' "$candidates"
            return 0
        fi

        now=$(date +%s)
        [ "$now" -ge "$deadline" ] && return 1
        [ "$now" -ge "$RUN_DEADLINE_TS" ] && return 1
        sleep 1
    done
}

# format_subject <YYMMDD> <HHMMSS>
# "260827" + "153012" -> "26/08/27 15:30:12". Rozklad na dvojice znaku
# jen pres parametrickou expanzi (#/%) - zadne substring rezy, ty ash
# nema (to je bashismus).
format_subject() {
    d="$1"
    t="$2"

    yy="${d%????}"
    rest="${d#??}"
    mm="${rest%??}"
    dd="${d#????}"

    hh="${t%????}"
    rest2="${t#??}"
    mi="${rest2%??}"
    ss="${t#????}"

    printf '%s/%s/%s %s:%s:%s' "$yy" "$mm" "$dd" "$hh" "$mi" "$ss"
}

# resolve_attach_path <snap_path> <daydir> <fname>
# QUALITY=HD posila z HDPIC/ (nekomprimovana verze), jinak (vcetne
# vychoziho LOW) ze snaps/ (uz komprimovana appkou). Parovani je dane
# formatem retezcu primo v ubia_first (overeno rozborem binarky
# 2026-08-31): snaps/<den>/<jmeno>.jpg <-> HDPIC/<den>/<jmeno>H.jpg -
# stejny den i jmeno, jen slozka a "H" pred priponou navic.
# Kdyz HD varianta chybi nebo neni kompletni (snapready), tise se
# spadne zpet na snaps/ verzi - nikdy neselhat kvuli chybejicimu HD.
resolve_attach_path() {
    snap_path="$1"
    daydir="$2"
    fname="$3"

    if [ "$QUALITY" != "HD" ]; then
        printf '%s' "$snap_path"
        return
    fi

    hd_fname="${fname%.jpg}H.jpg"
    hd_path="$SDCARD/HDPIC/$daydir/$hd_fname"

    if [ -f "$hd_path" ] && "$HUNTER_DIR/bin/snapready" "$hd_path" >/dev/null 2>&1; then
        printf '%s' "$hd_path"
    else
        printf '%s' "$snap_path"
    fi
}

# mailsend_run <argumenty...>
# Obalka nad bin/mailsend: doplni --ca JEN kdyz je CA_FILE neprazdny.
# Prazdny CA_FILE musi znamenat, ze se --ca neposila vubec - prazdny
# retezec by mailsend vzal jako cestu k souboru a odeslani by skoncilo
# chybou "nepodarilo se nacist CA soubor". Stejna obalka jako
# mailrecv_run v lib/mailcmd.sh.
mailsend_run() {
    if [ -n "$CA_FILE" ]; then
        "$HUNTER_DIR/bin/mailsend" --ca "$CA_FILE" "$@"
    else
        "$HUNTER_DIR/bin/mailsend" "$@"
    fi
}

# send_snap <cesta>
# Odesle jeden snimek e-mailem. Vraci navratovy kod mailsend (0 =
# potvrzeno serverem). Volajici smi pripsat do sent_list.txt JEN pri
# navratu 0 - viz spec sekce 6 (nikdy stav "oznaceno jako odeslane, ale
# nedorazilo"). Do sent_list.txt patri VZDY cesta ze snaps/ (kanonicka
# identita snimku), bez ohledu na to, ktera kvalita se skutecne poslala.
send_snap() {
    snap_path="$1"
    fname=$(basename "$snap_path")
    daydir=$(basename "$(dirname "$snap_path")")
    hhmmss="${fname%%_*}"
    subject=$(format_subject "$daydir" "$hhmmss")
    body=$(build_status_body)
    attach_path=$(resolve_attach_path "$snap_path" "$daydir" "$fname")
    log "kvalita: QUALITY=$QUALITY, priloha=$attach_path"

    mailsend_run \
        --host "$SMTP_HOST" --port "$SMTP_PORT" \
        --user "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
        --to "$SMTP_TO" --subject "$subject" \
        --body "$body" --attach "$attach_path" \
        --tls "$SMTP_TLS" \
        >> "$LOG_FILE" 2>&1
}

# send_reply_mail <komu> <text>
# Odpoved na prikaz. Predmet je VZDY "HUNTER reply" - prichozi predmet
# se NIKDY necituje, protoze je v nem token.
send_reply_mail() {
    to="$1"
    text="$2"
    mailsend_run \
        --host "$SMTP_HOST" --port "$SMTP_PORT" \
        --user "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
        --to "$to" --subject "HUNTER reply" \
        --body "$text" \
        --tls "$SMTP_TLS" \
        >> "$LOG_FILE" 2>&1
}
