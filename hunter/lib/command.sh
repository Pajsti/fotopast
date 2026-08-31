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
# to da vyresit cistě shellovym `case`, ktery zadnou externí zavislost
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

        [Ww][Ii][Pp][Ee]" "[Cc][Oo][Nn][Ff][Ii][Rr][Mm])
            wipe_sent_snaps
            CMD_REPLY="WIPE DONE ($WIPE_COUNT photos, $(get_space_gb) free)"
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
            case "$tgt" in
                +[0-9]*) remove_master "$(normalize_phone "$tgt")"
                         CMD_REPLY="REMOVED $tgt" ;;
                *@*.*)   remove_mail_master "$tgt"
                         CMD_REPLY="REMOVED $tgt" ;;
                *)       CMD_REPLY='REMOVE: INVALID TARGET' ;;
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
# sent_list.txt nekdy poskodil, `case` filtr níže je posledni pojistka.
#
# Po smazani se sent_list.txt prepise bez zaznamu o smazanych souborech
# (atomicky), aby neblokovaly detekci pripadnych novych snimku se stejnym
# nazvem po pretoceni casu.
wipe_sent_snaps() {
    WIPE_COUNT=0

    if [ ! -f "$STATE_DIR/sent_list.txt" ]; then
        return 0
    fi

    tmp="$STATE_DIR/sent_list.txt.tmp.$$"
    : > "$tmp"

    old_ifs="$IFS"
    IFS='
'
    while IFS= read -r f; do
        case "$f" in
            "$SDCARD/snaps/"*.jpg)
                if [ -f "$f" ]; then
                    rm -f "$f"
                    WIPE_COUNT=$((WIPE_COUNT + 1))
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
}
