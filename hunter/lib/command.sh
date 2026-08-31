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
# Jednoducha mezera mezi tokeny (vic mezer za sebou u vicoslovnych
# prikazu neni podporovano - zname omezeni, viz spec).
execute_command() {
    cmd=$(trim "$1")

    case "$cmd" in
        [Ss][Tt][Aa][Tt][Uu][Ss])
            CMD_REPLY=$(build_status_reply)
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
        [Aa][Dd][Dd]" "*)
            num=$(trim "${cmd#* }")
            case "$num" in
                +[0-9]*)
                    add_master "$(normalize_phone "$num")"
                    CMD_REPLY="ADDED $num"
                    ;;
                *)
                    CMD_REPLY='ADD: INVALID NUMBER'
                    ;;
            esac
            ;;
        [Ww][Ii][Pp][Ee])
            wipe_sent_snaps
            CMD_REPLY="WIPE DONE ($WIPE_COUNT photos, $(get_space_gb) free)"
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
