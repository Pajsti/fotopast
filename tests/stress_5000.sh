#!/bin/sh
# tests/stress_5000.sh - rucni zatezovy test, NENI soucasti bezne sady
# (bez prefixu test_ - "for f in tests/test_*.sh" ho preskoci).
#
# Odpoved na otazku 2026-09-22: "jak se Hunter zachova, kdyz sent_list.txt
# naroste na 5000 zaznamu a snaps/ na 5000 souboru?" Bezi na PC pod
# dash, ne na realnem MIPS busybox ash s nekolika MB RAM - zmeri tedy
# ALGORITMICKE chovani (roste to linearne? kvadraticky? kolik bajtu
# drzi nejvetsi jedna promenna?), ne presne cislo v MB na zarizeni.
#
# Spusteni: dash tests/stress_5000.sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

echo "=== priprava: 5000 souboru / 100 dnu, vsechny v sent_list.txt ==="

DAYS=100
PER_DAY=50
day_n=0
while [ "$day_n" -lt "$DAYS" ]; do
    # 6-mistny den ve tvaru 26NN01 - NN (00-99) je jedina promenna
    # slozka, aby kazdy den byl jiny existujici adresar. Presna
    # kalendarni platnost je jedno, snap_num6 chce jen 6 cislic.
    nn=$(printf '%02d' "$day_n")
    d="26${nn}01"
    mkdir -p "$SDCARD/snaps/$d"
    f_n=0
    while [ "$f_n" -lt "$PER_DAY" ]; do
        hh=$(printf '%06d' "$f_n")
        path="$SDCARD/snaps/$d/${hh}_000_65535_N.jpg"
        printf 'x' > "$path"
        printf '%s\n' "$path" >> "$STATE_DIR/sent_list.txt"
        f_n=$((f_n + 1))
    done
    day_n=$((day_n + 1))
done
sync

oldest_day="260001"
newest_day="269901"

total_files=$(find "$SDCARD/snaps" -name '*.jpg' | grep -c .)
total_sent=$(grep -c . "$STATE_DIR/sent_list.txt")
sent_bytes=$(stat -c %s "$STATE_DIR/sent_list.txt")
echo "souboru na karte: $total_files, radku v sent_list.txt: $total_sent, velikost: $sent_bytes B"

# --- 1) steady-state: cursor u posledniho dne + JEDNA nova nedoslana fotka ---
mkdir -p "$SDCARD/snaps/$newest_day"
printf 'x' > "$SDCARD/snaps/$newest_day/999999_000_65535_N.jpg"
cursor_write "$newest_day"

echo
echo "=== 1) steady-state (cursor u posledniho dne, 1 novy kandidat) ==="
t0=$(date +%s%N)
result=$(find_ready_candidates)
t1=$(date +%s%N)
n=$(printf '%s\n' "$result" | grep -c .)
assert_eq "steady-state: najde presne 1 kandidata" "$n" "1"
echo "nalezeno kandidatu: $n, cas: $(( (t1 - t0) / 1000000 )) ms"

# --- 2) nejhorsi pripad: cursor uvazly u nejstarsiho dne ---
cursor_write "$oldest_day"
echo
echo "=== 2) nejhorsi pripad (cursor u nejstarsiho dne, sken VSECH 100 dnu) ==="
t0=$(date +%s%N)
result=$(find_ready_candidates)
t1=$(date +%s%N)
n=$(printf '%s\n' "$result" | grep -c .)
assert_eq "nejhorsi pripad: porad najde presne 1 kandidata" "$n" "1"
echo "nalezeno kandidatu: $n, cas: $(( (t1 - t0) / 1000000 )) ms"

# --- 3) velikost nejvetsi _slice promenne (jeden den, fgrep vysledek) ---
# Kazdy den ma presne PER_DAY=50 zaznamu, takze slice je pro kazdy den
# stejne velka - reprezentativni vzorek staci jeden.
slice=$(fgrep "/snaps/$oldest_day/" "$STATE_DIR/sent_list.txt")
slice_bytes=$(printf '%s' "$slice" | wc -c)
echo
echo "=== 3) velikost jedne _slice promenne (50 zaznamu/den) ==="
echo "bajtu: $slice_bytes"

# --- 4) WIPE: precte a prepise CELY sent_list.txt (neni cursor-bounded) ---
echo
echo "=== 4) wipe_sent_snaps() - cely pruchod 5000 radku ==="
t0=$(date +%s%N)
wipe_sent_snaps
t1=$(date +%s%N)
echo "smazano souboru: $WIPE_COUNT, cas: $(( (t1 - t0) / 1000000 )) ms"
assert_eq "WIPE: smazalo vsech 5000 zaznamu" "$WIPE_COUNT" "5000"
remaining=$(grep -c . "$STATE_DIR/sent_list.txt" 2>/dev/null || echo 0)
assert_eq "WIPE: sent_list.txt je po smazani prazdny (vse bylo *.jpg pod snaps/)" "$remaining" "0"

echo
echo "=== shrnuti ==="
echo "5000 souboru + 5000 radku sent_list.txt zpracovano bez chyby."
echo "list_unsent_snaps/day_fully_sent jsou cursor-bounded - fgrep bezi jen"
echo "na dnech OD CURSORU, ne na vsech 100. WIPE cursor-bounded NENI a cte"
echo "cely soubor, ale radek po radku (while read), ne vsechno najednou."

fixture_teardown
finish
