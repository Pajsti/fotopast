#!/bin/bash
#
# build.sh - postavi testovaci nastroje pro fotopast (mipsel, staticky).
#
# Spoustet ve WSL Ubuntu ze slozky test_files:
#   wsl bash build.sh
#
# Co udela:
#   1. doinstaluje mipsel toolchain (potrebuje sudo, jednorazove)
#   2. stahne a prelozi mbedTLS 2.28 pro mipsel do build/mbedtls
#   3. spusti make
#
# mbedTLS je pinnuty na 2.28 (LTS) zamerne: rada 3.6 vyzaduje
# psa_crypto_init() a ma jinak resenou konfiguraci, coz by tu jen
# pridalo prace navic.

set -euo pipefail

MBEDTLS_VER="v2.28.8"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
PREFIX="$BUILD/mbedtls"
CROSS="mipsel-linux-gnu-"

say() { printf '\n=== %s ===\n' "$*"; }

# Pi Zero 2 W ma 512 MB RAM - plny -j nproc tam preklad mbedTLS zazene
# do swapu a je to pomalejsi, nez kdyz se drzi zkratka.
pick_jobs() {
	local kb
	kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
	if   [ "$kb" -lt 1048576 ]; then echo 2
	elif [ "$kb" -lt 2097152 ]; then echo 3
	else nproc
	fi
}
JOBS="${JOBS:-$(pick_jobs)}"

# ---------------------------------------------------------------- toolchain
if ! command -v "${CROSS}gcc" > /dev/null 2>&1; then
	say "instaluji mipsel toolchain (sudo)"
	sudo apt-get update
	sudo apt-get install -y gcc-mipsel-linux-gnu build-essential git wget
else
	echo "toolchain: $(command -v "${CROSS}gcc")"
fi

for t in git make; do
	command -v "$t" > /dev/null 2>&1 || { sudo apt-get install -y "$t"; }
done

mkdir -p "$BUILD"

# ------------------------------------------------------------------ mbedTLS
if [ ! -f "$PREFIX/lib/libmbedtls.a" ]; then
	say "stahuji a prekladam mbedTLS $MBEDTLS_VER pro mipsel"

	if [ ! -d "$BUILD/mbedtls-src" ]; then
		git clone --depth 1 --branch "$MBEDTLS_VER" \
			https://github.com/Mbed-TLS/mbedtls.git "$BUILD/mbedtls-src"
	fi

	cd "$BUILD/mbedtls-src"
	make clean > /dev/null 2>&1 || true

	# Jen knihovny; programy a testy nepotrebujeme a jen by build zdrzely.
	make lib \
		CC="${CROSS}gcc" \
		AR="${CROSS}ar" \
		LD="${CROSS}ld" \
		CFLAGS="-O2 -fno-strict-aliasing -mfp32" \
		-j"$JOBS"

	# Kopirujeme rucne misto `make install`: install v 2.28 zavisi na
	# cili no_test, ktery by zbytecne stavel i ukazkove programy.
	mkdir -p "$PREFIX/include" "$PREFIX/lib"
	cp -r include/mbedtls "$PREFIX/include/"
	if [ -d include/psa ]; then cp -r include/psa "$PREFIX/include/"; fi
	cp library/libmbedtls.a library/libmbedx509.a library/libmbedcrypto.a \
		"$PREFIX/lib/"
	cd "$HERE"
else
	echo "mbedTLS uz je postavena v $PREFIX"
fi

# -------------------------------------------------------------------- tools
say "prekladam nastroje"
cd "$HERE"
make clean > /dev/null 2>&1 || true
make MBEDTLS="$PREFIX"

say "hotovo"
for f in atcmd smssend smsrecv mailsend; do
	if [ -f "$f" ]; then
		printf '%-10s %8s B  %s\n' "$f" "$(stat -c %s "$f")" \
			"$(file -b "$f" | cut -c1-60)"
	fi
done

cat <<'MSG'

Zkopiruj binarky na SD kartu do hunter/ a na zarizeni je spoustej odtud.
Na VFAT/exFAT nejdou nastavit prava, ale karta se mountuje s vychozim
0755, takze se spousti primo.
MSG
