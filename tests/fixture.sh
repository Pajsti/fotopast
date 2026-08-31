# tests/fixture.sh - postavi docasne prostredi Hunteru pro testy.
#
# Vytvori adresar s bin/, state/, config.txt a mail.token, nastavi
# HUNTER_DIR/SDCARD/LOG_FILE a nacte knihovny. Kazdy test si vola
# fixture_setup na zacatku a fixture_teardown na konci.

fixture_setup() {
    FIX=$(mktemp -d)
    HUNTER_DIR="$FIX/hunter"
    SDCARD="$FIX/sdcard"
    STATE_DIR="$HUNTER_DIR/state"
    CONFIG_FILE="$HUNTER_DIR/config.txt"
    LOG_FILE="$HUNTER_DIR/log.txt"
    TOKEN_FILE="$HUNTER_DIR/mail.token"

    mkdir -p "$HUNTER_DIR/bin" "$STATE_DIR" "$SDCARD/snaps/260828" "$SDCARD/HDPIC/260828"
    : > "$LOG_FILE"

    cat > "$CONFIG_FILE" <<'EOF'
MASTERS=+420603284430
MAIL_MASTERS=paja.stindl@seznam.cz
QUALITY=HD
CONFIRM=ON
AUTH_TYPE=TOKEN
SMTP_HOST=smtp.example.cz
SMTP_PORT=465
SMTP_USER=fotopast@example.cz
SMTP_TO=paja.stindl@seznam.cz
SMTP_TLS=implicit
IMAP_HOST=imap.example.cz
IMAP_PORT=993
AT_PORT=/dev/null
AT_BAUD=115200
SNAP_WAIT=1
MAX_SEND_PER_WAKE=3
REQUEST_MAX=5
RUN_DEADLINE=180
EOF

    printf 'tajnytoken1\n' > "$TOKEN_FILE"

    # fake snapready: vsechno je "pripravene"
    printf '#!/bin/sh\nexit 0\n' > "$HUNTER_DIR/bin/snapready"
    chmod +x "$HUNTER_DIR/bin/snapready"

    # fake atcmd: nic nevraci (STATUS pak da N/A)
    printf '#!/bin/sh\nexit 1\n' > "$HUNTER_DIR/bin/atcmd"
    chmod +x "$HUNTER_DIR/bin/atcmd"

    ROOT=$(cd "$(dirname "$0")/.." && pwd)
    . "$ROOT/hunter/lib/common.sh"
    . "$ROOT/hunter/lib/status.sh"
    . "$ROOT/hunter/lib/mail.sh"
    . "$ROOT/hunter/lib/command.sh"

    load_config
}

fixture_teardown() {
    [ -n "$FIX" ] && rm -rf "$FIX"
}

# fixture_snap <YYMMDD> <HHMMSS> - vyrobi dvojici snaps/ + HDPIC/
fixture_snap() {
    mkdir -p "$SDCARD/snaps/$1" "$SDCARD/HDPIC/$1"
    printf 'jpegdata' > "$SDCARD/snaps/$1/$2_000_65535_P.jpg"
    printf 'hdjpegdata' > "$SDCARD/HDPIC/$1/$2_000_65535_PH.jpg"
}
