# Hunter — nasazení a provoz

Implementace podle [docs/superpowers/specs/2026-08-27-hunter-design.md](../docs/superpowers/specs/2026-08-27-hunter-design.md)
(základ: e-mail fotek, stav, správa místa) a
[docs/superpowers/specs/2026-08-31-hunter-mail-commands-design.md](../docs/superpowers/specs/2026-08-31-hunter-mail-commands-design.md)
(příkazový kanál přes e-mail — nahrazuje SMS, které na tomto modemu
nefungují). Sekce 11 prvního specu shrnuje, co bylo potřeba ověřit
přímo na zařízení — k 2026-09-01 je vyřešená většina bodů.

## Co kam patří na SD kartě

```
<SD karta>/
├── ubia_test              ← z ../sdcard-root/ubia_test, KOŘEN karty
└── hunter/                ← celá tato složka
    ├── hunter.sh
    ├── lib/
    ├── bin/                ← atcmd, smssend, smsrecv, mailsend, mailrecv,
    │                          snapready, logscan
    ├── config.txt          ← zkopíruj a uprav z config.txt.example
    ├── smtp.pass           ← vytvoř ručně, viz níže
    ├── mail.token           ← vytvoř ručně, viz níže (příkazový kanál)
    └── state/             ← sent_list.txt, mail_seen.txt, sms_seen.txt,
                              cursor.txt (posledni vyrizeny den)
```

`ubia_test` musí zůstat v **kořeni karty** — ta cesta je napevno
zapsaná v binárce `ubia_first`, nejde ji přesunout.

## Postup nasazení (od nuly)

1. **Zastav původní aplikaci**, ať je klid na práci — viz
   [dev-stop.sh](dev-stop.sh):
   ```sh
   sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600
   ```
2. Zkopíruj na kartu (**fyzicky přes čtečku**, ne přes UART — binárky
   jsou moc velké a přenos textových souborů přes UART heredoc ztrácí
   tabulátory, viz [../pi-tools/README.md](../pi-tools/README.md)):
   - obsah **této složky** (`hunter/`) do `<SD>/hunter/`
   - [../sdcard-root/ubia_test](../sdcard-root/ubia_test) do `<SD>/ubia_test`
3. Na kartě vytvoř `hunter/config.txt` podle
   [config.txt.example](config.txt.example) a uprav `MASTERS`,
   `MAIL_MASTERS`, `SMTP_*`, `IMAP_HOST`, `AT_PORT`.
4. Vytvoř heslo SMTP/IMAP (nikdy do config.txt, kvůli `ps`) — je to
   stejné aplikační heslo pro oba protokoly:
   ```sh
   echo 'aplikacni-heslo' > /tmp/mnt/sdcard/hunter/smtp.pass
   ```
5. Vytvoř aspoň jeden token pro e-mailové příkazy (jeden na řádek,
   aspoň 8 znaků, bez mezer):
   ```sh
   echo 'muj-tajny-token-min-8-znaku' > /tmp/mnt/sdcard/hunter/mail.token
   ```
6. **Ověř AT port** — na tomhle konkrétním kusu hardwaru je to
   `/dev/ttyUSB2` (ověřeno, viz níže), ale při výměně modulu/desky to
   znovu ověř:
   ```sh
   /tmp/mnt/sdcard/hunter/bin/atcmd /dev/ttyUSB2 115200 AT
   ```
   Musí vrátit `OK`.
7. Ruční zkušební běh, než se svěří `ubia_test`:
   ```sh
   sh /tmp/mnt/sdcard/hunter/hunter.sh
   cat /tmp/mnt/sdcard/hunter/log.txt
   ```
8. `sh /tmp/mnt/sdcard/hunter/dev-resume.sh` — reboot, `ubia_test` se
   od teď spouští automaticky při každém probuzení.

Podrobný krokovaný postup (vč. aktualizace existujícího nasazení o
e-mailové příkazy) je v [../CHECKLIST.md](../CHECKLIST.md).

## E-mailové příkazy

Příkazový kanál přes e-mail — nahrazuje SMS, které na tomto modemu
(SIMCom A7670E-MNXY) nejdou vůbec (`AT+CLAC` ukázal, že SMS příkazy
nejsou ve firmwaru, ne že by šlo o SIM kartu). Hunter při každém
probuzení zkontroluje IMAP schránku (stejný účet jako pro odesílání) a
vykoná, co v ní najde.

