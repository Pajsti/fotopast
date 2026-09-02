#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

A="$SDCARD/snaps/260828/210948_000_65535_P.jpg"
B="$SDCARD/snaps/260828/220000_000_65535_P.jpg"
C="$SDCARD/snaps/260829/080000_000_65535_P.jpg"

# --- snap_num6 ---
snap_num6 "260828" && r=0 || r=1
assert_eq "snap_num6 bere 6 cislic" "$r" "0"
snap_num6 "26082" && r=0 || r=1
assert_eq "snap_num6 odmita 5 cislic" "$r" "1"
snap_num6 "2608288" && r=0 || r=1
assert_eq "snap_num6 odmita 7 cislic" "$r" "1"
snap_num6 "26082a" && r=0 || r=1
assert_eq "snap_num6 odmita pismeno" "$r" "1"
snap_num6 "" && r=0 || r=1
assert_eq "snap_num6 odmita prazdny retezec" "$r" "1"

# --- snap_newer: tyz den, ruzny cas ---
snap_newer "$B" "$A" && r=0 || r=1
assert_eq "pozdejsi cas tyz den je novejsi" "$r" "0"
snap_newer "$A" "$B" && r=0 || r=1
assert_eq "drivejsi cas tyz den neni novejsi" "$r" "1"

# --- snap_newer: ruzne dny ---
snap_newer "$C" "$B" && r=0 || r=1
assert_eq "novejsi den vyhrava i pri drivejsim case" "$r" "0"
snap_newer "$B" "$C" && r=0 || r=1
assert_eq "starsi den prohrava i pri pozdejsim case" "$r" "1"

# --- snap_newer: shodne ---
snap_newer "$A" "$A" && r=0 || r=1
assert_eq "shodna cesta neni novejsi sama nez sebe" "$r" "1"

# --- snap_newer: neplatne tvary ---
# a neplatne -> vraci 1 (nesmi vyhrat); b neplatne -> vraci 0
snap_newer "$SDCARD/snaps/xxxxxx/210948_000_65535_P.jpg" "$A" && r=0 || r=1
assert_eq "neplatne 'a' nevyhrava" "$r" "1"
snap_newer "$A" "$SDCARD/snaps/xxxxxx/210948_000_65535_P.jpg" && r=0 || r=1
assert_eq "proti neplatnemu 'b' vyhrava platne 'a'" "$r" "0"

# --- pomocne funkce zustavaji funkcni (jsou to ctitelne pojmenovane
# operace, jen se uz nevolaji v horke smycce) ---
assert_eq "snap_date_of" "$(snap_date_of "$A")" "260828"
assert_eq "snap_time_of" "$(snap_time_of "$A")" "210948"

fixture_teardown
finish
