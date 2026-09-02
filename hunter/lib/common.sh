# common.sh - log, atomicke zapisy, zamek, konfigurace, drobne shellove
# pomocniky. Zdrojuje se z hunter.sh, ne spousti primo.
#
# DULEZITE: busybox na zarizeni NEMA awk, sed, cut, sort, uniq, wc, head,
# tail, expr, tee ani bc (overeno primo v binarce, ne jen podle symlinku
# v /bin). Cely Hunter proto pouziva jen: case, parametricka expanze
# ${var#...}/${var%...}, $(( )), read, trap - a z appletu jen grep/fgrep,
# tr, printf, find, stat, df, dd, date, mkdir, mv, rm, cp, touch, sleep,
# kill, pidof.
#
# DULEZITE (MIPS): SIGSTOP/SIGCONT maji na MIPS JINA cisla nez na
# x86/ARM. Signaly se proto v celem Hunteru volaji vzdycky JMENEM
# (kill -STOP, kill -CONT, trap ... INT TERM HUP), nikdy cislem.

# log <text...>
# Zapise radek do LOG_FILE s casovym razitkem. LOG_FILE musi byt jiz
# nastaveny volajicim (hunter.sh ho nastavuje pred prvnim pouzitim).
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# rotate_log_if_needed
# Bez wc/du merime velikost pres `stat -c %s`. Pri prekroceni 1 MB se
# stary log prepise na log.txt.old (jedna generace zpetne staci - Hunter
# beh trva sekundy, log neroste rychle).
rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null)
    case "$size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "$size" -gt 1048576 ]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null
    fi
}

# acquire_lock
# Zamek pres mkdir (atomicka operace i na FAT/exFAT). Kdyz adresar zamku
# existuje po vypadku napajeni z minuleho behu, PID v nem uz nebezi
# (kazdy boot ma nova PID) - takovy zamek se bezpecne prevezme.
acquire_lock() {
    lockdir="$STATE_DIR/.lock"
    if mkdir "$lockdir" 2>/dev/null; then
        echo $$ > "$lockdir/pid" 2>/dev/null
        return 0
    fi
    if [ -f "$lockdir/pid" ]; then
        oldpid=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$oldpid" ] && ! kill -0 "$oldpid" 2>/dev/null; then
            rm -rf "$lockdir" 2>/dev/null
            if mkdir "$lockdir" 2>/dev/null; then
                echo $$ > "$lockdir/pid" 2>/dev/null
                return 0
            fi
        fi
    fi
    return 1
}

release_lock() {
    rm -rf "$STATE_DIR/.lock" 2>/dev/null
}

# trim <retezec>
# Osekne uvodni a koncove mezery/taby. Bez sed - po jednom znaku pres
# case, ale retezce jsou kratke (SMS max 160 znaku), takze O(n) nevadi.
trim() {
    s="$1"
    # tab pres $(printf) misto literalu v souboru - literalni tabulatory
    # v tomto zdrojaku se pri prenosu po UART ztraceji (busybox ash je
    # i uprostred heredocu bere jako doplnovani prikazu, viz spec).
    tb="$(printf '\t')"
    while :; do
        case "$s" in
            " "*|"$tb"*) s="${s#?}" ;;
            *) break ;;
        esac
    done
    while :; do
        case "$s" in
            *" "|*"$tb") s="${s%?}" ;;
            *) break ;;
        esac
    done
    printf '%s' "$s"
}

# normalize_phone <cislo>
# Odstrani mezery a pomlcky, aby "+420 603 284 430" a "+420603284430"
# byly totozne pri porovnavani s MASTERS.
normalize_phone() {
    printf '%s' "$1" | tr -d ' -'
}

# atomic_write_file <cesta> <obsah>
# Zapis pres docasny soubor + sync + mv. Pouziva se pro PREPIS celeho
# souboru (config.txt) - proste pripojeni radku (sent_list.txt,
# sms_seen.txt) staci resit `>> soubor; sync`, protoze pripojeni
# neriskuje ztratu uz existujiciho obsahu, jen posledniho radku.
atomic_write_file() {
    path="$1"
    content="$2"
    tmp="${path}.tmp.$$"
    printf '%s' "$content" > "$tmp" || return 1
    sync
    mv -f "$tmp" "$path" || return 1
    sync
    return 0
}

