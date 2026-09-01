# mailcmd.sh - transport prikazu pres e-mail (IMAP).
#
# Zrcadlo lib/sms.sh: nacte neprectene zpravy, autorizuje, vykona pres
# spolecny execute_command() z lib/command.sh, odpovi a uklidi.
#
# Poradi kroku je zamerne stejne jako u SMS: dedup-zapis PRED vykonanim,
# oznaceni \Seen AZ PO vykonani a odpovedi. Kdyby zarizeni zhaslo mezi
# vykonanim a oznacenim, priste je zprava porad neprectena - ale
# mail_seen.txt uz UID ma, takze se jen tise oznaci bez druheho vykonani.
#
# TVRDE PRAVIDLO: zpravy bez prefixu "HUNTER " se NEDOTYKAME vubec -
# ani ji neoznacime prectenou. Ctem stejnou schranku, ze ktere Hunter
# odesila, a nesmime prebirat cizi postu.

process_mail() {
    [ -n "$IMAP_HOST" ] || { log "IMAP_HOST nenastaven, prikazy preskoceny"; return 0; }
    [ -f "$HUNTER_DIR/smtp.pass" ] || { log "chybi smtp.pass, prikazy preskoceny"; return 0; }

    listing=$("$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
                "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
                list unseen 2>>"$LOG_FILE")
    [ -z "$listing" ] && return 0

    # UIDVALIDITY je soucasti dedup klice: po (vzacnem) znovuvytvoreni
    # schranky zacnou UID od zacatku a bez tohoto cisla by se novy prikaz
    # mohl tise preskocit jako "uz zpracovany".
    mail_uidvalidity="0"

    old_ifs="$IFS"
    IFS='
'
    for line in $listing; do
        IFS="$old_ifs"
        case "$line" in
            UIDVALIDITY\|*)
                mail_uidvalidity="${line#*|}"
                IFS='
'; continue ;;
            MSG\|*) ;;
            *) IFS='
'; continue ;;
        esac

        # MSG|uid|odesilatel|predmet - predmet je POSLEDNI pole a muze
        # obsahovat "|", takze se zbytek po tretim poli spoji zpet.
        field_ifs="$IFS"
        IFS='|'
        set -- $line
        IFS="$field_ifs"

        uid="$2"
        from="$3"
        shift 3
        subject="$*"

        # Zprava, ktera neni nase - NESAHAT na ni.
        case "$subject" in
            [Hh][Uu][Nn][Tt][Ee][Rr]" "*) ;;
            *) IFS='
'; continue ;;
        esac

        key="$mail_uidvalidity|$uid"
        if [ -f "$STATE_DIR/mail_seen.txt" ] && \
           fgrep -qxF "$key" "$STATE_DIR/mail_seen.txt" 2>/dev/null; then
            log "mail UID $uid jiz zpracovan drive (vypadek napajeni?), jen oznacuji"
            "$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
                "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
                seen "$uid" >>"$LOG_FILE" 2>&1
            IFS='
'; continue
        fi

        # Az ted je jiste, ze je co delat - zmrazit aplikaci, aby
        # zarizeni nezhaslo uprostred zpracovani.
        ensure_app_frozen

        printf '%s\n' "$key" >> "$STATE_DIR/mail_seen.txt"
        sync

        authorize_mail "$from" "$subject"
        if [ "$AUTH_OK" != 1 ]; then
            # Token se NIKDY neloguje - logujeme jen odesilatele.
            log "mail od '$from' neautorizovan (rezim $AUTH_TYPE), odmitnuto bez odpovedi"
            "$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
                "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
                seen "$uid" >>"$LOG_FILE" 2>&1
            IFS='
'; continue
        fi

        log "mail prikaz od $from: $AUTH_CMD"
        CMD_REPLY=""
        execute_command "$AUTH_CMD" "$AUTH_HAS_TOKEN"

        if [ "$CONFIRM" = "ON" ] && [ -n "$CMD_REPLY" ]; then
            send_reply_mail "$from" "$CMD_REPLY"
        fi

        "$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
            "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
            seen "$uid" >>"$LOG_FILE" 2>&1

        IFS='
'
    done
    IFS="$old_ifs"
}
