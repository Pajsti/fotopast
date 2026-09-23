# command.sh - transportne NEZAVISLY vykonavac prikazu.
#
# Bere text prikazu a vraci odpoved v globalni promenne CMD_REPLY.
# O tom, jestli prikaz prisel SMS nebo e-mailem, nevi nic - to je vec
# transportu (lib/sms.sh, lib/mailcmd.sh).
#
# Odpoved se NEVRACI pres stdout/$() - `$(...)` v POSIX shellu vzdy
# spousti subshell, a kdyby volajici zabalil tenhle call do neho, zmeny
# MASTERS/QUALITY/CONFIRM udelane uvnitr by se ztratily za hranici
# funkce. Proto globalni promenna a volani PRIMO.
#
# Case-insensitivita je resena `case` patterny se znakovymi tridami
# ([Ss][Tt]...), NE pres `tr '[:lower:]' '[:upper:]'` - POSIX tridy v tr
# (FEATURE_TR_CLASSES) jsou v busyboxu volitelne a tenhle firmware je
# hodne oriznuty.

# execute_command <telo_zpravy>
# Vykona jeden prikaz. Odpoved NEVRACI pres stdout/$() - `$(...)` v
# POSIX shellu vzdy spousti subshell, a kdyby volajici zabalil tenhle
# call do neho (napr. `reply=$(execute_command ...)`), zmeny
# MASTERS/QUALITY/CONFIRM udelane uvnitr by se ztratily za hranici
# funkce a v pameti bezicho skriptu by zustal stary stav (i kdyz soubor
# na disku by byl spravne). Misto toho se odpoved uklada do globalni
# promenne CMD_REPLY a funkce se vola PRIMO, ne pres $().
#
# Case-insensitivita je resena primo v `case` patternech pres znakove
# tridy typu [Ss][Tt][Aa][Tt][Uu][Ss], NE pres `tr '[:lower:]' '[:upper:]'`.
# Duvod: POSIX tridy znaku v tr (FEATURE_TR_CLASSES) jsou v busyboxu
# volitelny compile-time prepinac a tenhle firmware ma busybox hodne
# oklestenej (zadny awk/sed/cut/sort/...) - nechci na tom stavet, kdyz se
# to da vyresit ciste shellovym `case`, ktery zadnou externi zavislost
# nema.
#
# --- tokeny ---------------------------------------------------------
#
# mail.token je viceradkovy, jeden token na radek. Kazdy clovek ma
# vlastni token, takze odvolani jednoho neznamena menit token vsem.
# Vsechny tokeny maji STEJNE opravneni (vedome rozhodnuti, viz spec 3.3).
#
# Hodnota tokenu se NIKDY nezaloguje ani nevraci v odpovedi.

# load_tokens -> nastavi TOKEN_COUNT
load_tokens() {
    TOKEN_COUNT=0
    [ -f "$TOKEN_FILE" ] || return 0
    while IFS= read -r t || [ -n "$t" ]; do
        [ -n "$t" ] && TOKEN_COUNT=$((TOKEN_COUNT + 1))
    done < "$TOKEN_FILE"
    return 0
}

# is_valid_token <token> -> navratovy kod 0 = plati
is_valid_token() {
    [ -n "$1" ] || return 1
    [ -f "$TOKEN_FILE" ] || return 1
    while IFS= read -r t || [ -n "$t" ]; do
        [ "$t" = "$1" ] && return 0
    done < "$TOKEN_FILE"
    return 1
}

# add_token <token> -> ADD_TOKEN_RESULT = OK|EXISTS|TOO_SHORT|BAD_CHARS
add_token() {
    nt="$1"

    # nl pres skutecny Enter v literalu, ne $(printf '\n') - command
    # substitution orezava koncove nove radky, takze $(printf '\n') by
    # se vyhodnotilo na prazdny retezec a pattern *""* by matchoval
    # cokoli (viz IFS trik v mail.sh/common.sh).
    nl='
'
    case "$nt" in
        *" "*|*"$(printf '\t')"*|*"$nl"*) ADD_TOKEN_RESULT=BAD_CHARS; return 1 ;;
    esac
    # min. 8 znaku. Busybox nema wc; `case` s osmi otazniky nezavisi ani
    # na ${#var}, ktere neni ve vsech ash buildech spolehlive.
    case "$nt" in
        ????????*) ;;
        *) ADD_TOKEN_RESULT=TOO_SHORT; return 1 ;;
    esac

    if is_valid_token "$nt"; then
        ADD_TOKEN_RESULT=EXISTS; return 0
    fi

    printf '%s\n' "$nt" >> "$TOKEN_FILE"
    sync
    ADD_TOKEN_RESULT=OK
    return 0
}