**Tvar předmětu:** `HUNTER <token> <příkaz> [argumenty]`

```
HUNTER <token> STATUS                  stav: baterie/signal/misto
HUNTER <token> LAST <N>                N nejnovejsich fotek
HUNTER <token> DATE <YYMMDD>           fotky z daneho dne
HUNTER <token> GET <jmeno>             konkretni soubor
HUNTER <token> QUALITY HD|LOW          kvalita odesilanych fotek
HUNTER <token> CONFIRM ON|OFF          potvrzovaci odpovedi
HUNTER <token> WIPE CONFIRM            smaze jiz odeslane fotky
HUNTER <token> CLEAR QUEUE             preskoci cekajici fotky (nemaze)
HUNTER <token> LIST CMD                vypis prikazu (dle aktualniho rezimu)
HUNTER <token> ADD <tel|mail>          pridat opravneneho    [vzdy token]
HUNTER <token> REMOVE <tel|mail>       odebrat opravneneho   [vzdy token]
HUNTER <token> ADD TOKEN <novy>        pridat token           [vzdy token]
HUNTER <token> REMOVE TOKEN <token>    odebrat token          [vzdy token]
HUNTER <token> AUTH TYPE TOKEN|SENDER  zmena rezimu           [vzdy token]
HUNTER <token> FOTO                    nepodporovano
```

Pošli `HUNTER <token> LIST CMD` pro aktuální výpis (mění se podle
`AUTH_TYPE`).

**Fronta.** `STATUS` hlásí `FRONTA:<N>` — kolik fotek čeká na odeslání.
Když je nedodělek zbytečně velký, `CLEAR QUEUE` ho vyprázdní: fotky
zůstanou na kartě, jen se přestanou nabízet. Totéž dělá automaticky
`MAX_QUEUE` v configu, když fronta přeroste strop (přeskočí nejstarší).

**Pozor:** přeskočené fotky se zapisují do `state/sent_list.txt`, takže
je pozdější `WIPE CONFIRM` smaže, i když ti nikdy nedorazily mailem.

**Autorizace:** výchozí `AUTH_TYPE=TOKEN` vyžaduje platný token i
odesílatele v `MAIL_MASTERS`. `AUTH_TYPE=SENDER` stačí jen odesílatel
— ale hlavička `From` jde podvrhnout, takže i v tomhle režimu příkazy
měnící oprávnění (`AUTH TYPE`, `ADD`/`REMOVE`, `ADD TOKEN`/`REMOVE TOKEN`)
vyžadují token vždy. Token se **nikde** nevypisuje ani neloguje.
Zpráva bez prefixu `HUNTER ` se vůbec nedotkne (necituje se ani
neoznačí přečtenou) — Hunter čte tutéž schránku, ze které odesílá, a
nesmí sahat na cizí poštu.

Zdrojáky: `bin/mailrecv` (IMAP klient), `lib/command.sh` (vykonavač,
sdílený s mrtvou SMS větví), `lib/mailcmd.sh` (transport). Plný spec a
implementační plán viz odkazy nahoře.

## Co je hotové a jak je to ověřené

### Ověřeno přímo na reálném zařízení (ne jen v simulaci)

- **`SIGSTOP`+`stopWdg` skutečně oddaluje vypnutí** — bývalo to
  nejrizikovější bod celého návrhu. `log.txt` z ostrého provozu má
  přes 10 cyklů `ubia_first (pid …) zmrazen` → `pokracuje`, bez
  jediného watchdog resetu mezi nimi.
- **E-mailová větev funguje od konce do konce** — reálná fotka byla
  poslána a doručena (SMTP `250`, potvrzeno i příjemcem).
- **AT port je `/dev/ttyUSB2`** — `ttyUSB1` i `ttyUSB2` odpovídají na
  základní AT příkazy, `ttyUSB0`/`ttyUSB3` neodpovídají na nic.
- **SMS na tomhle modemu nejde vůbec** — `AT+CLAC` (výpis podporovaných
  AT příkazů přímo z firmwaru modemu) neobsahuje jedinou SMS-příbuznou
  položku (`CMGF`, `CMGS`, `CNMI`, `CSMS`, ...). Silnější a přímější
  důkaz než `+CME ERROR` kód, a nezávislý na SIM kartě.
- **Baterie jde číst přes `AT+CBC`** (napětí článku, např.
  `+CBC: 4.011V`) — spolehlivější než plánované hledání `_battery=` v
  logu, které nikdy nebylo potvrzené.
