# Hunter — nasazení a provoz

Implementace podle [docs/superpowers/specs/2026-08-27-hunter-design.md](../docs/superpowers/specs/2026-08-27-hunter-design.md).
Přečti si tam sekci 11 (otevřené body) — dvě věci se dají ověřit jen na
zařízení a než se to stane, kód se k nim chová konzervativně.

## Co kam patří na SD kartě

```
<SD karta>/
├── ubia_test              ← z ../sdcard-root/ubia_test, KOŘEN karty
└── hunter/                ← celá tato složka
    ├── hunter.sh
    ├── lib/
    ├── bin/
    ├── config.txt          ← zkopíruj a uprav z config.txt.example
    ├── smtp.pass           ← vytvoř ručně, viz níže
    └── state/
```

`ubia_test` musí zůstat v **kořeni karty** — ta cesta je napevno
zapsaná v binárce `ubia_first`, nejde ji přesunout.

## Postup nasazení

1. **Zastav původní aplikaci**, ať je klid na práci — viz
   [dev-stop.sh](dev-stop.sh):
   ```sh
   sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600
   ```
2. Zkopíruj na kartu:
   - obsah **této složky** (`hunter/`) do `<SD>/hunter/`
   - [../sdcard-root/ubia_test](../sdcard-root/ubia_test) do `<SD>/ubia_test`
3. Na kartě vytvoř `hunter/config.txt` podle
   [config.txt.example](config.txt.example) a uprav `MASTERS`, `SMTP_*`,
   `AT_PORT`.
4. Vytvoř heslo SMTP (nikdy do config.txt, kvůli `ps`):
   ```sh
   echo 'aplikacni-heslo' > /tmp/mnt/sdcard/hunter/smtp.pass
   ```
5. **Ověř AT port** (viz spec sekce 11, bod 1 — `ttyUSB2` je hypotéza,
   ne jistota):
   ```sh
   /tmp/mnt/sdcard/hunter/bin/atcmd /dev/ttyUSB2 115200 AT
   ```
   Musí vrátit `OK`. Jinak zkus `ttyUSB0`/`ttyUSB1`/`ttyUSB3` a uprav
   `AT_PORT` v configu.
6. Ruční zkušební běh, než se svěří `ubia_test`:
   ```sh
   sh /tmp/mnt/sdcard/hunter/hunter.sh
   cat /tmp/mnt/sdcard/hunter/log.txt
   ```
7. `sh /tmp/mnt/sdcard/hunter/dev-resume.sh` — reboot, `ubia_test` se
   od teď spouští automaticky při každém probuzení.

## Co je hotové a jak je to ověřené

Všechny čtyři C nástroje (`atcmd`, `smssend`, `smsrecv`, `mailsend`) i
dva nové (`snapready`, `logscan`) jsou přeložené pro cíl (MIPS32r2,
`-mfp32` shodné s `ubia_first`) a otestované pod `qemu-mipsel-static`
proti reálným hraničním případům — viz [../test_files/README.md](../test_files/README.md).

Shellová vrstva (`hunter.sh`, `lib/*.sh`) je napsaná pod tvrdým
omezením: **busybox na zařízení nemá `awk`, `sed`, `cut`, `sort`,
`uniq`, `wc`, `head`, `tail`, `expr`, `tee` ani `bc`** — ověřeno přímo
v binárce ze `dump/bin/busybox`, ne jen podle symlinků. Všechna field
extraction jde přes POSIX parametrickou expanzi (`${var#...}`/`${var%...}`)
a `case`, ne přes tyhle nástroje.

Otestováno end-to-end pod `dash` (POSIX shell velmi blízký busybox
`ash`) na Pi, se skutečnými binárkami běžícími pod `qemu-mipsel-static`:

- **`find_ready_candidates`** správně rozliší kompletní JPEG (končící
  `FF D9`) od rozepsaného.
- **`get_battery_percent`** správně vytáhne poslední `_battery=NN` ze
  simulovaného `logfile.txt`; `get_space_gb` sedí matematicky na `df -k`
  skutečného disku.
- **`execute_sms_command`** — všech devět příkazů (`STATUS`, `FOTO`,
  `QUALITY HD/LOW`, `CONFIRM ON/OFF`, `ADD` platné/neplatné číslo,
  `WIPE`, neznámý příkaz) dává správnou odpověď a správně mění
  `config.txt`.
- **`process_sms`** end-to-end: autorizovaná SMS dostane odpověď,
  neautorizovaná (číslo mimo `MASTERS`) se tiše smaže bez odpovědi a
  bez vykonání (`WIPE` od cizího čísla soubor nesmazal); opakovaný běh
  se stejnými SMS (simulace výpadku napájení mezi vykonáním a smazáním
  na modemu) je idempotentní — nic se nevykoná podruhé.
