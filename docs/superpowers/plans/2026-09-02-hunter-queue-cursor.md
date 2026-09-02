# Fronta a cursor — implementační plán

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aby Hunter fungoval stejně dobře s pěti tisíci fotkami na kartě jako s pěti sty, a aby šlo frontu nedodělku omezit i ručně vyprázdnit.

**Architecture:** Automatická větev přestane procházet celou historii — nový `state/cursor.txt` drží poslední vyřízený den a hledání kandidátů se omezí na dny od něj dál, s jedním `fgrep` na den místo jednoho na soubor. `LAST N` se přepíše z N průchodů celým stromem na průchod složkami dnů od nejnovější s předčasným ukončením a bez forků v porovnávání. Na cursor se pak navěsí `CLEAR QUEUE` a `MAX_QUEUE`.

**Tech Stack:** POSIX shell (busybox ash na zařízení, `dash` v testech), C nástroje se v tomhle plánu nemění.

**Spec:** [docs/superpowers/specs/2026-09-02-hunter-queue-cursor-design.md](../specs/2026-09-02-hunter-queue-cursor-design.md)

## Global Constraints

Kopie z existujících specu a z hlavičky `hunter/lib/common.sh` — platí pro každý task:

- **Busybox na zařízení nemá `awk`, `sed`, `cut`, `sort`, `uniq`, `wc`, `head`, `tail`, `expr`, `tee` ani `bc`.** Z appletů se smí jen `grep`/`fgrep`, `find`, `tr`, `date`, `mkdir`, `mv`, `rm`, `sync`, `printf`. Field extraction jde přes parametrickou expanzi (`${var#...}`/`${var%...}`) a `case`.
- **`tr` jen s explicitními rozsahy** (`tr 'A-Z' 'a-z'`), nikdy POSIX třídy — `FEATURE_TR_CLASSES` je volitelný compile-time přepínač.
- **Žádný doslovný TAB (0x09) a žádné CR** v souborech pod `hunter/`. Žádná diakritika v `hunter/**` (ani v komentářích).
- **Signály vždy jménem** (`-STOP`, `-CONT`, `-TERM`), nikdy číslem — MIPS má jiná čísla.
- **Aritmetika je 32bitová.** Datum a čas se porovnávají jako dvě šestimístná čísla zvlášť, nikdy jako jedno dvanáctimístné.
- **Testy:** `sh tests/run_tests.sh` (běží pod `dash`). Každý task končí zelenou celou sadou, ne jen svým souborem.
- **Commity** v češtině bez diakritiky, ve stylu `git log --oneline`. Na konci `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **Nikdy neupravovat `hunter/lib/*.sh` přímo na Raspberry Pi** — repo je na Windows, na Pi se jen kompiluje C. Tenhle plán C nemění, takže se s Pi vůbec nepracuje.

---

### Task 1: `snap_num6` do common.sh a `snap_newer` bez forků

Spec 8.1. Dnes `snap_newer` volá `snap_date_of`/`snap_time_of` přes `$( )`, což jsou **4 forky na jedno porovnání**, a volá se v cyklu přes všechny soubory. Funkce navíc dnes nemá žádný test.

`snap_num6` se přesouvá do `common.sh`, protože ho budou potřebovat i cursor helpery (Task 3), a `common.sh` se načítá jako první v `hunter.sh` i v `tests/fixture.sh`.

**Files:**
- Modify: `hunter/lib/common.sh` (přidat `snap_num6`)
- Modify: `hunter/lib/command.sh:257-275` (odebrat `snap_num6`, přepsat `snap_newer`)
- Create: `tests/test_snaporder.sh`

**Interfaces:**
- Produces: `snap_num6 <retezec>` → 0 když je to přesně 6 číslic, jinak 1. Nově v `common.sh`.
- Produces: `snap_newer <a> <b>` → 0 když `a` je novější než `b`. Signatura beze změny.
- Consumes: nic z předchozích tasků.

- [ ] **Step 1: Napiš padající test**

Vytvoř `tests/test_snaporder.sh`:

```sh
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
```

- [ ] **Step 2: Spusť test, ověř že padá**

Run: `sh tests/test_snaporder.sh`
Expected: FAIL — `snap_num6` zatím není v `common.sh`, takže po přesunu v dalším kroku musí projít; před přesunem projde jen díky tomu, že ho zatím poskytuje `command.sh`. Zapiš do reportu, které asserty prošly a které ne, ať je vidět výchozí stav.

- [ ] **Step 3: Přesuň `snap_num6` do `common.sh`**

V `hunter/lib/common.sh` přidej (nad `load_config`, k ostatním sdíleným pomocníkům):

```sh
# snap_num6 <retezec>
# 0, kdyz je vstup presne 6 cislic. Pouziva se na overeni YYMMDD i
# HHMMSS - obe casti cesty ke snimku, a taky nazvy slozek dnu.
# Sestimistne cislo (max 999999) se vejde do 32bitove aritmetiky, takze
# se pak da porovnavat pres -gt/-lt.
snap_num6() {
    case "$1" in [0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;; esac
    return 1
}
```

V `hunter/lib/command.sh` **smaž** starou definici:

```sh
snap_num6() {
    case "$1" in [0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;; esac
    return 1
}
```

- [ ] **Step 4: Přepiš `snap_newer` bez forků**

V `hunter/lib/command.sh` nahraď celé tělo `snap_newer`:

```sh
# snap_newer <a> <b> -> 0 kdyz a je novejsi nez b
#
# Datum a cas se tahaji INLINE parametrickou expanzi, ne pres
# snap_date_of/snap_time_of - kazde $( ) je fork a tahle funkce se vola
# v cyklu pres vsechny soubory dne. Puvodni varianta stala 4 forky na
# jedno porovnani, coz pri tisicich fotek delalo z LAST N radove
# statisice procesu (spec 2026-09-02, sekce 1.2).
snap_newer() {
    sp=${1%/*}; ad=${sp##*/}
    sb=${1##*/}; at=${sb%%_*}
    sp=${2%/*}; bd=${sp##*/}
    sb=${2##*/}; bt=${sb%%_*}
    snap_num6 "$ad" && snap_num6 "$at" || return 1
    snap_num6 "$bd" && snap_num6 "$bt" || return 0
    [ "$ad" -gt "$bd" ] && return 0
    [ "$ad" -lt "$bd" ] && return 1
    [ "$at" -gt "$bt" ] && return 0
    return 1
}
```

`snap_date_of`/`snap_time_of` **nech definované** — jsou to čitelné pojmenované operace a testy je ověřují; jen se už nevolají uvnitř `snap_newer`.

- [ ] **Step 5: Spusť testy**

Run: `sh tests/test_snaporder.sh` → Expected: PASS, všechny asserty
Run: `sh tests/run_tests.sh` → Expected: všechny sady zelené (počet sad o 1 vyšší než dřív)

- [ ] **Step 6: Ověř, že v `snap_newer` opravdu nezůstal fork**

Run: `grep -n '\$(' hunter/lib/command.sh | grep -A0 snap`
Expected: žádný výskyt `$(` mezi řádky `snap_newer`. Ověř očima celé tělo funkce.

- [ ] **Step 7: Commit**

```bash
git add hunter/lib/common.sh hunter/lib/command.sh tests/test_snaporder.sh
git commit -m "perf: snap_newer bez forku, snap_num6 do common.sh

snap_newer volal snap_date_of/snap_time_of pres \$( ), tedy 4 forky na
jedno porovnani - a vola se v cyklu pres vsechny soubory. Ted se datum
a cas tahaji inline parametrickou expanzi.

snap_num6 se presouva do common.sh, protoze ho budou potrebovat i
cursor helpery a common.sh se nacita jako prvni.

Test: novy tests/test_snaporder.sh - dosud tyhle funkce nepokryval
zadny test.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `list_snap_days` a `request_last` s předčasným ukončením

Spec 8.2. Dnes `request_last` hledá N-krát maximum přes celý strom. Nově jde po složkách dnů od nejnovější a skončí, jakmile má N kusů.

**Files:**
- Modify: `hunter/lib/common.sh` (přidat `list_snap_days`)
- Modify: `hunter/lib/command.sh:280-304` (přepsat `request_last`)
- Modify: `tests/test_request.sh` (přidat testy na pořadí a na dosah za cursor)

**Interfaces:**
- Consumes: `snap_num6` a `snap_newer` z Tasku 1.
- Produces: `list_snap_days` → vypíše názvy složek dnů v `snaps/` (jen jméno, ne cesta), jeden na řádek, v pořadí globu (tedy vzestupně). Konzumuje Task 3 a 4.
- Produces: `request_last <N>` — signatura beze změny.

- [ ] **Step 1: Napiš padající test**

Přidej na konec `tests/test_request.sh` **před** `fixture_teardown`:

```sh
# =====================================================================
# Poradi a dosah LAST (spec 2026-09-02, 8.2 a 8.3)
# =====================================================================

# --- LAST vraci OPRAVDU nejnovejsi, ne jen "nejakych N" ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 1" 1
assert_eq "LAST 1 vrati nejnovejsi fotku (260830 030000)" \
          "$REQUESTED_SNAPS" "$SDCARD/snaps/260830/030000_000_65535_P.jpg"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 3" 1
assert_contains "LAST 3 obsahuje nejnovejsi" "$REQUESTED_SNAPS" "260830/030000"
assert_contains "LAST 3 obsahuje druhou nejnovejsi" "$REQUESTED_SNAPS" "260830/020000"
assert_contains "LAST 3 obsahuje treti nejnovejsi" "$REQUESTED_SNAPS" "260830/010000"
assert_not_contains "LAST 3 uz nesaha na starsi den" "$REQUESTED_SNAPS" "260829"

# --- LAST prekroci hranici dne, kdyz v nejnovejsim dni neni dost ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 4" 1
assert_contains "LAST 4 sahne i do predchoziho dne" "$REQUESTED_SNAPS" "260829/080000"
assert_eq "LAST 4 vrati presne 4" "$(count_lines "$REQUESTED_SNAPS")" "4"

# --- LAST IGNORUJE cursor: musi dosahnout i na uzavreny den ---
# Tohle je regrese, ktera by rozbila cely smysl vyzadani (spec 8.3).
printf '260830\n' > "$STATE_DIR/cursor.txt"
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 4" 1
assert_contains "LAST sahne i na den PRED cursorem" "$REQUESTED_SNAPS" "260829/080000"
rm -f "$STATE_DIR/cursor.txt"
```

- [ ] **Step 2: Spusť test, ověř že padá**

Run: `sh tests/test_request.sh`
Expected: FAIL na `LAST 1 vrati nejnovejsi fotku` nebo dalších — dnešní implementace pořadí sice trefí, ale test na cursor prochází jen náhodou (cursor zatím nikdo nečte). Zapiš skutečný výsledek do reportu.

- [ ] **Step 3: Přidej `list_snap_days` do `common.sh`**

```sh
# list_snap_days
# Vypise nazvy slozek dnu v snaps/ (jen jmeno, ne cesta), jeden na
# radek. Pouziva se glob, ne find - glob je serazeny lexikograficky, coz
# je u YYMMDD zaroven chronologicky, a nestoji ani jeden fork.
# Nazvy dnu neobsahuji mezery, takze u volajiciho staci bezne deleni
# slov, zadne hratky s IFS.
list_snap_days() {
    for _lsd in "$SDCARD"/snaps/*/; do
        [ -d "$_lsd" ] || continue
        _lsd=${_lsd%/}
        printf '%s\n' "${_lsd##*/}"
    done
}
```

- [ ] **Step 4: Přepiš `request_last`**

V `hunter/lib/command.sh` nahraď celou funkci `request_last`:

```sh
# request_last <N> - N nejnovejsich fotek.
#
# Jde po slozkach dnu od NEJNOVEJSI a konci, jakmile ma N kusu - ne
# N-krat pres cely strom, jak to delala puvodni verze. Pri tisicich
# fotek byl puvodni postup neunosny (spec 2026-09-02, 1.2).
#
# Cursor se ZAMERNE ignoruje a sent_list.txt taky: vyzadane fotky maji
# dosahnout i na dny, ktere uz automatika uzavrela, a na uz odeslane
# snimky (spec 2026-09-02, 8.3).
request_last() {
    want="$1"
    [ "$want" -gt "$REQUEST_MAX" ] && want="$REQUEST_MAX"

    added=0
    days=$(list_snap_days)

    while [ "$added" -lt "$want" ]; do
        # nejnovejsi dosud nezpracovany den
        newest=""
        for d in $days; do
            snap_num6 "$d" || continue
            if [ -z "$newest" ] || [ "$d" -gt "$newest" ]; then
                newest="$d"
            fi
        done
        [ -z "$newest" ] && break

        # z tohohle dne ber od nejnovejsiho, dokud neni dost
        taken=""
        while [ "$added" -lt "$want" ]; do
            best=""
            for f in "$SDCARD/snaps/$newest"/*.jpg; do
                [ -f "$f" ] || continue
                case "
$taken" in
                    *"
$f"*) continue ;;
                esac
                if [ -z "$best" ] || snap_newer "$f" "$best"; then
                    best="$f"
                fi
            done
            [ -z "$best" ] && break
            taken="$taken
$best"
            request_add "$best" || return 0
            added=$((added + 1))
        done

        # den vycerpan - odeber ho ze seznamu a jdi na starsi
        days=$(printf '%s\n' "$days" | grep -v -x -F "$newest")
    done
}
```

- [ ] **Step 5: Spusť testy**

Run: `sh tests/test_request.sh` → Expected: PASS včetně nových assertů
Run: `sh tests/run_tests.sh` → Expected: všechny sady zelené

- [ ] **Step 6: Commit**

```bash
git add hunter/lib/common.sh hunter/lib/command.sh tests/test_request.sh
git commit -m "perf: request_last jde po dnech a konci predcasne

Puvodne N pruchodu celym stromem (pro kazdou hledanou fotku jeden).
Ted se jde po slozkach dnu od nejnovejsi a konci se, jakmile je N kusu
- pri LAST 5 se typicky sahne na jeden dva dny.

Pridano list_snap_days do common.sh (glob misto find, radi
chronologicky a nestoji fork) - vyuzije ho i cursor.

Test: poradi (opravdu nejnovejsi, ne jen nejakych N), prekroceni
hranice dne, a hlavne ze LAST dosahne i na den PRED cursorem.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Cursor — čtení a hledání kandidátů

Spec 3.1 a 3.4. Jádro celého plánu: `find_ready_candidates` přestane procházet celou historii a přestane forkovat `fgrep` na každý soubor.

**Files:**
- Modify: `hunter/lib/common.sh` (přidat `cursor_read`, `cursor_write`)
- Modify: `hunter/lib/mail.sh:16-27` (přepsat `find_ready_candidates`)
- Create: `tests/test_cursor.sh`

**Interfaces:**
- Consumes: `snap_num6` (Task 1), `list_snap_days` (Task 2).
- Produces: `cursor_read` → vypíše den `YYMMDD`, od kterého se má hledat; při chybějícím/poškozeném `state/cursor.txt` vrátí nejstarší den na kartě (prázdný řetězec, když `snaps/` neexistuje nebo je prázdný).
- Produces: `cursor_write <YYMMDD>` → zapíše cursor a zavolá `sync`.
- Produces: `find_ready_candidates` — signatura beze změny (cesty na stdout, řádek na soubor), **nově chronologicky vzestupně**. Na to pořadí spoléhá Task 5.

- [ ] **Step 1: Napiš padající test**

Vytvoř `tests/test_cursor.sh`:

```sh
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

fixture_teardown
finish
```

- [ ] **Step 2: Spusť test, ověř že padá**

Run: `sh tests/test_cursor.sh`
Expected: FAIL — `cursor_read: not found`

- [ ] **Step 3: Přidej cursor helpery do `common.sh`**

```sh
# cursor_read
# Vypise den (YYMMDD), od ktereho ma automatika hledat kandidaty.
#
# Chybejici, prazdny nebo poskozeny state/cursor.txt znamena "od
# nejstarsiho dne na karte" - tedy presne dnesni chovani. Diky tomu
# nepotrebuje zive nasazeni zadny rucni migracni krok (spec 2026-09-02,
# sekce 3.4).
cursor_read() {
    _cur=""
    if [ -f "$STATE_DIR/cursor.txt" ]; then
        read -r _cur < "$STATE_DIR/cursor.txt" 2>/dev/null
    fi
    snap_num6 "$_cur" || _cur=""

    if [ -z "$_cur" ]; then
        for _d in $(list_snap_days); do
            snap_num6 "$_d" || continue
            if [ -z "$_cur" ] || [ "$_d" -lt "$_cur" ]; then
                _cur="$_d"
            fi
        done
    fi
    printf '%s' "$_cur"
}

# cursor_write <YYMMDD>
cursor_write() {
    printf '%s\n' "$1" > "$STATE_DIR/cursor.txt"
    sync
}
```

- [ ] **Step 4: Přepiš `find_ready_candidates`**

V `hunter/lib/mail.sh` nahraď celou funkci (komentář nad ní o "rozdilu mnozin" uprav taky):

```sh
# find_ready_candidates
# Vypise (radek na soubor) cesty ke snimkum, ktere jeste nejsou v
# sent_list.txt a jsou kompletni.
#
# Prochazi jen dny OD CURSORU dal (spec 2026-09-02, sekce 3) - starsi
# dny jsou vyrizene a znovu se do nich nekouka. To je duvod, proc tohle
# neroste s celkovym poctem fotek na karte, ale jen s tim, co pribylo.
#
# Druha polovina zrychleni: JEDEN fgrep na den misto jednoho na soubor.
# Puvodni verze spoustela novy proces pro kazdy soubor, coz pri tisicich
# fotek delalo tisice forku na probuzeni.
#
# Vystup je chronologicky VZESTUPNY (glob nad YYMMDD i nad HHMMSS_...
# radi lexikograficky, coz je tady zaroven chronologicky). MAX_QUEUE na
# to spoleha, kdyz odrezava nejstarsi.
find_ready_candidates() {
    _cur=$(cursor_read)
    [ -n "$_cur" ] || return 0
    _nl='
'

    for _d in $(list_snap_days); do
        snap_num6 "$_d" || continue
        [ "$_d" -lt "$_cur" ] && continue

        _slice=""
        if [ -f "$STATE_DIR/sent_list.txt" ]; then
            _slice=$(fgrep "/snaps/$_d/" "$STATE_DIR/sent_list.txt" 2>/dev/null)
        fi

        for _f in "$SDCARD/snaps/$_d"/*.jpg; do
            [ -f "$_f" ] || continue
            case "$_nl$_slice$_nl" in
                *"$_nl$_f$_nl"*) continue ;;
            esac
            if "$HUNTER_DIR/bin/snapready" "$_f" >/dev/null 2>&1; then
                printf '%s\n' "$_f"
            fi
        done
    done
}
```

- [ ] **Step 5: Spusť testy**

Run: `sh tests/test_cursor.sh` → Expected: PASS
Run: `sh tests/run_tests.sh` → Expected: všechny sady zelené

- [ ] **Step 6: Ověř, že zmizel fork na soubor**

Run: `grep -n 'fgrep' hunter/lib/mail.sh`
Expected: právě jeden výskyt, a to **vně** vnitřní smyčky přes soubory.

- [ ] **Step 7: Commit**

```bash
git add hunter/lib/common.sh hunter/lib/mail.sh tests/test_cursor.sh
git commit -m "perf: cursor - automatika prestava prochazet celou historii

find_ready_candidates prochazel find-em vsechny soubory v snaps/ a pro
kazdy spoustel vlastni fgrep pres cely sent_list.txt. Pri 5000 fotkach
to bylo ~5000 forku na probuzeni, i kdyz nic nepribylo.

Ted se prochazeji jen dny od state/cursor.txt dal a na den pripada
jeden fgrep. Chybejici cursor = nejstarsi den na karte, takze zive
nasazeni nepotrebuje zadny migracni krok.

Vedlejsi dusledek: vystup je nove chronologicky vzestupny (glob misto
find) - spoleha na to MAX_QUEUE.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Cursor — posun a zapojení do `hunter.sh`

Spec 3.2 a 3.3.

**Files:**
- Modify: `hunter/lib/mail.sh` (přidat `day_fully_sent`, `cursor_advance`)
- Modify: `hunter/hunter.sh` (volat `cursor_advance` po odeslání)
- Modify: `tests/test_cursor.sh` (přidat testy posunu)

**Interfaces:**
- Consumes: `cursor_read`/`cursor_write` (Task 3), `list_snap_days`, `snap_num6`.
- Produces: `day_fully_sent <YYMMDD>` → 0 když je každý `*.jpg` toho dne v `sent_list.txt`.
- Produces: `cursor_advance` → posune cursor na nejstarší den, který ještě není celý odeslaný, nejvýš však na nejnovější existující den. Nikdy se neposouvá zpět.

- [ ] **Step 1: Napiš padající test**

Přidej do `tests/test_cursor.sh` před `fixture_teardown`:

```sh
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
```

- [ ] **Step 2: Spusť test, ověř že padá**

Run: `sh tests/test_cursor.sh`
Expected: FAIL — `cursor_advance: not found`

- [ ] **Step 3: Přidej `day_fully_sent` a `cursor_advance` do `mail.sh`**

Vlož pod `find_ready_candidates`:

```sh
# day_fully_sent <YYMMDD>
# 0, kdyz je KAZDY *.jpg toho dne v sent_list.txt.
#
# Ridi se VYHRADNE clenstvim v sent_list.txt, ne kandidaturou. Soubor,
# ktery snapready odmita (neuplny, poskozeny), tedy den drzi otevreny -
# schvalne: "neumim ho poslat" neni totez co "je vyrizeny"
# (spec 2026-09-02, 3.2 a omezeni 9.3).
day_fully_sent() {
    _d="$1"
    _nl='
'
    _slice=""
    if [ -f "$STATE_DIR/sent_list.txt" ]; then
        _slice=$(fgrep "/snaps/$_d/" "$STATE_DIR/sent_list.txt" 2>/dev/null)
    fi

    for _f in "$SDCARD/snaps/$_d"/*.jpg; do
        [ -f "$_f" ] || continue
        case "$_nl$_slice$_nl" in
            *"$_nl$_f$_nl"*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# cursor_advance
# Posune cursor na nejstarsi den, ktery jeste neni cely odeslany -
# nejvys ale na NEJNOVEJSI existujici den, ten se neuzavira nikdy.
#
# Podminka "existuje novejsi slozka dne" je zamerne strukturalni, ne
# podle hodin: hodiny zarizeni nemaji zalohovany RTC a mezi probuzenimi
# plavou (spec 2026-08-27, 2.1). Do nejnovejsi slozky se porad zapisuje,
# takze rozepsany snimek nemuze propadnout.
#
# Cursor se nikdy neposouva ZPET - jen tak ma "tenhle den je vyrizeny"
# trvalou platnost.
cursor_advance() {
    _newest=""
    for _d in $(list_snap_days); do
        snap_num6 "$_d" || continue
        if [ -z "$_newest" ] || [ "$_d" -gt "$_newest" ]; then
            _newest="$_d"
        fi
    done
    [ -n "$_newest" ] || return 0

    _open=""
    for _d in $(list_snap_days); do
        snap_num6 "$_d" || continue
        [ "$_d" -ge "$_newest" ] && continue
        day_fully_sent "$_d" && continue
        if [ -z "$_open" ] || [ "$_d" -lt "$_open" ]; then
            _open="$_d"
        fi
    done

    if [ -n "$_open" ]; then
        _new="$_open"
    else
        _new="$_newest"
    fi

    _cur=$(cursor_read)
    [ -n "$_cur" ] && [ "$_new" -le "$_cur" ] && return 0
    cursor_write "$_new"
    log "cursor posunut na $_new"
}
```

- [ ] **Step 4: Zavolej `cursor_advance` z `hunter.sh`**

V `hunter/hunter.sh` **za** blok odesílání (za `fi`, které uzavírá `if [ -n "$snap_list" ]`) přidej:

```sh
# Posun cursoru az TED, po odeslani - prave odeslane soubory se tim do
# uzavreni sveho dne zapocitaji hned. Jednou za probuzeni, ne uvnitr
# find_ready_candidates: ta se vola opakovane z pollovaci smycky
# wait_for_candidates (spec 2026-09-02, 3.3).
cursor_advance
```

- [ ] **Step 5: Spusť testy**

Run: `sh tests/test_cursor.sh` → Expected: PASS
Run: `sh tests/run_tests.sh` → Expected: všechny sady zelené, včetně `test_wake_send.sh`

- [ ] **Step 6: Commit**

```bash
git add hunter/lib/mail.sh hunter/hunter.sh tests/test_cursor.sh
git commit -m "feat: posun cursoru po odeslani

Den se uzavira, az kdyz je kazdy jeho snimek v sent_list.txt A existuje
novejsi slozka dne. Druha podminka je strukturalni, ne podle hodin -
hodiny zarizeni plavou a do nejnovejsi slozky se porad zapisuje.

Cursor se nikdy neposouva zpet ani za nejnovejsi den. Soubor, ktery
snapready odmita, drzi svuj den otevreny zamerne.

Volani je v hunter.sh az po odeslani, jednou za probuzeni.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `MAX_QUEUE` a `skip_snaps`

Spec 6 a 7.1.

**Files:**
- Modify: `hunter/lib/common.sh` (`MAX_QUEUE` default, `skip_snaps`)
- Modify: `hunter/hunter.sh` (odříznutí fronty před sloučením s vyžádanými)
- Modify: `hunter/config.txt.example` (klíč + varování k `WIPE`)
- Create: `tests/test_queue.sh` (úroveň funkcí)
- Create: `tests/test_queue_wake.sh` (skutečný běh `hunter.sh` jako podproces)

**Interfaces:**
- Consumes: `find_ready_candidates` (Task 3) a jeho **chronologicky vzestupné** pořadí.
- Produces: `skip_snaps <seznam>` → zapíše cesty do `sent_list.txt`, **vynechá** vše z `REQUESTED_SNAPS`, vypíše počet skutečně přeskočených. Konzumuje Task 6.
- Produces: konfigurační klíč `MAX_QUEUE` (výchozí `100`, `0` = bez omezení).

- [ ] **Step 1: Napiš padající test**

Vytvoř `tests/test_queue.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

fixture_snap 260828 010000
fixture_snap 260828 020000
fixture_snap 260829 030000

S1="$SDCARD/snaps/260828/010000_000_65535_P.jpg"
S2="$SDCARD/snaps/260828/020000_000_65535_P.jpg"
S3="$SDCARD/snaps/260829/030000_000_65535_P.jpg"

: > "$STATE_DIR/sent_list.txt"

# --- skip_snaps zapisuje do sent_list.txt ---
REQUESTED_SNAPS=""
n=$(skip_snaps "$S1
$S2")
assert_eq "skip_snaps hlasi pocet" "$n" "2"
assert_contains "prvni cesta je v sent_list" "$(cat "$STATE_DIR/sent_list.txt")" "010000"
assert_contains "druha cesta je v sent_list" "$(cat "$STATE_DIR/sent_list.txt")" "020000"

# --- KLICOVE: vyzadane fotky skip_snaps NESMI zapsat (spec 7.1) ---
: > "$STATE_DIR/sent_list.txt"
REQUESTED_SNAPS="$S1"
n=$(skip_snaps "$S1
$S2")
assert_eq "skip_snaps preskoci jen nevyzadane" "$n" "1"
assert_not_contains "vyzadana fotka se NEDOSTALA do sent_list" \
                    "$(cat "$STATE_DIR/sent_list.txt")" "010000"
assert_contains "nevyzadana fotka do sent_list patri" \
                "$(cat "$STATE_DIR/sent_list.txt")" "020000"

# --- vychozi hodnota MAX_QUEUE ---
assert_eq "MAX_QUEUE ma vychozi hodnotu" "$MAX_QUEUE" "100"

fixture_teardown
finish
```

- [ ] **Step 2: Spusť test, ověř že padá**

Run: `sh tests/test_queue.sh`
Expected: FAIL — `skip_snaps: not found`

- [ ] **Step 3: Přidej `MAX_QUEUE` a `skip_snaps` do `common.sh`**

Do `load_config`, za `: "${REQUEST_MAX:=5}"`:

```sh
    # Strop na velikost nedodelku. Pres nej se NEJSTARSI cekajici fotky
    # preskoci (zapisem do sent_list.txt), aby se dohaneni nenafouklo
    # donekonecna. 0 = bez omezeni.
    : "${MAX_QUEUE:=100}"
```

A jako novou funkci (vedle ostatních sdílených pomocníků):

```sh
# skip_snaps <seznam cest, radek na soubor>
# Oznaci fotky za vyrizene, aniz by se odesilaly - zapisem do
# sent_list.txt. Vypise pocet skutecne preskocenych.
#
# Vyzadane fotky (REQUESTED_SNAPS) VYNECHAVA, a to je bezpecnostne
# nosne: vyzadane se do sent_list.txt zamerne nezapisuji nikdy (viz
# hunter.sh), protoze jinak by se prvnim vyzadanim oznacily za odeslane
# a uz NIKDY by neodesly automaticky. Kdyby se tam dostaly tudy,
# obesla by se ta ochrana zadem - tise a natrvalo
# (spec 2026-09-02, invariant 7.1).
skip_snaps() {
    _cnt=0
    _nl='
'
    _old_ifs="$IFS"
    IFS="$_nl"
    for _s in $1; do
        IFS="$_old_ifs"
        [ -n "$_s" ] || { IFS="$_nl"; continue; }
        case "$_nl$REQUESTED_SNAPS$_nl" in
            *"$_nl$_s$_nl"*) IFS="$_nl"; continue ;;
        esac
        printf '%s\n' "$_s" >> "$STATE_DIR/sent_list.txt"
        _cnt=$((_cnt + 1))
        IFS="$_nl"
    done
    IFS="$_old_ifs"
    sync
    printf '%s' "$_cnt"
}
```

- [ ] **Step 4: Spusť test, ověř že prochází**

Run: `sh tests/test_queue.sh` → Expected: PASS

- [ ] **Step 5: Zapoj `MAX_QUEUE` do `hunter.sh`**

V `hunter/hunter.sh` vlož **hned za** `snap_list=$(wait_for_candidates)` a **před** blok odstraňování duplicit:

```sh
# MAX_QUEUE: nedodelek se nesmi nafouknout donekonecna. Co je pres
# strop, to se NEJSTARSI preskoci - zapisem do sent_list.txt, takze uz
# se to nenabizi. Soubory na karte zustavaji.
#
# Poradi z find_ready_candidates je chronologicky vzestupne, takze
# "nejstarsi" jsou proste prvni radky.
#
# Bezi to PRED slouchenim s REQUESTED_SNAPS a skip_snaps navic
# vyzadane sama vynechava - vyzadana fotka se timhle nesmi dostat do
# sent_list.txt (spec 2026-09-02, 7.1).
if [ -n "$snap_list" ] && [ "$MAX_QUEUE" -gt 0 ]; then
    queue_n=$(printf '%s' "$snap_list" | grep -c .)
    if [ "$queue_n" -gt "$MAX_QUEUE" ]; then
        drop=$((queue_n - MAX_QUEUE))
        to_skip=""
        keep=""
        i=0
        old_ifs="$IFS"
        IFS='
'
        for cand in $snap_list; do
            IFS="$old_ifs"
            i=$((i + 1))
            if [ "$i" -le "$drop" ]; then
                to_skip="$to_skip$cand
"
            else
                keep="$keep$cand
"
            fi
            IFS='
'
        done
        IFS="$old_ifs"
        skipped=$(skip_snaps "$to_skip")
        snap_list=$(printf '%s' "$keep")
        log "fronta pres strop ($queue_n > $MAX_QUEUE): preskoceno $skipped nejstarsich"
    fi
fi
```

- [ ] **Step 6: Přidej `MAX_QUEUE` do `config.txt.example`**

Za blok `REQUEST_MAX`:

```
# Strop na velikost nedodelku (kolik cekajicich fotek ma vubec smysl
# drzet). Co je pres strop, to se NEJSTARSI preskoci - soubory na karte
# zustanou, jen uz se nenabizeji k odeslani. 0 = bez omezeni.
#
# POZOR: preskocene fotky se zapisuji do state/sent_list.txt, takze je
# pozdejsi WIPE CONFIRM smaze, i kdyz ti nikdy nedorazily mailem.
# Vedome rozhodnuti (2026-09-02) ve prospech jednoduchosti - stejne to
# plati pro prikaz CLEAR QUEUE.
MAX_QUEUE=100
```

- [ ] **Step 7: Napiš test skutečného běhu `hunter.sh`**

Odříznutí fronty žije v **těle** `hunter.sh`, ne ve funkci — nejde ho nasourcovat. Použij proto `fixture_subprocess.sh`, který spouští izolovanou kopii `hunter.sh` jako opravdový proces (stejně jako `tests/test_wake_send.sh`).

Vytvoř `tests/test_queue_wake.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture_subprocess.sh"

# =====================================================================
# A: MAX_QUEUE odrizne NEJSTARSI a fronta se vejde pod strop
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=2\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260828 030000
subproc_mk_snap 260829 040000

subproc_run_hunter

sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)
ms=$(cat "$FIX/mailsend.log" 2>/dev/null)

assert_contains "A: log rekl, ze fronta prerostla strop" \
                "$(cat "$HDIR/log.txt")" "fronta pres strop"
assert_not_contains "A: nejstarsi se NEODESLALA" "$ms" "010000"
assert_not_contains "A: druha nejstarsi se NEODESLALA" "$ms" "020000"
assert_contains "A: novejsi se odeslala" "$ms" "030000"
assert_contains "A: nejnovejsi se odeslala" "$ms" "040000"
assert_contains "A: preskocena nejstarsi je v sent_list" "$sl" "010000"
assert_contains "A: preskocena druha je v sent_list" "$sl" "020000"
assert_eq "A: preskocene soubory zustaly na karte" \
          "$([ -f "$SDCARD/snaps/260828/010000_000_65535_P.jpg" ] && echo ano)" "ano"

subproc_fixture_teardown

# =====================================================================
# B: pod stropem se neodrezava nic
# =====================================================================
subproc_fixture_setup 3 3
printf 'MAX_QUEUE=100\n' >> "$HDIR/config.txt"

subproc_mk_snap 260828 010000
subproc_mk_snap 260829 020000

subproc_run_hunter

assert_not_contains "B: pod stropem se o odrezavani vubec nemluvi" \
                    "$(cat "$HDIR/log.txt")" "fronta pres strop"

subproc_fixture_teardown
finish
```

- [ ] **Step 8: Spusť test skutečného běhu**

Run: `sh tests/test_queue_wake.sh` → Expected: PASS
Run: `sh tests/run_tests.sh` → Expected: všechny sady zelené

- [ ] **Step 9: Commit**

```bash
git add hunter/lib/common.sh hunter/hunter.sh hunter/config.txt.example tests/test_queue.sh tests/test_queue_wake.sh
git commit -m "feat: MAX_QUEUE - strop na velikost nedodelku

Pres strop se nejstarsi cekajici fotky preskoci zapisem do
sent_list.txt; soubory na karte zustavaji. Poradi z
find_ready_candidates je chronologicke, takze nejstarsi jsou prvni.

skip_snaps zamerne VYNECHAVA REQUESTED_SNAPS: vyzadane fotky se do
sent_list.txt nezapisuji nikdy, jinak by z automatickeho odesilani
vypadly natrvalo (spec 7.1).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Příkaz `CLEAR QUEUE`

Spec 5.

**Files:**
- Modify: `hunter/lib/command.sh` (nová větev v `execute_command`, řádek v `build_cmd_listing`)
- Modify: `hunter/hunter.sh` (inicializace příznaku + vyprázdnění fronty)
- Modify: `tests/test_queue.sh` (testy příkazu)
- Modify: `tests/test_queue_wake.sh` (scénáře C a D — skutečný běh)
- Modify: `tests/test_listcmd.sh` (výpis musí příkaz obsahovat)

**Interfaces:**
- Consumes: `skip_snaps` (Task 5).
- Produces: globální příznak `CLEAR_QUEUE_REQUESTED` (`0`/`1`), který nastavuje `execute_command` a čte `hunter.sh`.

- [ ] **Step 1: Napiš padající test**

Přidej do `tests/test_queue.sh` před `fixture_teardown`:

```sh
# =====================================================================
# CLEAR QUEUE (spec 2026-09-02, sekce 5)
# =====================================================================

# --- prikaz jen nastavi priznak, sam nic nemaze ani nezapisuje ---
: > "$STATE_DIR/sent_list.txt"
CLEAR_QUEUE_REQUESTED=0
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "CLEAR QUEUE" 1
assert_eq "CLEAR QUEUE odpovida bez poctu" "$CMD_REPLY" "QUEUE CLEARED"
assert_eq "CLEAR QUEUE nastavil priznak" "$CLEAR_QUEUE_REQUESTED" "1"
assert_eq "CLEAR QUEUE sam nic nezapsal do sent_list" \
          "$(cat "$STATE_DIR/sent_list.txt")" ""
assert_eq "CLEAR QUEUE nesmazal zadny soubor" "$([ -f "$S1" ] && echo ano)" "ano"

# --- funguje i bez tokenu (nemeni opravneni, stejne jako WIPE) ---
CLEAR_QUEUE_REQUESTED=0
CMD_REPLY=""
execute_command "CLEAR QUEUE" 0
assert_eq "CLEAR QUEUE nevyzaduje token" "$CMD_REPLY" "QUEUE CLEARED"
assert_eq "a priznak nastavi i bez tokenu" "$CLEAR_QUEUE_REQUESTED" "1"

# --- malymi pismeny taky ---
CLEAR_QUEUE_REQUESTED=0
CMD_REPLY=""
execute_command "clear queue" 1
assert_eq "CLEAR QUEUE je case-insensitive" "$CMD_REPLY" "QUEUE CLEARED"
```

A do `tests/test_listcmd.sh` přidej k ostatním kontrolám výpisu:

```sh
assert_contains "LIST CMD zna CLEAR QUEUE" "$(build_cmd_listing)" "CLEAR QUEUE"
```

- [ ] **Step 2: Spusť testy, ověř že padají**

Run: `sh tests/test_queue.sh` → Expected: FAIL (`CMD_REPLY` prázdný, příkaz neexistuje)
Run: `sh tests/test_listcmd.sh` → Expected: FAIL

- [ ] **Step 3: Přidej větev do `execute_command`**

V `hunter/lib/command.sh` vlož mezi větev `CONFIRM OFF` a `WIPE`:

```sh
        [Cc][Ll][Ee][Aa][Rr]" "[Qq][Uu][Ee][Uu][Ee])
            # Jen se nastavi priznak - skutecne preskoceni dela hunter.sh
            # az po zpracovani VSECH prikazu.
            #
            # Musi to tak byt kvuli invariantu 7.1: preskakovani se nesmi
            # dotknout vyzadanych fotek, a REQUESTED_SNAPS je konecny
            # teprve, kdyz dobehnou vsechny prikazy daneho probuzeni.
            # Kdyby v jedne davce prisel CLEAR QUEUE driv nez LAST 2,
            # oznacil by fotku, kterou ma LAST teprve vyzadat - a ta by
            # z automatickeho odesilani vypadla natrvalo.
            #
            # Proto taky odpoved neobsahuje pocet: v okamziku odeslani
            # odpovedi jeste neni znam. Loguje se az pri preskoceni.
            CLEAR_QUEUE_REQUESTED=1
            CMD_REPLY='QUEUE CLEARED'
            ;;
```

- [ ] **Step 4: Přidej řádek do `build_cmd_listing`**

Za řádek s `WIPE CONFIRM`:

```sh
    printf '%s CLEAR QUEUE             preskoci cekajici fotky (nemaze)\n' "$p"
```

- [ ] **Step 5: Zapoj do `hunter.sh`**

Vedle `REQUESTED_SNAPS=""` (u inicializace proměnných) přidej:

```sh
CLEAR_QUEUE_REQUESTED=0
```

A **před** blok `MAX_QUEUE` (z Tasku 5) vlož:

```sh
# CLEAR QUEUE: uzivatel rekl, ze cekajici fotky uz posilat nechce.
# Soubory zustavaji na karte, jen se oznaci za vyrizene. Bezi to az
# tady, po zpracovani vsech prikazu, aby byl REQUESTED_SNAPS konecny -
# skip_snaps vyzadane vynechava (spec 2026-09-02, 5 a 7.1).
if [ "$CLEAR_QUEUE_REQUESTED" = 1 ] && [ -n "$snap_list" ]; then
    cleared=$(skip_snaps "$snap_list")
    log "CLEAR QUEUE: preskoceno $cleared cekajicich fotek"
    snap_list=""
fi
```

- [ ] **Step 6: Napiš test skutečného běhu — včetně klíčového invariantu**

Přidej do `tests/test_queue_wake.sh` před `finish`:

```sh
# =====================================================================
# C: CLEAR QUEUE mailem - nic se neodesle, nic se nesmaze
# =====================================================================
subproc_fixture_setup 3 3

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260829 030000

printf 'UIDVALIDITY|1\nMSG|10|paja.stindl@seznam.cz|HUNTER tajnytoken1 CLEAR QUEUE\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

ms=$(cat "$FIX/mailsend.log" 2>/dev/null)
sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)

# odpoved na prikaz se posila (bez prilohy), fotky NE (ty maji --attach)
assert_eq "C: neodesla se ani jedna fotka" \
          "$(printf '%s\n' "$ms" | grep -c -- '--attach')" "0"
assert_contains "C: log rekl kolik preskocil" \
                "$(cat "$HDIR/log.txt")" "CLEAR QUEUE: preskoceno 3"
assert_contains "C: vsechny tri jsou v sent_list" "$sl" "010000"
assert_contains "C: vsechny tri jsou v sent_list (2)" "$sl" "020000"
assert_contains "C: vsechny tri jsou v sent_list (3)" "$sl" "030000"
assert_eq "C: soubory zustaly na karte" \
          "$([ -f "$SDCARD/snaps/260829/030000_000_65535_P.jpg" ] && echo ano)" "ano"

subproc_fixture_teardown

# =====================================================================
# D: INVARIANT 7.1 - CLEAR QUEUE prijde v davce DRIV nez LAST, a presto
# se vyzadana fotka musi odeslat a NESMI skoncit v sent_list.txt.
#
# Tohle je duvod, proc CLEAR QUEUE jen nastavuje priznak misto aby
# preskakoval hned. Kdyby preskakoval hned, oznacil by fotku, kterou ma
# LAST teprve vyzadat - a ta by z automatickeho odesilani vypadla
# NATRVALO, tise a bez stopy v logu.
# =====================================================================
subproc_fixture_setup 3 3

subproc_mk_snap 260828 010000
subproc_mk_snap 260828 020000
subproc_mk_snap 260829 030000

printf 'UIDVALIDITY|1\nMSG|10|paja.stindl@seznam.cz|HUNTER tajnytoken1 CLEAR QUEUE\nMSG|11|paja.stindl@seznam.cz|HUNTER tajnytoken1 LAST 1\n' \
    > "$FIX/mail_listing.txt"

subproc_run_hunter

ms=$(cat "$FIX/mailsend.log" 2>/dev/null)
sl=$(cat "$HDIR/state/sent_list.txt" 2>/dev/null)

assert_contains "D: vyzadana fotka se PRESTO odeslala" "$ms" "030000"
assert_not_contains "D: a NENI v sent_list (jinak by z automatiky vypadla navzdy)" \
                    "$sl" "030000"
assert_contains "D: nevyzadane preskocene v sent_list jsou" "$sl" "010000"
assert_contains "D: nevyzadane preskocene v sent_list jsou (2)" "$sl" "020000"

subproc_fixture_teardown
```

- [ ] **Step 7: Spusť testy**

Run: `sh tests/test_queue.sh` → Expected: PASS
Run: `sh tests/test_queue_wake.sh` → Expected: PASS včetně scénáře D
Run: `sh tests/test_listcmd.sh` → Expected: PASS
Run: `sh tests/run_tests.sh` → Expected: všechny sady zelené

- [ ] **Step 8: Mutačně ověř scénář D**

Test D je jediná pojistka proti tiché trvalé ztrátě fotky — ověř, že opravdu chytá, ne že jen prochází. V `hunter/lib/common.sh` **dočasně** odstraň ze `skip_snaps` větev vynechávající `REQUESTED_SNAPS`:

```sh
        case "$_nl$REQUESTED_SNAPS$_nl" in
            *"$_nl$_s$_nl"*) IFS="$_nl"; continue ;;
        esac
```

Run: `sh tests/test_queue_wake.sh`
Expected: **FAIL** na `D: a NENI v sent_list`. Pak změnu vrať zpět a spusť znovu — musí projít. Obojí zapiš do reportu.

- [ ] **Step 9: Commit**

```bash
git add hunter/lib/command.sh hunter/hunter.sh tests/test_queue.sh tests/test_queue_wake.sh tests/test_listcmd.sh
git commit -m "feat: prikaz CLEAR QUEUE

Oznaci cekajici fotky za vyrizene, aniz by je odeslal; soubory na karte
zustavaji. Token nevyzaduje (nemeni opravneni, stejne jako WIPE).

Prikaz sam jen nastavi priznak - preskoceni dela hunter.sh az po
zpracovani vsech prikazu, aby byl REQUESTED_SNAPS konecny. Jinak by
CLEAR QUEUE prichozi v davce driv nez LAST oznacil fotku, kterou ma
LAST teprve vyzadat. Proto odpoved neobsahuje pocet - loguje se.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: `STATUS` hlásí hloubku fronty

Spec 10.

**Files:**
- Modify: `hunter/lib/status.sh:172-177` (`build_status_reply`)
- Modify: `tests/test_command.sh` (assert na `FRONTA:`)

**Interfaces:**
- Consumes: `find_ready_candidates` (Task 3).

- [ ] **Step 1: Napiš padající test**

Do `tests/test_command.sh` přidej před `fixture_teardown`:

```sh
# --- STATUS hlasi hloubku fronty (spec 2026-09-02, sekce 10) ---
: > "$STATE_DIR/sent_list.txt"
rm -f "$STATE_DIR/cursor.txt"
fixture_snap 260828 111111
fixture_snap 260828 222222
CMD_REPLY=""
execute_command "STATUS" 1
assert_contains "STATUS hlasi frontu" "$CMD_REPLY" "FRONTA:"

# a cislo odpovida skutecnemu poctu kandidatu
q=$(find_ready_candidates | grep -c .)
assert_contains "STATUS hlasi spravny pocet" "$CMD_REPLY" "FRONTA:$q"
```

- [ ] **Step 2: Spusť test, ověř že padá**

Run: `sh tests/test_command.sh`
Expected: FAIL — v odpovědi `FRONTA:` není

- [ ] **Step 3: Rozšiř `build_status_reply`**

V `hunter/lib/status.sh`:

```sh
# build_status_reply
# Kompaktni jednoradkova varianta pro odpoved na STATUS.
#
# FRONTA je pocet cekajicich kandidatu po uplatneni cursoru - presne to
# cislo, podle ktereho se uzivatel rozhoduje, jestli poslat CLEAR QUEUE
# (spec 2026-09-02, sekce 10).
build_status_reply() {
    bat=$(get_battery_percent)
    sig=$(get_signal_percent)
    spc=$(get_space_gb)
    queue=$(find_ready_candidates | grep -c .)
    printf 'BAT:%s SIG:%s SPACE:%s FRONTA:%s' "$bat" "$sig" "$spc" "$queue"
}
```

- [ ] **Step 4: Spusť testy**

Run: `sh tests/test_command.sh` → Expected: PASS
Run: `sh tests/run_tests.sh` → Expected: všechny sady zelené

- [ ] **Step 5: Commit**

```bash
git add hunter/lib/status.sh tests/test_command.sh
git commit -m "feat: STATUS hlasi hloubku fronty

FRONTA:<N> je pocet cekajicich kandidatu po uplatneni cursoru - presne
to cislo, podle ktereho se uzivatel rozhoduje, jestli ma smysl poslat
CLEAR QUEUE.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Dokumentace a nasazení

**Files:**
- Modify: `hunter/README.md`
- Modify: `CHECKLIST.md`
- Modify: `docs/superpowers/specs/2026-08-27-hunter-design.md` (ukazatel u detekce kandidátů)

- [ ] **Step 1: `hunter/README.md` — strom karty**

Do diagramu SD karty přidej `cursor.txt` vedle ostatních stavových souborů a doplň jednořádkový popis:

```
    └── state/             ← sent_list.txt, mail_seen.txt, sms_seen.txt,
                              cursor.txt (posledni vyrizeny den)
```

- [ ] **Step 2: `hunter/README.md` — tabulka příkazů**

Za řádek `WIPE CONFIRM` přidej:

```
HUNTER <token> CLEAR QUEUE             preskoci cekajici fotky (nemaze)
```

A do textu pod tabulkou přidej odstavec:

```markdown
**Fronta.** `STATUS` hlásí `FRONTA:<N>` — kolik fotek čeká na odeslání.
Když je nedodělek zbytečně velký, `CLEAR QUEUE` ho vyprázdní: fotky
zůstanou na kartě, jen se přestanou nabízet. Totéž dělá automaticky
`MAX_QUEUE` v configu, když fronta přeroste strop (přeskočí nejstarší).

**Pozor:** přeskočené fotky se zapisují do `state/sent_list.txt`, takže
je pozdější `WIPE CONFIRM` smaže, i když ti nikdy nedorazily mailem.
```

- [ ] **Step 3: `hunter/README.md` — sekce o ověření**

Do „Ověřeno pod `dash`/`qemu`" přidej větu:

```markdown
Škálování na tisíce fotek je řešené cursorem (`state/cursor.txt`) —
automatická větev prochází jen dny od posledního vyřízeného dál, ne
celou historii. Detaily a měření v
[2026-09-02-hunter-queue-cursor-design.md](../docs/superpowers/specs/2026-09-02-hunter-queue-cursor-design.md).
```

- [ ] **Step 4: `CHECKLIST.md` — nová fáze**

Za Fázi 8 přidej Fázi 9, opět jako **aktualizaci běžícího nasazení**:

```markdown
## Fáze 9 — aktualizace: fronta a cursor (2026-09-02)

- [ ] `sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600` — **a pak pracovat
      svižně**. Historie z fáze 8: držet `ubia_first` mrtvý přes hodinu
      skončilo restart smyčkou vyvolanou MCU watchdogem.
- [ ] Vytáhnout kartu a **fyzicky přes čtečku** zkopírovat:
  - `hunter/lib/common.sh`, `hunter/lib/command.sh`, `hunter/lib/mail.sh`,
    `hunter/lib/status.sh`, `hunter/hunter.sh`
- [ ] **Při té příležitosti dodělat dva resty z fáze 8** (ať se karta
      netahá zbytečně podruhé):
  - zkopírovat `hunter/bin/mailrecv` a `hunter/bin/mailsend` (obsahují
    opravu progname a novou podporu `--ca`)
  - smazat `hunter/spike_move_test/` a oba snímky z něj vrátit zpět:
    `121101_000_65535_NH.jpg` → `HDPIC/260831/`,
    `210948_000_65535_PH.jpg` → `HDPIC/260828/`
- [ ] Doplnit do `hunter/config.txt` klíč `MAX_QUEUE=100`.
- [ ] `cursor.txt` **nevytvářet** — chybějící soubor znamená „začni od
      nejstaršího dne", což je přesně dosavadní chování. Vytvoří se sám.
- [ ] Kartu vrátit, `md5sum` porovnat proti build stroji (`sh -n`
      nestačí).
- [ ] Ruční běh: `sh /tmp/mnt/sdcard/hunter/hunter.sh`, pak v logu čekáš
      `cursor posunut na <den>` (pokud je co uzavřít) a
      `cat /tmp/mnt/sdcard/hunter/state/cursor.txt` musí dávat platný
      `YYMMDD`.
- [ ] Ostrý test: pošli `HUNTER <token> STATUS` → odpověď musí mít
      `FRONTA:<N>`. Pak `HUNTER <token> LAST 2` → dvě fotky dorazí i
      poté, co cursor nějaký den uzavřel.
- [ ] `sh /tmp/mnt/sdcard/hunter/dev-resume.sh` (reboot), sledovat pár
      přirozených probuzení.
```

- [ ] **Step 5: Ukazatel ve starém specu**

V `docs/superpowers/specs/2026-08-27-hunter-design.md` k popisu detekce kandidátů (rozdíl množin `snaps/` minus `sent_list.txt`) přidej blockquote:

```markdown
> **Aktualizace 2026-09-02:** detekce se od té doby omezuje cursorem —
> prochází jen dny od posledního vyřízeného dál, ne celou historii. Viz
> [2026-09-02-hunter-queue-cursor-design.md](2026-09-02-hunter-queue-cursor-design.md).
```

- [ ] **Step 6: Ověř, že v device souborech nezůstala diakritika ani tab**

```bash
grep -rn -P '[^\x00-\x7F]' hunter/hunter.sh hunter/lib/*.sh ; echo "diakritika: $?"
grep -rn -P '\t' hunter/hunter.sh hunter/lib/*.sh ; echo "taby: $?"
grep -rn -P '\r' hunter/hunter.sh hunter/lib/*.sh ; echo "CR: $?"
```

Expected: všechny tři bez výpisu (exit 1 = nic nenalezeno).

- [ ] **Step 7: Poslední běh celé sady**

Run: `sh tests/run_tests.sh`
Expected: všechny sady zelené

- [ ] **Step 8: Commit**

```bash
git add hunter/README.md CHECKLIST.md docs/
git commit -m "docs: fronta a cursor - README, CHECKLIST faze 9

Faze 9 je zamerne psana jako aktualizace beziciho nasazeni a sbira i
dva resty z faze 8 (resync binarek s --ca, uklid spike_move_test),
aby se karta netahala dvakrat.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