# set_config_value <KLIC> <HODNOTA>
# Prepise (nebo prida) KLIC=HODNOTA v config.txt, ostatni radky beze
# zmeny. Atomicky pres docasny soubor. `case` pattern matching resi
# "najdi radek zacinajici na KLIC=" bez sed.
#
# POZOR - DUVERNI HRANICE: config.txt nacita load_config pres `.`, takze
# argument HODNOTA se pri pristim behu VYHODNOTI JAKO SHELL. Kdo sem
# pousti text od uzivatele (ADD/REMOVE v lib/command.sh), musi ho nejdriv
# profiltrovat znakovym seznamem povolenych znaku - jinak je to spusteni
# libovolneho prikazu, nebo (u nesparovane uvozovky) trvale rozbity
# config, ktery uz nikdy nepujde nacist.
set_config_value() {
    key="$1"
    val="$2"
    tmp="${CONFIG_FILE}.tmp.$$"
    found=0

    : > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                printf '%s=%s\n' "$key" "$val" >> "$tmp"
                found=1
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp"
                ;;
        esac
    done < "$CONFIG_FILE"

    if [ "$found" = 0 ]; then
        printf '%s=%s\n' "$key" "$val" >> "$tmp"
    fi

    sync
    mv -f "$tmp" "$CONFIG_FILE"
    sync
}

# snap_num6 <retezec>
# 0, kdyz je vstup presne 6 cislic. Pouziva se na overeni YYMMDD i
# HHMMSS - obe casti cesty ke snimku, a taky nazvy slozek dnu.
# Sestimistne cislo (max 999999) se vejde do 32bitove aritmetiky, takze
# se pak da porovnavat pres -gt/-lt.
snap_num6() {
    case "$1" in [0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;; esac
    return 1
}

# list_snap_days
# Vypise nazvy slozek dnu v snaps/ (jen jmeno, ne cesta), jeden na
# radek. Pouziva se glob, ne find - glob je serazeny lexikograficky, coz
# je u YYMMDD zaroven chronologicky, a nestoji ani jeden fork.
# Nazvy dnu neobsahuji mezery, takze u volajiciho staci bezne deleni
# slov, zadne hratky s IFS.
list_snap_days() {
    for _lsd in "$SDCARD"/snaps/*/; do
        [ -d "$_lsd" ] || continue
        _lsd=${_lsd%/}
        printf '%s\n' "${_lsd##*/}"
    done
}

# cursor_read
# Vypise den (YYMMDD), od ktereho ma automatika hledat kandidaty.
#
# Chybejici, prazdny nebo poskozeny state/cursor.txt znamena "od
# nejstarsiho dne na karte" - tedy presne dnesni chovani. Diky tomu
# nepotrebuje zive nasazeni zadny rucni migracni krok (spec 2026-09-02,
# sekce 3.4).
#
# Cursor se nikdy neposune pres nejnovejsi slozku dne na karte (spec
# 2026-09-02) - hodnota novejsi nez nejnovejsi den je proto nemozny stav,
# stejne neduveryhodny jako poskozeny soubor, a resi se identicky: NEklampuje
# se na nejnovejsi den (to by tise preskocilo vsechny dny mezi skutecnou
# pozici a nejnovejsim), ale spadne az na nejstarsi den. Jednorazovy plny
# rescan je levny a sent_list.txt porad dedupuje, takze nehrozi duplicitni
# odeslani.
cursor_read() {
    _cur=""
    if [ -f "$STATE_DIR/cursor.txt" ]; then
        read -r _cur < "$STATE_DIR/cursor.txt" 2>/dev/null
    fi
    snap_num6 "$_cur" || _cur=""

    _oldest=""
    _newest=""
    for _d in $(list_snap_days); do
        snap_num6 "$_d" || continue
        if [ -z "$_oldest" ] || [ "$_d" -lt "$_oldest" ]; then
            _oldest="$_d"
        fi
        if [ -z "$_newest" ] || [ "$_d" -gt "$_newest" ]; then
            _newest="$_d"
        fi
    done

    if [ -n "$_cur" ] && [ -n "$_newest" ] && [ "$_cur" -gt "$_newest" ]; then
        _cur=""
    fi
    [ -z "$_cur" ] && _cur="$_oldest"

    printf '%s' "$_cur"
}

# cursor_write <YYMMDD>
cursor_write() {
    printf '%s\n' "$1" > "$STATE_DIR/cursor.txt"
    sync
}

