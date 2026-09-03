#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

fixture_snap 260828 210948
fixture_snap 260829 080000
fixture_snap 260830 010000

count_lines() { printf '%s' "$1" | grep -c . ; }

# --- chybejici cursor = nejstarsi den na karte (spec 3.4) ---
rm -f "$STATE_DIR/cursor.txt"
assert_eq "chybejici cursor -> nejstarsi den" "$(cursor_read)" "260828"

# --- a chova se to jako dnes: vidi uplne vsechno ---
# 3 dny x 1 snimek. fixture_snap vyrabi dvojici snaps/ + HDPIC/, ale
# find_ready_candidates kouka JEN do snaps/ - proto 3, ne 6.
assert_eq "bez cursoru se najdou vsechny 3 fotky" \
          "$(count_lines "$(find_ready_candidates)")" "3"

# --- poskozeny cursor se ignoruje stejne jako chybejici ---
printf 'nesmysl\n' > "$STATE_DIR/cursor.txt"
assert_eq "poskozeny cursor -> nejstarsi den" "$(cursor_read)" "260828"
printf '\n' > "$STATE_DIR/cursor.txt"
assert_eq "prazdny cursor -> nejstarsi den" "$(cursor_read)" "260828"

# --- cursor novejsi nez nejnovejsi den na karte je nemozny stav (spec:
# cursor se nikdy neposune pres nejnovejsi slozku dne) a resi se stejne
# jako poskozeny cursor - NEklampuje se na nejnovejsi den, spadne az na
# nejstarsi, jinak by se tise preskocilo vse mezi skutecnou pozici a
# nejnovejsim dnem ---
cursor_write 270101
assert_eq "cursor za nejnovejsim dnem -> nejstarsi den (ne klamp)" \
          "$(cursor_read)" "260828"
assert_eq "cursor za nejnovejsim dnem -> najdou se vsechny fotky, ne nula" \
          "$(count_lines "$(find_ready_candidates)")" "3"

# --- nastaveny cursor odrizne starsi dny ---
cursor_write 260829
assert_eq "cursor se precte zpatky" "$(cursor_read)" "260829"
out=$(find_ready_candidates)
assert_not_contains "den pred cursorem se uz neprochazi" "$out" "260828"
assert_contains "den na cursoru se prochazi" "$out" "260829"
assert_contains "den za cursorem se prochazi" "$out" "260830"
assert_eq "zbyvaji 2 fotky ze dvou dnu" "$(count_lines "$out")" "2"

# --- POradi je chronologicky vzestupne (spoleha na to MAX_QUEUE) ---
cursor_write 260828
first=""
for line in $(find_ready_candidates); do
    [ -z "$first" ] && first="$line"
done
assert_contains "prvni kandidat je z nejstarsiho dne" "$first" "260828"

# --- sent_list.txt vyradi konkretni soubor, ne cely den ---
printf '%s\n' "$SDCARD/snaps/260829/080000_000_65535_P.jpg" > "$STATE_DIR/sent_list.txt"
out=$(find_ready_candidates)
assert_not_contains "odeslana fotka uz neni kandidat" "$out" "260829/080000"
assert_eq "po odecteni jedne zbyva 2" "$(count_lines "$out")" "2"

# --- shoda musi byt na CELY radek, ne na podretezec ---
: > "$STATE_DIR/sent_list.txt"
printf '%s\n' "$SDCARD/snaps/260830/010000_000_65535_P.jpg.bak" > "$STATE_DIR/sent_list.txt"
out=$(find_ready_candidates)
assert_contains "podobna cesta v sent_list nesmi vyradit skutecnou" \
                "$out" "260830/010000_000_65535_P.jpg"

# --- snapready odmita -> neni kandidat, ale den to NEuzavira (Task 4) ---
: > "$STATE_DIR/sent_list.txt"
printf '#!/bin/sh\ncase "$1" in *010000*) exit 1 ;; esac\nexit 0\n' \
    > "$HUNTER_DIR/bin/snapready"