- **`wipe_sent_snaps`** smaže jen soubory, které skutečně existují a
  jsou v `sent_list.txt`; po smazání se seznam přepíše bez mrtvých
  záznamů.
- **Celý `hunter.sh`** proti falešnému `ubia_first` (skutečná binárka,
  ne skript — `pidof` bez `-x` najde jen binárky, což na zařízení
  odpovídá realitě). Heartbeat čítač uvnitř fake procesu **prokazatelně
  zamrzl na dobu přesně odpovídající `SIGSTOP`–`SIGCONT` oknu** a po
  `SIGCONT` pokračoval stejným tempem dál. Po doběhnutí `hunter.sh`:
  proces žije (stav `S`, ne `T`), `sent_list.txt` má záznam,
  `/tmp/stopWdg` i zámek jsou uklizené.

**Jedna reálná chyba nalezená a opravená při testování:**
`reply=$(execute_sms_command "$body")` spouštělo funkci v subshellu
(klasická past `$(...)` v POSIX shellu) — změny `MASTERS`/`QUALITY`/
`CONFIRM` uvnitř by se ztratily za hranicí funkce. Opraveno přes
globální `SMS_REPLY` a přímé volání bez `$()` (viz `lib/sms.sh`).

**Jedno riziko odstraněné návrhem, ne opravou:** `tr '[:lower:]' '[:upper:]'`
by potřeboval `FEATURE_TR_CLASSES`, což je v busyboxu volitelný
compile-time přepínač bez jistoty přítomnosti na tomhle okleštěném
buildu. Nahrazeno case-insensitivními `case` patterny
(`[Ss][Tt][Aa][Tt][Uu][Ss]`), které žádnou takovou závislost nemají.

## Co NENÍ ověřené (viz spec sekce 11)

Tohle nejde ověřit mimo zařízení a kód se k tomu chová konzervativně,
dokud se to neprověří:

1. **Který `/dev/ttyUSB*` je AT port** — `ttyUSB2` je hypotéza.
2. **Jestli `AT+CSQ` na reálném modulu funguje** stejně, jak předpokládá
   `get_signal_percent`.
3. **Jestli SMS umí probudit spící zařízení** — bez toho SMS čekají na
   přirozené probuzení (fallback, spec 7.5).
4. **Jestli `logfile.txt` opravdu obsahuje `_battery=`** — `logscan` je
   hotový a otestovaný, ale zdroj dat je nepotvrzený.
5. **Jestli `SIGSTOP`+`stopWdg` skutečně oddálí vypnutí na reálném HW.**
   Mechanismus signálů je teď prokazatelně funkční (viz test výše) —
   neznámá zůstává jen reakce MCU/watchdogu na zařízení samotném.
   **Nejrizikovější bod celého návrhu.**
6. **Jak `ubia_first` snese zmizení souborů, na které odkazuje
   `ubia_record.db`** — `WIPE` proto zatím maže jen odeslané.
7. **Jestli `stat -c %s` a `grep -F/-x/-q` v cílovém busyboxu fungují
   tak, jak předpokládá kód.** Applet `stat`/`grep`/`fgrep`/`egrep` jsou
   v binárce potvrzené, ale úplný rozsah přepínačů se nedal ověřit
   spuštěním (viz níže) — jsou to ale fundamentální vlastnosti dané
   applety, ne volitelné rozšíření jako `tr` třídy, takže riziko je nízké.

Bod 7 vznikl z pokusu spustit skutečnou `dump/bin/busybox` pod
`qemu-mipsel-static` — binárka je dynamicky slinkovaná proti uClibc a
loader spadl na nekompatibilním formátu `ld.so.cache` (viz historie
konverzace). Cesta ven (build vlastního uClibc cache nebo statický
busybox) by stála víc času, než jaký by ušetřila oproti prostému
ověření na startu prvního ostrého běhu.

## Provoz

| Situace | Co udělat |
|---|---|
| Chceš vidět, co se děje | `cat /tmp/mnt/sdcard/hunter/log.txt` |
| SMS nechodí | `hunter/bin/smsrecv $AT_PORT $AT_BAUD storage` — zkontroluj úložiště modemu |
| `WIPE` neuvolnil místo | zkontroluj, že mazané soubory už byly v `state/sent_list.txt` |
| Podezření na zaseklý běh | `RUN_DEADLINE` v configu je tvrdý strop (výchozí 180 s) |
| Chceš se vrátit k testování bez Huntera | `sh hunter/dev-stop.sh 600` (viz [dev-stop.sh](dev-stop.sh)) |
