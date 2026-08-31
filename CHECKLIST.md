# Checklist — nasazení a test Huntera přes UART

Přístup je přes sériovou konzoli (piny na desce → Raspberry Pi →
`pi-tools/uartlog`, náhrada za minicom s automatickým časovým
razítkem). Telnet se nepoužívá.

Odškrtávej postupně, nepřeskakuj. Kroky 5 a 6 jsou nevratné/rizikové —
tam je u každého napsáno, co dělat, když to nedopadne.

---

## Hned teď — pozorování baseline stability

Než začneš cokoli nasazovat, spusť logger a nech ho běžet, zatímco
chodíš kolem fotopasti. Uvidíš přesně, kdy a jak často se zařízení
budí, jak dlouho boot trvá, a jestli je to stabilní i bez Huntera.

```sh
# na Raspberry Pi:
cd ~/fotopast/test_files       # nebo kam sis uartlog.c zkopíroval
gcc -O2 -o uartlog uartlog.c   # jen poprvé, pak uz binarka existuje
./uartlog                      # /dev/serial0, 115200, loguje do ~/uart-<datum>.log
```

Nech to běžet, hýbej se před čočkou, sleduj `[T+…]` razítka. `Ctrl-C`
ukončí a bezpečně uzavře log. Log si pak můžeš v klidu projít:
```sh
less ~/uart-*.log
```

Tohle samo o sobě nic nemění na zařízení — je to jen pasivní odposlech
konzole. Klidně to nech běžet na pozadí i během zbytku checklistu:
```sh
nohup ./uartlog /dev/serial0 115200 ~/baseline.log > /dev/null 2>&1 &
```
(Na pozadí bez terminálu se automaticky přepne do režimu jen-logování,
nic neposílá na UART.)

---

## Fáze 0 — záloha (jednou)

- [ ] Kartu vyndat, na PC zkopírovat **mimo kartu**: `ubia_record.db`,
      `ubia_record.dup`.

## Fáze 1 — soubory na kartu

- [ ] Zkopírovat obsah [hunter/](hunter/) do `<SD>/hunter/`.
- [ ] Zkopírovat [sdcard-root/ubia_test](sdcard-root/ubia_test) do
      `<SD>/ubia_test` (**kořen** karty, ne do `hunter/`).
- [ ] `cp hunter/config.txt.example hunter/config.txt` na kartě, upravit
      `MASTERS`, `SMTP_USER`, `SMTP_TO`.
- [ ] Vytvořit `hunter/smtp.pass` s aplikačním heslem.
- [ ] Kartu vrátit, zapnout, připojit `uartlog`.

## Fáze 2 — klid na práci

- [ ] `sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600`
- [ ] Pokud ještě NEBYLO ověřeno dřív (jednorázově, viz
      [hunter/dev-stop.sh](hunter/dev-stop.sh)): `touch /tmp/stopWdg`
      samostatně a počkat ~5× timeout watchdogu, ověřit že se zařízení
      samo neresetuje. Bez tohohle ověření nepokračuj dál.

## Fáze 3 — najít AT port

- [ ] `hunter/bin/atcmd /dev/ttyUSB2 115200 AT` → čekáš `OK`. Když ne,
      zkusit `ttyUSB0`/`ttyUSB1`/`ttyUSB3`.
- [ ] Nalezený port zapsat do `AT_PORT` v `config.txt` na kartě.
- [ ] `atcmd $AT_PORT 115200 "AT+CSQ"` a `"AT+CPIN?"` — obojí by mělo
      vrátit smysluplnou odpověď, ne timeout.

## Fáze 4 — ruční běh bez fotky

- [ ] Zkontrolovat, že `snaps/` neobsahuje nic nového (jinak dočasně
      přejmenovat poslední den pryč).
- [ ] `sh /tmp/mnt/sdcard/hunter/hunter.sh`
- [ ] `cat /tmp/mnt/sdcard/hunter/log.txt` → čekáš `hunter start` →
      `nic k odeslani` → `hunter konec`, žádné SIGSTOP zprávy.

## Fáze 5 — SMS bez rizika

- [ ] Poslat SMS `STATUS` z čísla v `MASTERS`.
- [ ] `sh hunter/hunter.sh` znovu, zkontrolovat log i telefon —
      odpověď musí dorazit.
- [ ] Volitelně vyzkoušet `ADD`, `QUALITY HD/LOW`, `CONFIRM ON/OFF` a
      ověřit v `config.txt`, že se zapsaly.

## Fáze 6 — první ostrý test s fotkou ⚠️ nejrizikovější krok

- [ ] Vrátit zpět přejmenovanou složku / počkat na skutečný pohyb.
- [ ] **Mít po ruce fyzický vypínač/baterku** — pro případ, že by se
      `ubia_first` po `SIGCONT` nerozeběhl nebo watchdog přesto
      resetoval.
- [ ] `sh hunter/hunter.sh`
- [ ] V logu čekáš `ubia_first (pid …) zmrazen` → `odeslano: …` →
      `ubia_first pokracuje`.
- [ ] Hned potom `ps | grep ubia_first` → stav musí být `S`, ne `T`.
- [ ] Zkontrolovat e-mail — fotka s přílohou a správným tělem dorazila.
- [ ] **Když se něco pokazí:** fyzicky odpojit napájení. Nic z tohohle
      postupu nesahá do flash paměti, po restartu je zařízení
      v původním stavu (jen `stopWdg` v `/tmp` zmizí samo).

## Fáze 7 — pustit natrvalo

- [ ] `sh /tmp/mnt/sdcard/hunter/dev-resume.sh` (reboot).
- [ ] Sledovat `uartlog` přes několik dalších přirozených probuzení —
      `ubia_test` se teď spouští sám.
- [ ] `cat log.txt` po každém probuzení — chceš vidět opakovanou
      spolehlivost, ne jen jeden úspěch.

## Prvních pár dní sledovat

- [ ] Žádné neočekávané restarty (smyčka resetů = watchdog problém).
- [ ] Fotky chodí e-mailem v rozumném čase po pohybu.
- [ ] `log.txt` se rotuje (limit 1 MB), neroste bez konce.
- [ ] `state/sent_list.txt` a `state/sms_seen.txt` nerostou nesmyslně
      rychle (indikátor, že se něco opakovaně vykonává znovu).

---

## Otevřené otázky, které tenhle checklist NEřeší

Viz [docs/superpowers/specs/2026-08-27-hunter-design.md](docs/superpowers/specs/2026-08-27-hunter-design.md#11-otevřené-body--ověřit-na-zařízení),
sekce 11 — zejména bod 3 (probuzení přes SMS) je samostatný test, ne
součást téhle checklisty; dá se dělat souběžně, kdykoli po fázi 7.
