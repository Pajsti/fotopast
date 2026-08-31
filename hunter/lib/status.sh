# status.sh - Battery / Signal / Space. Kazda hodnota vraci bud cislo s
# jednotkou, nebo "N/A" - nikdy odhad (viz Instructions.txt, pozadavek na
# spolehlivost hodnot).

# get_space_gb
# Volne misto na karte v GiB na 3 des. mista, cele celociselnou aritmetikou
# (busybox nema bc/awk). `df -k` muze u dlouheho nazvu zarizeni zalomit
# vystup na dva radky (klasicka libc df kviha) - proto neparsujeme podle
# pozice sloupce, ale hledame pole KONCICI na "%" a bereme predchozi pole
# jako Available. Funguje bez ohledu na zalomeni.
get_space_gb() {
    df_out=$(df -k "$SDCARD" 2>/dev/null)
    if [ -z "$df_out" ]; then
        printf 'N/A'
        return
    fi

    avail_kb=""
    old_ifs="$IFS"
    IFS='
'
    for line in $df_out; do
        case "$line" in
            *%*) ;;
            *) continue ;;
        esac
        IFS=" $(printf '\t')"
        set -- $line
        IFS='
'
        prev=""
        for f in "$@"; do
            case "$f" in
                *%) avail_kb="$prev"; break ;;
            esac
            prev="$f"
        done
    done
    IFS="$old_ifs"

    case "$avail_kb" in
        ''|*[!0-9]*)
            printf 'N/A'
            return
            ;;
    esac

    whole=$((avail_kb / 1048576))
    frac=$(((avail_kb % 1048576) * 1000 / 1048576))
    printf '%d.%03dGB' "$whole" "$frac"
}

# get_signal_percent
# AT+CSQ vraci "+CSQ: <rssi>,<ber>". rssi je 0-31 (99 = nezname). Prevod
# na procenta: rssi*100/31. Parsovani jen pres parametrickou expanzi -
# zadne cut/awk.
get_signal_percent() {
    resp=$("$HUNTER_DIR/bin/atcmd" "$AT_PORT" "$AT_BAUD" "AT+CSQ" 3 2>/dev/null)

    line=""
    old_ifs="$IFS"
    IFS='
'
    for l in $resp; do
        case "$l" in
            *+CSQ:*) line="$l" ;;
        esac
    done
    IFS="$old_ifs"

    if [ -z "$line" ]; then
        printf 'N/A'
        return
    fi

    rest="${line#*+CSQ:}"
    while :; do
        case "$rest" in
            " "*) rest="${rest# }" ;;
            *) break ;;
        esac
    done
    rssi="${rest%%,*}"

    case "$rssi" in
        ''|*[!0-9]*)
            printf 'N/A'
            return
            ;;
    esac

    if [ "$rssi" -ge 99 ]; then
        printf 'N/A'
        return
    fi

    pct=$((rssi * 100 / 31))
    [ "$pct" -gt 100 ] && pct=100
    printf '%s%%' "$pct"
}

# get_battery_percent
# Baterie chodi z MCU po I2C, ktere je vlastnene puvodni aplikaci - do ni
# nesahame (viz spec sekce 8). Primy zdroj: AT+CBC na AT_PORT vraci napeti
# clanku, napr. "+CBC: 4.011V" (overeno na zarizeni 2026-08-31). Prevod na
# procenta je linearni aproximace pro 1-clankovou Li-ion/LiPo (3.3V = 0 %,
# 4.2V = 100 %) - je to odhad PREVODU, ne odhad CHYBEJICI hodnoty; kdyz
# odpoved neprijde nebo nema ocekavany format, je to porad N/A.
get_battery_percent() {
    resp=$("$HUNTER_DIR/bin/atcmd" "$AT_PORT" "$AT_BAUD" "AT+CBC" 5 2>/dev/null)

    line=""
    old_ifs="$IFS"
    IFS='
'
    for l in $resp; do
        case "$l" in
            *+CBC:*) line="$l" ;;
        esac
    done
    IFS="$old_ifs"

    if [ -z "$line" ]; then
        printf 'N/A'
        return
    fi

    rest="${line#*+CBC:}"
    while :; do
        case "$rest" in
            " "*) rest="${rest# }" ;;
            *) break ;;
        esac
    done

    # ocekavany format "D.DDDV" - jedna cislice, tecka, tri cislice, V.
    # Cokoli jineho (jiny format CBC na jinem firmwaru apod.) -> N/A,
    # nikdy hadat jiny tvar odpovedi.
    case "$rest" in
        [0-9].[0-9][0-9][0-9]V*) ;;
        *) printf 'N/A'; return ;;
    esac

    volt="${rest%%V*}"
    whole="${volt%%.*}"
    frac="${volt#*.}"
    fracval=$((1$frac - 1000))
    mv=$((whole * 1000 + fracval))

    if [ "$mv" -le 3300 ]; then
        pct=0
    elif [ "$mv" -ge 4200 ]; then
        pct=100
    else
        pct=$(( (mv - 3300) * 100 / 900 ))
    fi
    printf '%s%%' "$pct"
}

# build_status_body
# Tridradkove telo pro e-mail (viz Instructions.txt pozadavek na format).
build_status_body() {
    bat=$(get_battery_percent)
    sig=$(get_signal_percent)
    spc=$(get_space_gb)
    printf 'Battery: %s\nSignal: %s\nSpace: %s\n' "$bat" "$sig" "$spc"
}

# build_status_reply
# Kompaktni jednoradkova varianta pro SMS odpoved na STATUS (SMS ma
# limit ~160 znaku).
build_status_reply() {
    bat=$(get_battery_percent)
    sig=$(get_signal_percent)
    spc=$(get_space_gb)
    printf 'BAT:%s SIG:%s SPACE:%s' "$bat" "$sig" "$spc"
}