# remove_token <token> -> REMOVE_TOKEN_RESULT = OK|NOT_FOUND|LAST
remove_token() {
    rt="$1"

    if ! is_valid_token "$rt"; then
        REMOVE_TOKEN_RESULT=NOT_FOUND; return 1
    fi

    load_tokens
    # Posledni token nejde odebrat - v rezimu TOKEN by se zarizeni stalo
    # neovladatelnym na dalku a jedinou cestou zpet by byl fyzicky
    # pristup ke karte.
    if [ "$TOKEN_COUNT" -le 1 ]; then
        REMOVE_TOKEN_RESULT=LAST; return 1
    fi

    tmp="$TOKEN_FILE.tmp.$$"
    : > "$tmp"
    while IFS= read -r t || [ -n "$t" ]; do
        [ -z "$t" ] && continue
        [ "$t" = "$rt" ] && continue
        printf '%s\n' "$t" >> "$tmp"
    done < "$TOKEN_FILE"
    sync
    mv -f "$tmp" "$TOKEN_FILE"
    sync
    REMOVE_TOKEN_RESULT=OK
    return 0
}

# --- autorizace -----------------------------------------------------

# is_mail_master <adresa> -> 0 = je v MAIL_MASTERS
# Adresa uz prichazi malymi pismeny z mailrecv; MAIL_MASTERS z configu
# snizime taky (tr s EXPLICITNIMI rozsahy - POSIX tridy busybox nemusi
# mit).
is_mail_master() {
    [ -n "$1" ] || return 1
    [ -n "$MAIL_MASTERS" ] || return 1
    ml=$(printf '%s' "$MAIL_MASTERS" | tr 'A-Z' 'a-z')
    a=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case ",$ml," in
        *",$a,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# authorize_mail <odesilatel> <predmet>
# Nastavi:
#   AUTH_OK        1 = smi se vykonat
#   AUTH_CMD       prikaz bez prefixu a bez tokenu
#   AUTH_HAS_TOKEN 1 = ve zprave byl platny token
#
# Prefix "HUNTER " uz musi byt oriznuty volajicim? NE - resi se tady,
# aby transport nemusel znat format.
authorize_mail() {
    AUTH_OK=0
    AUTH_CMD=""
    AUTH_HAS_TOKEN=0

    from="$1"
    subj=$(trim "$2")

    # musi zacinat prefixem
    case "$subj" in
        [Hh][Uu][Nn][Tt][Ee][Rr]" "*) ;;
        *) return 1 ;;
    esac
    rest=$(trim "${subj#* }")

    # prvni slovo muze byt token
    first="${rest%% *}"
    if is_valid_token "$first"; then
        AUTH_HAS_TOKEN=1
        # kdyz za tokenem uz nic neni, prikaz je prazdny
        if [ "$first" = "$rest" ]; then
            AUTH_CMD=""
        else
            AUTH_CMD=$(trim "${rest#* }")
        fi
    else
        AUTH_CMD="$rest"
    fi

    is_mail_master "$from" || return 1

    case "$AUTH_TYPE" in
        [Ss][Ee][Nn][Dd][Ee][Rr]) AUTH_OK=1 ;;
        *) [ "$AUTH_HAS_TOKEN" = 1 ] && AUTH_OK=1 ;;
    esac
    return 0
}

