# sms.sh - prijem, autorizace, vykonani SMS prikazu (viz spec sekce 7).
#
# Poradi kroku pro kazdou zpravu je zamerne: dedup-zapis PRED vykonanim,
# smazani z ulozistě modulu AZ PO vykonani a pripadne odpovedi. Kdyby
# zarizeni zhaslo mezi vykonanim a smazanim, dalsi probuzeni uvidi
# stejnou zpravu znovu - ale sms_seen.txt uz ji ma zapsanou, takze se jen
# tise smaze bez druheho vykonani. U WIPE by dvojite vykonani nevadilo,
# ale principem to ma platit pro vsechny prikazy stejne.

# process_sms
# Nacte nove SMS z modulu, autorizuje podle MASTERS, vykona, pripadne
# odpovi (jen kdyz CONFIRM=ON), uklidi ulozistě modulu.
process_sms() {
    listing=$("$HUNTER_DIR/bin/smsrecv" "$AT_PORT" "$AT_BAUD" list unread 2>>"$LOG_FILE")
    [ -z "$listing" ] && return 0

    old_ifs="$IFS"
    IFS='
'
    for line in $listing; do
        IFS="$old_ifs"
        case "$line" in
            MSG\|*) ;;
            *) continue ;;
        esac

        # MSG|index|status|odesilatel|cas|telo - telo je posledni pole a
        # pri vzniku obsahuje i pripadne dalsi "|" (nepravdepodobne u
        # prikazu, ale rozdeleni radku zvladne i tenhle pripad: `set --`
        # rozseka VSECHNA pole na "|", zbytek po petem poli zpet spojime
        # mezerou pres $*).
        field_ifs="$IFS"
        IFS='|'
        set -- $line
        IFS="$field_ifs"

        idx="$2"
        from="$4"
        ts="$5"
        shift 5
        body="$*"

        key="$from|$ts|$body"

        if [ -f "$STATE_DIR/sms_seen.txt" ] && \
           fgrep -qxF "$key" "$STATE_DIR/sms_seen.txt" 2>/dev/null; then
            log "SMS jiz zpracovana drive (vypadek napajeni?), jen mazu: $key"
            "$HUNTER_DIR/bin/smsrecv" "$AT_PORT" "$AT_BAUD" del "$idx" >>"$LOG_FILE" 2>&1
            IFS='
'
            continue
        fi

        printf '%s\n' "$key" >> "$STATE_DIR/sms_seen.txt"
        sync

        from_norm=$(normalize_phone "$from")
        if ! is_master "$from_norm"; then
            log "SMS od neautorizovaneho cisla '$from' odmitnuta"
            "$HUNTER_DIR/bin/smsrecv" "$AT_PORT" "$AT_BAUD" del "$idx" >>"$LOG_FILE" 2>&1
            IFS='
'
            continue
        fi

        log "SMS od $from: $body"
        SMS_REPLY=""
        execute_sms_command "$body"
        reply="$SMS_REPLY"

        if [ "$CONFIRM" = "ON" ] && [ -n "$reply" ]; then
            "$HUNTER_DIR/bin/smssend" "$AT_PORT" "$AT_BAUD" "$from" "$reply" >>"$LOG_FILE" 2>&1
        fi

        "$HUNTER_DIR/bin/smsrecv" "$AT_PORT" "$AT_BAUD" del "$idx" >>"$LOG_FILE" 2>&1
        IFS='
'
    done
    IFS="$old_ifs"
}

# execute_sms_command <telo_zpravy>
# Vykona jeden prikaz. Odpoved NEVRACI pres stdout/$() - `$(...)` v
# POSIX shellu vzdy spousti subshell, a kdyby volajici zabalil tenhle
# call do neho (napr. `reply=$(execute_sms_command ...)`), zmeny
# MASTERS/QUALITY/CONFIRM udelane uvnitr by se ztratily za hranici
# funkce a v pameti bezicho skriptu by zustal stary stav (i kdyz soubor
# na disku by byl spravne). Misto toho se odpoved uklada do globalni
# promenne SMS_REPLY a funkce se vola PRIMO, ne pres $().
#
# Case-insensitivita je resena primo v `case` patternech pres znakove
# tridy typu [Ss][Tt][Aa][Tt][Uu][Ss], NE pres `tr '[:lower:]' '[:upper:]'`.
# Duvod: POSIX tridy znaku v tr (FEATURE_TR_CLASSES) jsou v busyboxu
# volitelny compile-time prepinac a tenhle firmware ma busybox hodne
# oklestenej (zadny awk/sed/cut/sort/...) - nechci na tom stavet, kdyz se
# to da vyresit cistě shellovym `case`, ktery zadnou externí zavislost
# nema.
#
# Jednoducha mezera mezi tokeny (vic mezer za sebou u vicoslovnych
# prikazu neni podporovano - zname omezeni, viz spec).
execute_sms_command() {
    cmd=$(trim "$1")

    case "$cmd" in
        [Ss][Tt][Aa][Tt][Uu][Ss])
            SMS_REPLY=$(build_status_reply)
            ;;
        [Ff][Oo][Tt][Oo])
            # Neni overeno, ze umime vyvolat snimek bez znalosti MCU
            # protokolu / cloudove autorizace (spec sekce 7.4, otevreny
            # bod). Radeji priznat, ze to nejde, nez tvarit se, ze to
            # funguje.
            SMS_REPLY='FOTO NOT SUPPORTED'
            ;;
        [Qq][Uu][Aa][Ll][Ii][Tt][Yy]" "[Hh][Dd])
            set_config_value QUALITY HD
            QUALITY=HD
            # POZN.: QUALITY se zatim jen uklada do configu. Skutecne
            # prekodovani/zmenseni JPEGu pred odeslanim NENI implementovano
            # (vyzadovalo by knihovnu na JPEG, coz Instructions.txt
            # nechce "zbytecne narocne knihovny"). Snimky se posilaji
            # vzdy v kvalite, v jake je porizuje puvodni aplikace.
            SMS_REPLY='QUALITY SET TO HD'
            ;;
        [Qq][Uu][Aa][Ll][Ii][Tt][Yy]" "[Ll][Oo][Ww])
            set_config_value QUALITY LOW
            QUALITY=LOW
            SMS_REPLY='QUALITY SET TO LOW'
            ;;
        [Cc][Oo][Nn][Ff][Ii][Rr][Mm]" "[Oo][Nn])
            set_config_value CONFIRM ON
            CONFIRM=ON
            SMS_REPLY='CONFIRM ON'
            ;;
        [Cc][Oo][Nn][Ff][Ii][Rr][Mm]" "[Oo][Ff][Ff])
            set_config_value CONFIRM OFF
            CONFIRM=OFF
            SMS_REPLY='CONFIRM OFF'
            ;;
        [Aa][Dd][Dd]" "*)
            num=$(trim "${cmd#* }")
            case "$num" in
                +[0-9]*)
                    add_master "$(normalize_phone "$num")"
                    SMS_REPLY="ADDED $num"
                    ;;
                *)
                    SMS_REPLY='ADD: INVALID NUMBER'
                    ;;
            esac
            ;;
        [Ww][Ii][Pp][Ee])
            wipe_sent_snaps
            SMS_REPLY="WIPE DONE ($WIPE_COUNT photos, $(get_space_gb) free)"
            ;;
        *)
            SMS_REPLY='UNKNOWN CMD'
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