- **Hodiny zařízení nemají baterií zálohovaný RTC** a mezi probuzeními
  volně plují (naměřený rozdíl přes 10 hodin oproti modemu) — Hunter
  proto při startu synchronizuje `date` z `AT+CCLK?` (jen když je
  offset `+00`, jinak nesahá na hodiny raději, než by hádal časové
  pásmo).
- **`AT_PORT` nemusí při startu ještě existovat** — `hunter.sh` běží
  tak brzy po probuzení, že USB výčet modemu občas nestihne vytvořit
  `/dev/ttyUSB*` uzly. `wait_for_at_port()` na to krátce (max ~5 s)
  čeká; funkce závislé na AT portu bez něj degradují na `N/A`.

### Ověřeno pod `dash`/`qemu-mipsel-static` (ne na zařízení, ale proti reálným binárkám)

Všechny C nástroje (`atcmd`, `smssend`, `smsrecv`, `mailsend`,
`mailrecv`, `snapready`, `logscan`) jsou přeložené pro cíl (MIPS32r2,
`-mfp32` shodné s `ubia_first`) — viz
[../test_files/README.md](../test_files/README.md).

Shellová vrstva (`hunter.sh`, `lib/*.sh`) je napsaná pod tvrdým
omezením: **busybox na zařízení nemá `awk`, `sed`, `cut`, `sort`,
`uniq`, `wc`, `head`, `tail`, `expr`, `tee` ani `bc`** — ověřeno přímo
v binárce ze `dump/bin/busybox`. Field extraction jde přes POSIX
parametrickou expanzi (`${var#...}`/`${var%...}`) a `case`, `tr` jen
s explicitními rozsahy (ne POSIX třídy — `FEATURE_TR_CLASSES` je
volitelný compile-time přepínač bez jistoty přítomnosti). Testovací
harness je v [../tests/](../tests/) (`sh tests/run_tests.sh`, přes
`dash` jako referenční POSIX shell).

Škálování na tisíce fotek je řešené cursorem (`state/cursor.txt`) —
automatická větev prochází jen dny od posledního vyřízeného dál, ne
celou historii. Detaily a měření v
[2026-09-02-hunter-queue-cursor-design.md](../docs/superpowers/specs/2026-09-02-hunter-queue-cursor-design.md).

Bezpečnostní vrstva e-mailových příkazů (tokeny, autorizace,
privilegované příkazy) prošla opakovaným mutačním testováním — recenze
psaly vlastní útočné testy a dvakrát je i mutačně ověřily (dočasně
odstranily kontrolu, potvrdily že test spadne, vrátily zpět). Nalezené
a opravené: prázdný řetězec jako adresa obcházel kontrolu `MAIL_MASTERS`
při poškozeném configu; vložený newline v `add_token` zapsal dva
tokeny najednou; hodnota tokenu unikala do logu u `ADD TOKEN`/`REMOVE
TOKEN`; `ensure_app_frozen` se spouštělo i pro neautorizované zprávy.

## Co NENÍ ověřené

- **`FOTO` příkaz** (vyvolání snímku na dálku) — bez znalosti MCU
  protokolu nebo cloudové autorizace se neví, jestli to jde. Odpovídá
  `FOTO NOT SUPPORTED`, nepředstírá se funkce, která nefunguje.
- **Jak `ubia_first` snese zmizení souborů, na které odkazuje
  `ubia_record.db`** — `WIPE` proto maže jen odeslané, `HDPIC/` se
  nedotýká nikdy.

## Provoz

| Situace | Co udělat |
|---|---|
| Chceš vidět, co se děje | `cat /tmp/mnt/sdcard/hunter/log.txt` |
| E-mailové příkazy nechodí | zkontroluj `hunter/mail.token` (existuje? min. 8 znaků?), `MAIL_MASTERS`, `IMAP_HOST` v configu |
| `WIPE` neuvolnil místo | zkontroluj, že mazané soubory už byly v `state/sent_list.txt` |
| Podezření na zaseklý běh | `RUN_DEADLINE` v configu je tvrdý strop (výchozí 180 s) |
| Chceš se vrátit k testování bez Huntera | `sh hunter/dev-stop.sh 600` — **pozor, chrání jen aktuální boot session**, po restartu je pryč (viz spec 2026-08-27, sekce 11, bod 11) |