# build_cmd_listing
# Vypis prikazu, ktery ODRAZI AKTUALNI REZIM - ukazuje presne to, co je
# ted potreba napsat. Hodnota tokenu se nikdy nevypisuje, jen "<token>".
# Bez diakritiky, stejne jako zbytek zarizeni.
build_cmd_listing() {
    case "$AUTH_TYPE" in
        [Ss][Ee][Nn][Dd][Ee][Rr]) mode="SENDER"; p="HUNTER" ;;
        *)                        mode="TOKEN";  p="HUNTER <token>" ;;
    esac
    # privilegovane prikazy maji token vzdy, bez ohledu na rezim
    pp="HUNTER <token>"

    printf 'HUNTER commands (auth mode: %s)\n\n' "$mode"
    printf '%s STATUS                  stav: baterie/signal/misto\n' "$p"
    printf '%s LAST <N>                N nejnovejsich fotek\n' "$p"
    printf '%s DATE <YYMMDD>           fotky z daneho dne\n' "$p"
    printf '%s GET <jmeno>             konkretni soubor\n' "$p"
    printf '%s QUALITY HD|LOW          kvalita odesilanych fotek\n' "$p"
    printf '%s CONFIRM ON|OFF          potvrzovaci odpovedi\n' "$p"
    printf '%s WIPE CONFIRM            smaze jiz odeslane fotky\n' "$p"
    printf '%s CLEAR QUEUE             vyprazdni frontu, i vadne (nemaze)\n' "$p"
    printf '%s LIST CMD                tento vypis\n' "$p"
    printf '%s ADD <tel|mail>          pridat opravneneho   [vzdy token]\n' "$pp"
    printf '%s REMOVE <tel|mail>       odebrat opravneneho  [vzdy token]\n' "$pp"
    printf '%s ADD TOKEN <novy>        pridat token         [vzdy token]\n' "$pp"
    printf '%s REMOVE TOKEN <token>    odebrat token        [vzdy token]\n' "$pp"
    printf '%s AUTH TYPE TOKEN|SENDER  zmena rezimu         [vzdy token]\n' "$pp"
    printf '%s FOTO                    nepodporovano\n' "$p"
    printf '\n<token> = kterykoli z tokenu v hunter/mail.token'
    printf ' (nikdy se nevypisuje)\n'
}

# --- vyzadani fotek -------------------------------------------------
#
# Vyzadane fotky OBCHAZEJI sent_list.txt - preposlat uz odeslanou fotku
# je cely smysl veci. Sbiraji se do REQUESTED_SNAPS (cesty oddelene
# novym radkem), ktere hunter.sh slouci s automatickymi kandidaty.
#
# Strop je REQUEST_MAX, oddeleny od MAX_SEND_PER_WAKE - o vyzadane fotky
# si uzivatel rekl vyslovne.

# request_add <cesta> - prida cestu, hlida strop. Vraci 1 pri dosazeni
# stropu (volajici ma prestat pridavat).
request_add() {
    n=$(printf '%s' "$REQUESTED_SNAPS" | grep -c . )
    [ "$n" -ge "$REQUEST_MAX" ] && return 1
    if [ -z "$REQUESTED_SNAPS" ]; then
        REQUESTED_SNAPS="$1"
    else
        REQUESTED_SNAPS="$REQUESTED_SNAPS
$1"
    fi
    return 0
}

# request_count
request_count() {
    printf '%s' "$REQUESTED_SNAPS" | grep -c .
}