chmod +x "$HUNTER_DIR/bin/snapready"
out=$(find_ready_candidates)
assert_not_contains "snapready odmitnuty soubor neni kandidat" "$out" "260830/010000"
printf '#!/bin/sh\nexit 0\n' > "$HUNTER_DIR/bin/snapready"
chmod +x "$HUNTER_DIR/bin/snapready"

# =====================================================================
# Posun cursoru (spec 2026-09-02, 3.2)
# =====================================================================

mark_sent() { printf '%s\n' "$1" >> "$STATE_DIR/sent_list.txt"; }

: > "$STATE_DIR/sent_list.txt"
cursor_write 260828

# --- nic neodeslano -> cursor se nehne ---
cursor_advance
assert_eq "bez odeslani se cursor nehne" "$(cursor_read)" "260828"

# --- day_fully_sent ---
assert_eq "nedoslany den neni fully_sent" "$(day_fully_sent 260828 && echo ano || echo ne)" "ne"
mark_sent "$SDCARD/snaps/260828/210948_000_65535_P.jpg"
assert_eq "doslany den je fully_sent" "$(day_fully_sent 260828 && echo ano || echo ne)" "ano"

# --- uzavreny nejstarsi den posune cursor na dalsi nedoslany ---
cursor_advance
assert_eq "po uzavreni 260828 stoji cursor na 260829" "$(cursor_read)" "260829"

# --- nejnovejsi den se NIKDY neuzavira, i kdyz je cely odeslany ---
mark_sent "$SDCARD/snaps/260829/080000_000_65535_P.jpg"
mark_sent "$SDCARD/snaps/260830/010000_000_65535_P.jpg"
cursor_advance
assert_eq "cursor se zastavi na nejnovejsim dni, nikdy za nim" \
          "$(cursor_read)" "260830"

# --- cursor se nikdy neposouva zpet ---
cursor_write 260830
: > "$STATE_DIR/sent_list.txt"
cursor_advance
assert_eq "prazdny sent_list cursor nevrati zpatky" "$(cursor_read)" "260830"

# --- soubor odmitany snapready drzi svuj den otevreny (spec 9.3) ---
cursor_write 260828
: > "$STATE_DIR/sent_list.txt"
printf '#!/bin/sh\ncase "$1" in *210948*) exit 1 ;; esac\nexit 0\n' \
    > "$HUNTER_DIR/bin/snapready"
chmod +x "$HUNTER_DIR/bin/snapready"
cursor_advance
assert_eq "den se souborem, ktery snapready odmita, zustava otevreny" \
          "$(cursor_read)" "260828"
printf '#!/bin/sh\nexit 0\n' > "$HUNTER_DIR/bin/snapready"
chmod +x "$HUNTER_DIR/bin/snapready"

# --- stara fotka pod cursorem se neuznava (spec omezeni 3) ---
# Kdyz se hodiny vratily zpatky, v starsi slozce se muze objevit nova
# fotka. find_ready_candidates ji nikdy neuvidí (omezeni 2: ta je prijata
# pres DATE/GET). Ale search pro nejstarsi otevreny den ji muze najit a
# dostat se do deadlocku - cursor by se mel pohybovat i kdyz je ta fotka
# tam, pokud jsou novejsi dny uzavrene.
cursor_write 260829
fixture_snap 260831 123456
: > "$STATE_DIR/sent_list.txt"
mark_sent "$SDCARD/snaps/260829/080000_000_65535_P.jpg"
mark_sent "$SDCARD/snaps/260830/010000_000_65535_P.jpg"
mark_sent "$SDCARD/snaps/260831/123456_000_65535_P.jpg"
cursor_advance
assert_eq "cursor se posoune pres starsi fotku, pokud se hodiny vratily" \
          "$(cursor_read)" "260831"

fixture_teardown
finish