# load_config
# config.txt je platny POSIX shell (KLIC=HODNOTA, komentare #), takze se
# naimportuje primo pres `.` - zadny vlastni parser netreba. Vyplni
# chybejici nepovinne klice vychozimi hodnotami.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "CHYBA: chybi $CONFIG_FILE, koncim"
        exit 1
    fi
    . "$CONFIG_FILE"

    : "${MASTERS:=}"
    : "${QUALITY:=HD}"
    : "${CONFIRM:=ON}"
    : "${SMTP_TLS:=starttls}"
    : "${AT_BAUD:=115200}"
    : "${SNAP_WAIT:=25}"
    : "${MAX_SEND_PER_WAKE:=3}"
    : "${RUN_DEADLINE:=180}"
    : "${AUTH_TYPE:=TOKEN}"
    : "${MAIL_MASTERS:=}"
    : "${REQUEST_MAX:=5}"
    : "${IMAP_PORT:=993}"
    : "${TOKEN_FILE:=$HUNTER_DIR/mail.token}"
    # CA svazek pro overeni certifikatu SMTP/IMAP serveru. PRAZDNY je
    # vychozi stav: bez nej je spojeni sifrovane, ale identita serveru se
    # neoveruje (mailsend/mailrecv na to samy varuji na stderr). Kdyz je
    # nastaveny, preda se obema klientum jako --ca. Zamerne se nevynucuje,
    # aby uz bezici instalace bez CA svazku na karte fungovaly dal.
    : "${CA_FILE:=}"

    # Vyzadane fotky jdou v davce prvni; kdyby byl strop nizsi nez
    # REQUEST_MAX, vytlacily by automaticke kandidaty a cast vyzadanych by
    # se ztratila (REQUESTED_SNAPS se mezi probuzenimi neuchovava) - a to
    # tise, protoze odpoved uzivateli uz rekla "SENDING N". Pravidlo je
    # popsane v config.txt.example i v CHECKLISTu; tady se opravdu
    # vynucuje, at uz ho porusi vychozi hodnoty nebo rucne editovany
    # config.
    [ "$MAX_SEND_PER_WAKE" -lt "$REQUEST_MAX" ] && MAX_SEND_PER_WAKE="$REQUEST_MAX"

    for req in SMTP_HOST SMTP_PORT SMTP_USER SMTP_TO AT_PORT; do
        eval "val=\${$req:-}"
        if [ -z "$val" ]; then
            log "CHYBA: $req neni nastaveno v $CONFIG_FILE, koncim"
            exit 1
        fi
    done
}

# wait_for_at_port
# Pri velmi rychlem probuzeni muze hunter.sh (spousteny primo z ubia_test
# pri sd_ready) predbehnout USB vycet modemu - /dev/ttyUSB* jeste nemusi
# existovat, byt o par vterin pozdeji uz ano (overeno na zarizeni
# 2026-08-31: v logu se stridaji behy, kde AT_PORT existuje, a behy s
# "No such file or directory"). Kratke omezene cekani (max ~5 s), pak
# pokracujeme tak ci onak - kazda AT-zavisla funkce uz sama degraduje na
# N/A, kdyz port porad neni.
wait_for_at_port() {
    i=0
    while [ ! -c "$AT_PORT" ] && [ "$i" -lt 5 ]; do
        sleep 1
        i=$((i + 1))
    done
    if [ ! -c "$AT_PORT" ]; then
        log "wait_for_at_port: $AT_PORT porad neexistuje po ${i}s cekani"
    fi
}

# sync_clock_from_modem
# Zarizeni nema baterii zalohovany RTC a mezi probuzenimi nebezi NTP -
# systemovy cas volne pluje mezi boothy (overeno na zarizeni 2026-08-31:
# rozdil pres 10 hodin oproti modemu, viz spec sekce 2.1). AT+CCLK? vraci
# cas synchronizovany siti (NITZ). Synchronizujeme jen kdyz je offset
# presne "+00" (UTC) - jinou hodnotu offsetu jsme na tomto zarizeni nikdy
# nezmerili, radsi nesahat na hodiny nez hadat aritmetiku casovych pasem.
sync_clock_from_modem() {
    resp=$("$HUNTER_DIR/bin/atcmd" "$AT_PORT" "$AT_BAUD" "AT+CCLK?" 5 2>/dev/null)

    line=""
    old_ifs="$IFS"
    IFS='
'
    for l in $resp; do
        case "$l" in
            *+CCLK:*) line="$l" ;;
        esac
    done
    IFS="$old_ifs"

    if [ -z "$line" ]; then
        log "sync_clock_from_modem: AT+CCLK? bez odpovedi, hodiny nemenim"
        return 1
    fi

    # ocekavany tvar: +CCLK: "YY/MM/DD,HH:MM:SS+OO" (overeno na zarizeni
    # 2026-08-31). Cokoli jineho -> nesahat na hodiny.
    case "$line" in
        *'"'[0-9][0-9]/[0-9][0-9]/[0-9][0-9],[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9]'"'*) ;;
        *)
            log "sync_clock_from_modem: neocekavany format odpovedi ($line), hodiny nemenim"
            return 1
            ;;
    esac

    body="${line#*\"}"
    body="${body%\"*}"

    case "$body" in
        *+*) tzsign="+" ;;
        *-*) tzsign="-" ;;
    esac
    tzq="${body#*[+-]}"
    datetime="${body%[+-]*}"

    if [ "$tzsign" != "+" ] || [ "$tzq" != "00" ]; then
        log "sync_clock_from_modem: offset ${tzsign}${tzq} != +00, nechci hadat prevod, hodiny nemenim"
        return 1
    fi

    datepart="${datetime%%,*}"
    timepart="${datetime#*,}"
    yy="${datepart%%/*}"
    mdrest="${datepart#*/}"
    mm="${mdrest%%/*}"
    dd="${mdrest#*/}"
    yyyy="20$yy"

    if date -u -s "${yyyy}-${mm}-${dd} ${timepart}" >/dev/null 2>&1; then
        log "sync_clock_from_modem: hodiny nastaveny na ${yyyy}-${mm}-${dd} ${timepart} UTC (AT+CCLK?)"
        return 0
    else
        log "sync_clock_from_modem: 'date -u -s' selhalo, hodiny nezmeneny"
        return 1
    fi
}