# Porovnavani stari snimku.
#
# Cesta ma tvar snaps/<YYMMDD>/<HHMMSS>_... Porovnava se CISELNE a ve
# DVOU krocich (nejdriv datum, pak cas), ne jako jedno dvanactimistne
# cislo ani jako retezec:
#   - operator \> uvnitr [ ] neni v POSIXu definovany a busybox ho
#     nemusi mit,
#   - dvanactimistne cislo by preteklo v 32bitove aritmetice.
# Sestimistne casti (max 999999) se do 32 bitu vejdou bez problemu.
#
# ZNAME OMEZENI: rok se bere jako YY, takze porovnani se rozbije na
# prelomu stoleti (99 -> 00). Pri nespolehlivych hodinach zarizeni
# (viz spec 2.1) je to prijatelne.
snap_date_of() { sp=${1%/*}; printf '%s' "${sp##*/}"; }
snap_time_of() { sb=${1##*/}; printf '%s' "${sb%%_*}"; }

# snap_newer <a> <b> -> 0 kdyz a je novejsi nez b
#
# Datum a cas se tahaji INLINE parametrickou expanzi, ne pres
# snap_date_of/snap_time_of - kazde $( ) je fork a tahle funkce se vola
# v cyklu pres vsechny soubory dne. Puvodni varianta stala 4 forky na
# jedno porovnani, coz pri tisicich fotek delalo z LAST N radove
# statisice procesu (spec 2026-09-02, sekce 1.2).
snap_newer() {
    sp=${1%/*}; ad=${sp##*/}
    sb=${1##*/}; at=${sb%%_*}
    sp=${2%/*}; bd=${sp##*/}
    sb=${2##*/}; bt=${sb%%_*}
    snap_num6 "$ad" && snap_num6 "$at" || return 1
    snap_num6 "$bd" && snap_num6 "$bt" || return 0
    [ "$ad" -gt "$bd" ] && return 0
    [ "$ad" -lt "$bd" ] && return 1
    [ "$at" -gt "$bt" ] && return 0
    return 1
}

# request_last <N> - N nejnovejsich fotek.
#
# Jde po slozkach dnu od NEJNOVEJSI a konci, jakmile ma N kusu - ne
# N-krat pres cely strom, jak to delala puvodni verze. Pri tisicich
# fotek byl puvodni postup neunosny (spec 2026-09-02, 1.2).
#
# Cursor se ZAMERNE ignoruje a sent_list.txt taky: vyzadane fotky maji
# dosahnout i na dny, ktere uz automatika uzavrela, a na uz odeslane
# snimky (spec 2026-09-02, 8.3).
request_last() {
    want="$1"
    [ "$want" -gt "$REQUEST_MAX" ] && want="$REQUEST_MAX"

    added=0
    days=$(list_snap_days)

    while [ "$added" -lt "$want" ]; do
        # nejnovejsi dosud nezpracovany den
        newest=""
        for d in $days; do
            snap_num6 "$d" || continue
            if [ -z "$newest" ] || [ "$d" -gt "$newest" ]; then
                newest="$d"
            fi
        done
        [ -z "$newest" ] && break

        # z tohohle dne ber od nejnovejsiho, dokud neni dost
        taken=""
        while [ "$added" -lt "$want" ]; do
            best=""
            for f in "$SDCARD/snaps/$newest"/*.jpg; do
                [ -f "$f" ] || continue
                case "
$taken" in
                    *"
$f"*) continue ;;
                esac
                if [ -z "$best" ] || snap_newer "$f" "$best"; then
                    best="$f"
                fi
            done
            [ -z "$best" ] && break
            taken="$taken
$best"
            request_add "$best" || return 0
            added=$((added + 1))
        done

        # den vycerpan - odeber ho ze seznamu a jdi na starsi
        days=$(printf '%s\n' "$days" | grep -v -x -F "$newest")
    done
}

# request_date <YYMMDD>
request_date() {
    d="$1"
    for f in $(find "$SDCARD/snaps/$d" -type f -name '*.jpg' 2>/dev/null); do
        request_add "$f" || break
    done
}

# request_get <jmeno> - jen holy nazev souboru; cokoli s "/" nebo ".."
# se odmita, aby se pres nej nedalo sahnout mimo snaps/.
request_get() {
    name="$1"
    case "$name" in
        */*|*..*|"") return 2 ;;
    esac
    for f in $(find "$SDCARD/snaps" -type f -name "$name" 2>/dev/null); do
        request_add "$f"
        return 0
    done
    return 1
}

# execute_command <text_prikazu> [ma_platny_token]
#
# Druhy argument rika, jestli zprava nesla platny token. Prikazy menici
# OPRAVNENI (AUTH TYPE, ADD, REMOVE, ADD TOKEN, REMOVE TOKEN) ho vyzaduji
# VZDY - i v rezimu SENDER. Tim je zaruceno, ze se z oslabeneho rezimu
# jde vzdycky vratit a ze si podvrzeny mail nemuze sam pridat trvaly
# pristup. Viz spec sekce 3.3.
#
# Jednoducha mezera mezi tokeny (vic mezer za sebou u vicoslovnych
# prikazu neni podporovano - zname omezeni, viz spec).
execute_command() {
    cmd=$(trim "$1")
    has_token="${2:-0}"

    case "$cmd" in
        [Ss][Tt][Aa][Tt][Uu][Ss])
            load_tokens
            CMD_REPLY="$(build_status_reply) TOKENS:$TOKEN_COUNT"
            ;;

        [Ff][Oo][Tt][Oo])
            # Neni overeno, ze umime vyvolat snimek bez znalosti MCU
            # protokolu / cloudove autorizace (spec sekce 7.4, otevreny
            # bod). Radeji priznat, ze to nejde, nez tvarit se, ze to
            # funguje.
            CMD_REPLY='FOTO NOT SUPPORTED'
            ;;

        [Qq][Uu][Aa][Ll][Ii][Tt][Yy]" "[Hh][Dd])
            set_config_value QUALITY HD
            QUALITY=HD
            # POZN.: QUALITY se zatim jen uklada do configu. Skutecne
            # prekodovani/zmenseni JPEGu pred odeslanim NENI implementovano
            # (vyzadovalo by knihovnu na JPEG, coz Instructions.txt
            # nechce "zbytecne narocne knihovny"). Snimky se posilaji
            # vzdy v kvalite, v jake je porizuje puvodni aplikace.
            CMD_REPLY='QUALITY SET TO HD'
            ;;

        [Qq][Uu][Aa][Ll][Ii][Tt][Yy]" "[Ll][Oo][Ww])
            set_config_value QUALITY LOW
            QUALITY=LOW
            CMD_REPLY='QUALITY SET TO LOW'
            ;;

        [Cc][Oo][Nn][Ff][Ii][Rr][Mm]" "[Oo][Nn])
            set_config_value CONFIRM ON
            CONFIRM=ON
            CMD_REPLY='CONFIRM ON'
            ;;

        [Cc][Oo][Nn][Ff][Ii][Rr][Mm]" "[Oo][Ff][Ff])
            set_config_value CONFIRM OFF
            CONFIRM=OFF
            CMD_REPLY='CONFIRM OFF'
            ;;

        [Cc][Ll][Ee][Aa][Rr]" "[Qq][Uu][Ee][Uu][Ee])
            # Jen se nastavi priznak - skutecne preskoceni dela hunter.sh
            # az po zpracovani VSECH prikazu.
            #
            # Musi to tak byt kvuli invariantu 7.1: preskakovani se nesmi
            # dotknout vyzadanych fotek, a REQUESTED_SNAPS je konecny
            # teprve, kdyz dobehnou vsechny prikazy daneho probuzeni.
            # Kdyby v jedne davce prisel CLEAR QUEUE driv nez LAST 2,
            # oznacil by fotku, kterou ma LAST teprve vyzadat - a ta by
            # z automatickeho odesilani vypadla natrvalo.
            #
            # Proto taky odpoved neobsahuje pocet: v okamziku odeslani
            # odpovedi jeste neni znam. Loguje se az pri preskoceni.
            CLEAR_QUEUE_REQUESTED=1
            CMD_REPLY='QUEUE CLEARED'
            ;;

        [Ww][Ii][Pp][Ee]" "[Cc][Oo][Nn][Ff][Ii][Rr][Mm])
            wipe_sent_snaps
            if [ "$WIPE_REMAINING" -gt 0 ]; then
                # Zbytek si Hunter dobere sam pri dalsich probuzenich.
                # Znacku se zadatelovou adresou zaklada az transport -
                # tenhle vykonavac o odesilateli nevi (viz komentar u
                # wipe_continue_if_pending nize).
                WIPE_CONTINUE=1
                CMD_REPLY="WIPE STARTED ($WIPE_COUNT photos, $WIPE_REMAINING zbyva, pokracuji sam, $(get_space_gb) free)"
            else
                CMD_REPLY="WIPE DONE ($WIPE_COUNT photos, $(get_space_gb) free)"
            fi
            ;;

        [Ww][Ii][Pp][Ee])
            CMD_REPLY='WIPE NEEDS CONFIRM'
            ;;

        [Aa][Uu][Tt][Hh]" "[Tt][Yy][Pp][Ee]" "[Tt][Oo][Kk][Ee][Nn])
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            set_config_value AUTH_TYPE TOKEN
            AUTH_TYPE=TOKEN
            CMD_REPLY='AUTH TYPE SET TO TOKEN'
            ;;

        [Aa][Uu][Tt][Hh]" "[Tt][Yy][Pp][Ee]" "[Ss][Ee][Nn][Dd][Ee][Rr])
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            set_config_value AUTH_TYPE SENDER
            AUTH_TYPE=SENDER
            CMD_REPLY='AUTH TYPE SET TO SENDER'
            ;;

        [Aa][Dd][Dd]" "[Tt][Oo][Kk][Ee][Nn]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            newtok=$(trim "${cmd##* }")
            add_token "$newtok"
            case "$ADD_TOKEN_RESULT" in
                OK)        load_tokens; CMD_REPLY="TOKEN ADDED ($TOKEN_COUNT total)" ;;
                EXISTS)    CMD_REPLY='TOKEN ALREADY PRESENT' ;;
                TOO_SHORT) CMD_REPLY='TOKEN TOO SHORT (min 8)' ;;
                BAD_CHARS) CMD_REPLY='TOKEN MUST NOT CONTAIN SPACES' ;;
            esac
            ;;

        [Rr][Ee][Mm][Oo][Vv][Ee]" "[Tt][Oo][Kk][Ee][Nn]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            oldtok=$(trim "${cmd##* }")
            remove_token "$oldtok"
            case "$REMOVE_TOKEN_RESULT" in
                OK)        load_tokens; CMD_REPLY="TOKEN REMOVED ($TOKEN_COUNT left)" ;;
                NOT_FOUND) CMD_REPLY='TOKEN NOT FOUND' ;;
                LAST)      CMD_REPLY='CANNOT REMOVE LAST TOKEN' ;;
            esac
            ;;

        [Aa][Dd][Dd]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            tgt=$(trim "${cmd#* }")
            # Hodnota konci v config.txt, ktery load_config nacita pres `.` -
            # cokoli mimo tenhle znakovy rozsah by tam bylo spustitelne
            # (`;`, `$(...)`, backtick) nebo by soubor rozbilo tak, ze uz by
            # se nenacetl vubec (osamocena uvozovka/zavorka) - a to je na
            # nedostupnem zarizeni trvale rozbiti. Tvarovy `case` nize je
            # jen kontrola TVARU, ne znaku, takze filtrovat je treba TADY.
            # Mezera je zamerne mimo rozsah: cislo se pise bez mezer
            # (+420603284430) nebo s pomlckami, ktere rozsah povoluje.
            case "$tgt" in
                *[!A-Za-z0-9@._+-]*) CMD_REPLY='ADD: INVALID TARGET'; return 0 ;;
            esac
            case "$tgt" in
                +[0-9]*) add_master "$(normalize_phone "$tgt")"
                         CMD_REPLY="ADDED $tgt" ;;
                *@*.*)   add_mail_master "$tgt"
                         CMD_REPLY="ADDED $tgt" ;;
                *)       CMD_REPLY='ADD: INVALID TARGET' ;;
            esac
            ;;

        [Rr][Ee][Mm][Oo][Vv][Ee]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            tgt=$(trim "${cmd#* }")
            # Stejny znakovy filtr jako u ADD - i REMOVE zapisuje zpatky do
            # config.txt (prepisuje cely radek MASTERS=/MAIL_MASTERS=).
            case "$tgt" in
                *[!A-Za-z0-9@._+-]*) CMD_REPLY='REMOVE: INVALID TARGET'; return 0 ;;
            esac
            case "$tgt" in
                +[0-9]*) remove_master "$(normalize_phone "$tgt")"
                         CMD_REPLY="REMOVED $tgt" ;;
                *@*.*)   remove_mail_master "$tgt"
                         case "$REMOVE_MAIL_RESULT" in
                             OK)        CMD_REPLY="REMOVED $tgt" ;;
                             NOT_FOUND) CMD_REPLY="MAIL MASTER NOT FOUND: $tgt" ;;
                             LAST)      CMD_REPLY='CANNOT REMOVE LAST MAIL MASTER' ;;
                         esac ;;
                *)       CMD_REPLY='REMOVE: INVALID TARGET' ;;
            esac
            ;;

        [Ll][Ii][Ss][Tt]" "[Cc][Mm][Dd])
            CMD_REPLY=$(build_cmd_listing)
            ;;

        [Ll][Aa][Ss][Tt]" "*)
            n=$(trim "${cmd#* }")
            case "$n" in
                ''|*[!0-9]*) CMD_REPLY='LAST: INVALID COUNT'; return 0 ;;
            esac
            [ "$n" -lt 1 ] && { CMD_REPLY='LAST: INVALID COUNT'; return 0; }
            # request_last -> request_add PREPISUJE globalni $n (zadna
            # funkce v lib/ nescopuje promenne, `local` neni v POSIXu).
            # Bez teto kopie by se nize porovnaval pocet uz pridanych
            # polozek, ktery je z definice <= REQUEST_MAX, takze hlaska o
            # oriznuti byla nedosazitelna.
            want_n="$n"
            request_last "$n"
            got=$(request_count)
            if [ "$got" = 0 ]; then
                CMD_REPLY='LAST: NOT FOUND'
            elif [ "$want_n" -gt "$REQUEST_MAX" ]; then
                CMD_REPLY="SENDING $got (capped at REQUEST_MAX=$REQUEST_MAX)"
            else
                CMD_REPLY="SENDING $got"
            fi
            ;;

        [Dd][Aa][Tt][Ee]" "*)
            d=$(trim "${cmd#* }")
            case "$d" in
                [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
                *) CMD_REPLY='DATE: INVALID FORMAT'; return 0 ;;
            esac
            request_date "$d"
            got=$(request_count)
            if [ "$got" = 0 ]; then
                CMD_REPLY='DATE: NOT FOUND'
            else
                CMD_REPLY="SENDING $got"
            fi
            ;;

        [Gg][Ee][Tt]" "*)
            name=$(trim "${cmd#* }")
            request_get "$name"
            case "$?" in
                0) CMD_REPLY="SENDING $(request_count)" ;;
                1) CMD_REPLY='GET: NOT FOUND' ;;
                2) CMD_REPLY='GET: INVALID NAME' ;;
            esac
            ;;

        *)
            CMD_REPLY='UNKNOWN CMD'
            ;;
    esac
}

