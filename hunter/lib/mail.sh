# mail.sh - cela fotka-pipeline: najit kandidaty, pockat na novy snimek,
# sestavit predmet/telo, odeslat. Detekce noveho snimku a odeslani jsou
# tady spolu zamerne - obe pracuji nad stejnou mnozinou "snaps/ minus
# sent_list.txt" a rozdeleni do dvou souboru by jen rozjelo definici
# "kandidat" na dve mista.
#
# Zadne hlidani slozky pres inotify - busybox ho nema (viz spec sekce 5).
# Detekce je rozdil mnozin omezeny cursorem: kandidati = snaps/<YYMMDD
# OD CURSORU DAL>/*.jpg - sent_list.txt, kazdy proveren snapready (viz
# test_files/snapready.c) na kompletnost. Presne DVE urovne, ne "**" -
# den musi byt slozka s nazvem presne 6 cislic (overeno snap_num6),
# soubory primo v ni. Skenuje se globem, ne findem (viz nize), takze
# cokoli hloubeji nebo v jinak pojmenovane slozce je pro automatiku i
# pro day_fully_sent neviditelne. Predpoklad plocheho stromu je od
# spec 2026-09-02 zavazny, ne uz jen nahodny - viz tamtez.

# list_unsent_snaps <jen_kompletni>
# Spolecny chodec po dnech pro find_ready_candidates (bezna detekce
# kandidatu) i CLEAR QUEUE (spec 2026-09-03, oprava omezeni 9.3 bod 3).
# Vypise (radek na soubor) cesty ke snimkum ode dne cursoru dal, ktere
# jeste nejsou v sent_list.txt.
#   1 = jen soubory, ktere pousti snapready (bezna detekce kandidatu)
#   0 = vsechny nedoslane, i nekompletni (CLEAR QUEUE - viz nize)
#
# Prochazi jen dny OD CURSORU dal (spec 2026-09-02, sekce 3) - starsi
# dny jsou vyrizene a znovu se do nich nekouka. To je duvod, proc tohle
# neroste s celkovym poctem fotek na karte, ale jen s tim, co pribylo.
#
# Druha polovina zrychleni: JEDEN fgrep na den misto jednoho na soubor.
# Puvodni verze spoustela novy proces pro kazdy soubor, coz pri tisicich
# fotek delalo tisice forku na probuzeni. Podminka na _ready_only je
# obycejny `[ ]` test, zadny subshell - na hotem case (az 25x za
# probuzeni, jednou na den) tim nesmi pribyt zadny dalsi fork.
#
# Vystup je chronologicky VZESTUPNY (glob nad YYMMDD i nad HHMMSS_...
# radi lexikograficky, coz je tady zaroven chronologicky). MAX_QUEUE na
# to spoleha, kdyz odrezava nejstarsi.
list_unsent_snaps() {
    _ready_only="$1"
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
            if [ "$_ready_only" = 1 ]; then
                "$HUNTER_DIR/bin/snapready" "$_f" >/dev/null 2>&1 || continue
            fi
            printf '%s\n' "$_f"
        done
    done
}

# find_ready_candidates
# Vypise (radek na soubor) cesty ke snimkum, ktere jeste nejsou v
# sent_list.txt a jsou kompletni. Jen tenky wrapper nad
# list_unsent_snaps 1 - signatura i chovani beze zmeny, takze vsichni
# dnesni volajici (wait_for_candidates, build_status_reply) a vsechny
# stavajici testy zustavaji netknute.
find_ready_candidates() { list_unsent_snaps 1; }

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
        # Optimalizace, ne pojistka: vynechani nejnovejsiho dne tu jen
        # usetri jeden zbytecny day_fully_sent na dni, ktery uz vime, ze
        # se nikdy neuzavre. I bez tohohle radku by vysledek byl stejny -
        # "cursor nikdy nepredbehne nejnovejsi den" hlida vyhradne vetev
        # "else _new=$_newest" nize, pouzita kdyz _open zustane prazdne.
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

    # Zasekly den: nejstarsi otevreny den je presne ten, na kterem uz
    # cursor stoji (tenhle beh se tedy vubec nepohne), a existuje novejsi
    # den. Prohledavane okno (find_ready_candidates, day_fully_sent) tim
    # roste o dalsi slozku pri kazdem dalsim dni na karte - ne o "jeden
    # den navic za probuzeni", jak drive tvrdil spec 9.3 bod 3 (viz
    # oprava tamtez - CLEAR QUEUE tohle neresi). Loguje se nejvys
    # jednou za beh (cursor_advance bezi jednou za probuzeni), aby
    # operator videl rostouci okno v log.txt misto aby ho odvodil az z
    # pomaleho probuzeni. Na normalni ceste "cursor uz je na nejnovejsim
    # dni, neni co dohanet" (_open zustava prazdne) se tahle podminka
    # nikdy nesplni.
    if [ -n "$_cur" ] && [ "$_open" = "$_cur" ] && [ "$_newest" -gt "$_cur" ]; then
        _scanned=0
        for _d in $(list_snap_days); do
            snap_num6 "$_d" || continue
            [ "$_d" -lt "$_cur" ] && continue
            _scanned=$((_scanned + 1))
        done
        log "cursor zasekly na $_cur (existuje novejsi den $_newest) - prochazi se $_scanned slozek dne"
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

