# sms.sh - prijem, autorizace, vykonani SMS prikazu (viz spec sekce 7).
#
# Poradi kroku pro kazdou zpravu je zamerne: dedup-zapis PRED vykonanim,
# smazani z ulozistě modulu AZ PO vykonani a pripadne odpovedi. Kdyby
# zarizeni zhaslo mezi vykonanim a smazanim, dalsi probuzeni uvidi
# stejnou zpravu znovu - ale sms_seen.txt uz ji ma zapsanou, takze se jen
# tise smaze bez druheho vykonani. U WIPE by dvojite vykonani nevadilo,
# ale principem to ma platit pro vsechny prikazy stejne.
#
# Samotny vykonavac prikazu (drive execute_sms_command, ted execute_command)
# se presunul do lib/command.sh - je transportne nezavisly a pouziva ho
# i e-mailovy kanal (lib/mailcmd.sh). Tenhle soubor uz drzi jen SMS
# transport: prijem, dedup, autorizaci a odeslani odpovedi.

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

        # Az ted je jiste, ze se prikaz opravdu vykona - zmrazit aplikaci,
        # aby zarizeni nezhaslo uprostred zpracovani. Zamerne AZ PO
        # is_master, ne hned po dedup kontrole - jinak by se zmrazovalo i
        # pro SMS od neautorizovaneho cisla, ktere se nakonec vubec
        # nevykona (stejna oprava jako u process_mail v Tasku 12).
        ensure_app_frozen

        log "SMS od $from: $body"
        CMD_REPLY=""
        # SMS transport nezna tokeny (zadne mail.token pole ve zprave) -
        # druhy argument je vzdy 0, takze privilegovane prikazy (AUTH
        # TYPE, ADD, REMOVE, ADD TOKEN, REMOVE TOKEN) pres SMS nejdou a
        # vraci "TOKEN REQUIRED". Zustavaji pristupne jen nezmenujici
        # OPRAVNENI prikazy (STATUS, FOTO, QUALITY, CONFIRM, WIPE).
        execute_command "$body" 0
        reply="$CMD_REPLY"

        if [ "$CONFIRM" = "ON" ] && [ -n "$reply" ]; then
            "$HUNTER_DIR/bin/smssend" "$AT_PORT" "$AT_BAUD" "$from" "$reply" >>"$LOG_FILE" 2>&1
        fi

        "$HUNTER_DIR/bin/smsrecv" "$AT_PORT" "$AT_BAUD" del "$idx" >>"$LOG_FILE" 2>&1
        IFS='
'
    done
    IFS="$old_ifs"
}