# wipe_sent_snaps
# Mazani je omezene VYHRADNE na $SDCARD/snaps/*.jpg soubory, ktere uz
# jsou v sent_list.txt (spec sekce 7.3). Nikdy se nedotkne ubia_record.db,
# logfile.txt, video/, HDPIC/ ani cehokoli mimo snaps/ - i kdyby se
# sent_list.txt nekdy poskodil, `case` filtr nize je posledni pojistka.
#
# Po smazani se sent_list.txt prepise bez zaznamu o smazanych souborech
# (atomicky), aby neblokovaly detekci pripadnych novych snimku se stejnym
# nazvem po pretoceni casu.
#
# DAVKOVANI (2026-09-23): zatezovy test (tests/stress_5000.sh) namer il
# 98.7 s na 5000 zaznamech - blizko RUN_DEADLINE (vychozich 180 s), a to
# jen na PC. Prave kdyz je karta plna stareho odeslaneho obsahu - tedy
# presne kdyz je WIPE potreba - je sent_list.txt nejvetsi a nejpomalejsi.
# Zpracuje se proto nejvys WIPE_BATCH zaznamu za jedno spusteni; zbytek
# zustane v sent_list.txt beze zmeny a ceka na dalsi WIPE CONFIRM.
# WIPE_REMAINING rika volajicimu, kolik jich zbylo, aby mohl odpoved
# rozlisit na WIPE DONE / WIPE PARTIAL (viz execute_command nize).
# Zadne automaticke pokracovani na pozadi - CONFIRM zustava bezpecnostni
# pojistkou, uzivatel prosty posle WIPE CONFIRM znovu.
wipe_sent_snaps() {
    WIPE_COUNT=0
    WIPE_REMAINING=0

    _wipe_cap="${WIPE_BATCH:-500}"
    case "$_wipe_cap" in
        ''|*[!0-9]*|0*) _wipe_cap=500 ;;
    esac

    if [ ! -f "$STATE_DIR/sent_list.txt" ]; then
        return 0
    fi

    tmp="$STATE_DIR/sent_list.txt.tmp.$$"
    : > "$tmp"

    _wipe_processed=0
    old_ifs="$IFS"
    IFS='