# is_master <cislo>
# Cislo uz musi byt normalizovane (viz normalize_phone). MASTERS je
# seznam oddeleny carkami; obalime carkami z obou stran, aby case
# pattern "*,cislo,*" nezachytil castecnou shodu (napr. "420" uvnitr
# "1420999").
is_master() {
    # Prazdny vstup nesmi nikdy projit: se zapraznenym MASTERS by se
    # obaleny retezec ",," porovnaval se vzorem *",,"* a sedl by. Stejna
    # pojistka jako u dvojcete is_mail_master (viz lib/command.sh).
    [ -n "$1" ] || return 1
    case ",$MASTERS," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# add_master <cislo>
# Prida cislo do MASTERS (config.txt i aktualni beh), pokud tam jeste
# neni.
add_master() {
    num="$1"
    if is_master "$num"; then
        return 0
    fi
    if [ -z "$MASTERS" ]; then
        newval="$num"
    else
        newval="$MASTERS,$num"
    fi
    set_config_value MASTERS "$newval"
    MASTERS="$newval"
}

# add_mail_master <adresa> / remove_mail_master <adresa>
# MAIL_MASTERS je seznam oddeleny carkami, stejne jako MASTERS.
add_mail_master() {
    a=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    if is_mail_master "$a"; then
        return 0
    fi
    if [ -z "$MAIL_MASTERS" ]; then
        newval="$a"
    else
        newval="$MAIL_MASTERS,$a"
    fi
    set_config_value MAIL_MASTERS "$newval"
    MAIL_MASTERS="$newval"
}

# remove_mail_master <adresa> -> REMOVE_MAIL_RESULT = OK|NOT_FOUND|LAST
#
# POSLEDNI adresu odebrat NELZE: se zapraznenym MAIL_MASTERS neprojde
# autorizaci nikdo (is_mail_master vrati 1 pro cokoli) a to v OBOU
# rezimech - jedinou cestou zpet by byl fyzicky pristup ke karte. Je to
# stejny duvod, pro ktery uz existuje pojistka u posledniho tokenu
# (remove_token v lib/command.sh), tady je dopad dokonce vetsi: ztrata
# posledniho tokenu nechava aspon rezim SENDER, ztrata posledni adresy
# nenechava zadnou cestu zpet.
#
# NOT_FOUND se hlasi zvlast, aby "odebral jsem neco jineho, nez jsem
# myslel" nevypadalo jako uspech - drive funkce hlasila REMOVED i kdyz
# zadna adresa neodpovidala.
remove_mail_master() {
    a=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    newval=""
    rm_found=0
    old_ifs="$IFS"
    IFS=','
    for m in $MAIL_MASTERS; do
        [ -z "$m" ] && continue
        rm_ml=$(printf '%s' "$m" | tr 'A-Z' 'a-z')
        if [ "$rm_ml" = "$a" ]; then rm_found=1; continue; fi
        if [ -z "$newval" ]; then newval="$m"; else newval="$newval,$m"; fi
    done
    IFS="$old_ifs"

    if [ "$rm_found" = 0 ]; then
        REMOVE_MAIL_RESULT=NOT_FOUND
        return 1
    fi
    if [ -z "$newval" ]; then
        REMOVE_MAIL_RESULT=LAST
        return 1
    fi

    set_config_value MAIL_MASTERS "$newval"
    MAIL_MASTERS="$newval"
    REMOVE_MAIL_RESULT=OK
    return 0
}

# remove_master <cislo> - totez pro telefonni cisla
remove_master() {
    newval=""
    old_ifs="$IFS"
    IFS=','
    for m in $MASTERS; do
        [ "$m" = "$1" ] && continue
        [ -z "$m" ] && continue
        if [ -z "$newval" ]; then newval="$m"; else newval="$newval,$m"; fi
    done
    IFS="$old_ifs"
    set_config_value MASTERS "$newval"
    MASTERS="$newval"
}