# send_via_smtp <komu> <predmet> <telo> [priloha]
send_via_smtp() {
    if [ -n "$4" ]; then
        mailsend_run \
            --host "$SMTP_HOST" --port "$SMTP_PORT" \
            --user "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
            --to "$1" --subject "$2" --body "$3" --attach "$4" \
            --tls "$SMTP_TLS" \
            >> "$LOG_FILE" 2>&1
    else
        mailsend_run \
            --host "$SMTP_HOST" --port "$SMTP_PORT" \
            --user "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
            --to "$1" --subject "$2" --body "$3" \
            --tls "$SMTP_TLS" \
            >> "$LOG_FILE" 2>&1
    fi
}

# send_via_imap <slozka> <komu> <predmet> <telo> [priloha]
# Ulozi zpravu pres IMAP APPEND do zadane slozky na tomtez uctu. Slozka
# je parametr, ne globalka - volajici (send_message) vzdy rekne, kam to
# ma jit, takze fotky a odpovedi se nemuzou omylem zamenit. Neni to
# odeslani - zprava se objevi ve slozce, ne ve schrance.
send_via_imap() {
    if [ -n "$5" ]; then
        mailrecv_run append "$1" \
            --from "$SMTP_USER" --to "$2" --subject "$3" --body "$4" \
            --attach "$5" \
            >> "$LOG_FILE" 2>&1
    else
        mailrecv_run append "$1" \
            --from "$SMTP_USER" --to "$2" --subject "$3" --body "$4" \
            >> "$LOG_FILE" 2>&1
    fi
}

# send_message <komu> <predmet> <telo> <priloha> <imap_slozka>
# Odesle zpravu podle SEND_TRANSPORT. <priloha> smi byt prazdna.
# <imap_slozka> urcuje cil pro vetve pouzivajici IMAP - send_snap
# preda IMAP_SAVE_FOLDER, send_reply_mail preda IMAP_REPLY_FOLDER.
# SMTP vetve pate parametry ignoruji.
#
# Vraci 0, kdyz uspel ASPON JEDEN zvoleny transport (spec 4.1) - kdyby
# se u smtp+imap vyzadovaly oba, vypadek IMAPu by donekonecna
# preposilal fotku, kterou uzivatel uz ma.
send_message() {
    case "$SEND_TRANSPORT" in
        smtp)
            send_via_smtp "$1" "$2" "$3" "$4"
            ;;
        imap)
            send_via_imap "$5" "$1" "$2" "$3" "$4"
            ;;
        smtp-imap)
            send_via_smtp "$1" "$2" "$3" "$4" && return 0
            log "SMTP selhalo, zkousim ulozit pres IMAP"
            send_via_imap "$5" "$1" "$2" "$3" "$4"
            ;;
        imap-smtp)
            send_via_imap "$5" "$1" "$2" "$3" "$4" && return 0
            log "IMAP selhalo, zkousim poslat mailem"
            send_via_smtp "$1" "$2" "$3" "$4"
            ;;
        smtp+imap)
            _sm_ok=1
            send_via_smtp "$1" "$2" "$3" "$4" && _sm_ok=0
            send_via_imap "$5" "$1" "$2" "$3" "$4" && _sm_ok=0
            return "$_sm_ok"
            ;;
        *)
            # validate_transport tohle nema propustit; kdyby ano, at to
            # aspon nekonci tise.
            log "SEND_TRANSPORT neznama hodnota v send_message, pouzivam smtp"
            send_via_smtp "$1" "$2" "$3" "$4"
            ;;
    esac
}

# send_snap <cesta>
# Odesle jeden snimek podle SEND_TRANSPORT (viz send_message vyse).
# Vraci 0, kdyz aspon jeden zvoleny transport uspel. Volajici smi
# pripsat do sent_list.txt JEN pri navratu 0 - viz spec sekce 6 (nikdy
# stav "oznaceno jako odeslane, ale nedorazilo"). Do sent_list.txt patri
# VZDY cesta ze snaps/ (kanonicka identita snimku), bez ohledu na to,
# ktera kvalita se skutecne poslala.
send_snap() {
    snap_path="$1"
    fname=$(basename "$snap_path")
    daydir=$(basename "$(dirname "$snap_path")")
    hhmmss="${fname%%_*}"
    subject=$(format_subject "$daydir" "$hhmmss")
    body=$(build_status_body)
    attach_path=$(resolve_attach_path "$snap_path" "$daydir" "$fname")
    log "kvalita: QUALITY=$QUALITY, priloha=$attach_path"

    send_message "$SMTP_TO" "$subject" "$body" "$attach_path" "$IMAP_SAVE_FOLDER"
}

# send_reply_mail <komu> <text>
# Odpoved na prikaz, jde stejnym dispecerem jako fotky (spec 3) - jedno
# nastaveni SEND_TRANSPORT tak plati pro obe a nemuze se rozejit. V
# IMAP vetvich konci ve vlastni slozce (IMAP_REPLY_FOLDER), oddelene od
# fotek - viz validate_transport pro vychozi hodnotu.
# Predmet je VZDY "HUNTER reply" - prichozi predmet se NIKDY necituje,
# protoze je v nem token.
send_reply_mail() {
    send_message "$1" "HUNTER reply" "$2" "" "$IMAP_REPLY_FOLDER"
}