'
    while IFS= read -r f; do
        case "$f" in
            "$SDCARD/snaps/"*.jpg)
                if [ "$_wipe_processed" -lt "$_wipe_cap" ]; then
                    _wipe_processed=$((_wipe_processed + 1))
                    if [ -f "$f" ]; then
                        rm -f "$f"
                        WIPE_COUNT=$((WIPE_COUNT + 1))
                    fi
                else
                    printf '%s\n' "$f" >> "$tmp"
                fi
                ;;
            *)
                printf '%s\n' "$f" >> "$tmp"
                ;;
        esac
    done < "$STATE_DIR/sent_list.txt"
    IFS="$old_ifs"

    sync
    mv -f "$tmp" "$STATE_DIR/sent_list.txt"
    sync

    WIPE_REMAINING=$(grep -c . "$STATE_DIR/sent_list.txt" 2>/dev/null)
    case "$WIPE_REMAINING" in
        ''|*[!0-9]*) WIPE_REMAINING=0 ;;
    esac
}

# --- rozdelane mazani pres vice probuzeni ---------------------------
#
# Jedno potvrzeni WIPE CONFIRM ma stacit na celou frontu: davky, ktere
# se do prvniho behu nevesly, si Hunter odbava sam pri dalsich
# probuzenich (rozhodnuti uzivatele 2026-09-23). Bez toho by u 5000
# zaznamu a WIPE_BATCH=500 musel uzivatel poslat prikaz jedenactkrat.
#
# Stav drzi state/wipe_pending.txt, ktery nese ADRESU zadatele - bez ni
# by na konci nebylo komu poslat zpravu, ze je hotovo. Znacka se zaklada
# az v transportu (lib/mailcmd.sh), protoze execute_command je zamerne
# transportne nezavisly a o odesilateli nevi nic; dava mu o tom vedet
# jen priznakem WIPE_CONTINUE.

