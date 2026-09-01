#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# fake mailrecv: "list unseen" vrati pripravene radky ze souboru,
# "seen" jen zapise UID do seen.log
cat > "$HUNTER_DIR/bin/mailrecv" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/listing.txt" 2>/dev/null; exit 0 ;;
    seen) shift; echo "\$@" >> "$FIX/seen.log"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$HUNTER_DIR/bin/mailrecv"

# fake mailsend: zapisuje argumenty do sent.log
cat > "$HUNTER_DIR/bin/mailsend" <<EOF
#!/bin/sh
echo "\$@" >> "$FIX/sent.log"
exit 0
EOF
chmod +x "$HUNTER_DIR/bin/mailsend"

ensure_app_frozen() { FROZEN=1; }
FROZEN=0

# --- autorizovany prikaz se vykona a odpovi ---
printf 'UIDVALIDITY|999\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_contains "klic vc. UIDVALIDITY v mail_seen" "$(cat "$STATE_DIR/mail_seen.txt")" "999|101"
assert_contains "oznaceno jako seen"      "$(cat "$FIX/seen.log")" "101"
assert_contains "odpoved odeslana"        "$(cat "$FIX/sent.log")" "HUNTER reply"
assert_eq       "aplikace zmrazena"       "$FROZEN" "1"

# --- odpoved nesmi citovat prichozi predmet (token!) ---
assert_not_contains "odpoved neobsahuje token" "$(cat "$FIX/sent.log")" "tajnytoken1"

# --- zprava bez prefixu se NEDOTKNE ---
printf 'UIDVALIDITY|999\nMSG|202|kdokoli@example.com|Newsletter: sleva 50%%\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_eq "cizi posta se neoznaci prectenou" "$(cat "$FIX/seen.log")" ""
assert_eq "na cizi postu se neodpovida"      "$(cat "$FIX/sent.log")" ""

# --- neautorizovany odesilatel: oznaci se, ale neodpovida ---
printf 'UIDVALIDITY|999\nMSG|303|cizi@example.com|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_contains "neautorizovany se oznaci prectenym" "$(cat "$FIX/seen.log")" "303"
assert_eq       "neautorizovanemu se neodpovida"     "$(cat "$FIX/sent.log")" ""

# --- deduplikace: stejne UID podruhe se nevykona ---
printf 'UIDVALIDITY|999\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 QUALITY LOW\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
QUALITY=HD
process_mail
assert_eq "duplicitni UID se nevykona" "$QUALITY" "HD"
assert_contains "ale oznaci se prectenym" "$(cat "$FIX/seen.log")" "101"

# --- jina UIDVALIDITY = jina schranka, stejne UID se vykona znovu ---
printf 'UIDVALIDITY|1000\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 QUALITY LOW\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
QUALITY=HD
process_mail
assert_eq "po zmene UIDVALIDITY se vykona" "$QUALITY" "LOW"

# --- token se nikde nezaloguje (kumulativne za cely beh testu) ---
assert_not_contains "log souboru neobsahuje token" "$(cat "$LOG_FILE")" "tajnytoken1"

fixture_teardown
finish