wipe_pending_file() { printf '%s' "$STATE_DIR/wipe_pending.txt"; }

# wipe_mark_pending <adresa>
wipe_mark_pending() {
    printf '%s\n' "$1" > "$(wipe_pending_file)"
    sync
}

wipe_clear_pending() {
    rm -f "$(wipe_pending_file)" 2>/dev/null
    sync
}

# wipe_pending_addr - adresa zadatele, nebo prazdno kdyz se nic nemaze
wipe_pending_addr() {
    [ -f "$(wipe_pending_file)" ] || return 0
    read -r _wpa < "$(wipe_pending_file)" 2>/dev/null
    printf '%s' "$_wpa"
}

# wipe_continue_if_pending
# Jedna davka za probuzeni, jen kdyz je rozdelane mazani. Vola se z
# hunter.sh AZ PO odeslani fotek - fotky jsou hlavni ucel zarizeni a
# mazani jim nesmi ujidat rozpocet behu.
#
# Kdyz uz nic nezbyva, znacku uklidi a naplni WIPE_DONE_NOTICE. Zpravu
# NEPOSILA sama: odeslani je vec volajiciho (hunter.sh), aby tahle
# funkce zustala testovatelna bez site.
wipe_continue_if_pending() {
    WIPE_DONE_NOTICE=""
    _wcp_addr=$(wipe_pending_addr)
    [ -n "$_wcp_addr" ] || return 0

    wipe_sent_snaps
    log "WIPE pokracuje: smazano $WIPE_COUNT, zbyva $WIPE_REMAINING"

    if [ "$WIPE_REMAINING" -le 0 ]; then
        wipe_clear_pending
        WIPE_DONE_NOTICE="WIPE DONE (posledni davka $WIPE_COUNT photos, $(get_space_gb) free)"
    fi
    return 0
}
