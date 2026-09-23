# Checklist — nasazení a test Huntera přes UART

Přístup je přes sériovou konzoli (piny na desce → Raspberry Pi →
`pi-tools/uartlog`, náhrada za minicom s automatickým časovým
razítkem). Telnet se nepoužívá.

Odškrtávej postupně, nepřeskakuj. Kroky 5 a 6 jsou nevratné/rizikové —
tam je u každého napsáno, co dělat, když to nedopadne.

Souhrnná referenční dokumentace (architektura, kompletní seznam
souborů/configu/příkazů, chování při chybách, obnova po nehodě):
[docs/REFERENCE.md](docs/REFERENCE.md).

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

## Fáze 8 — aktualizace: e-mailové příkazy (2026-09-01)

Tahle fáze se dělá na zařízení, které už fázemi 0–7 prošlo a **běží
naostro** (`ubia_test` se spouští samo při každém probuzení, fotky už
chodí mailem). Nejde o novou instalaci — jen o doplnění příkazového
kanálu na existující nasazení. SMS z fáze 5 se přeskakuje natrvalo:
`AT+CLAC` na tomhle modemu (SIMCom A7670E-MNXY) prokázal, že SMS
příkazy nejsou ve firmwaru vůbec, takže fáze 5 je bezpředmětná.

- [ ] **Zastavit appku na dobu úpravy** — `sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600`
      (stejný postup jako ve fázi 2).
- [ ] Vytáhnout kartu, **fyzicky přes čtečku** zkopírovat (přes UART
      neposílat — binárky jsou velké a textové soubory ztrácí
      tabulátory, viz [pi-tools/README.md](pi-tools/README.md)):
  - `hunter/bin/mailrecv` (nový)
  - `hunter/bin/mailsend` (přeložený nanovo po refaktoru na `tlsnet`)
  - `hunter/lib/command.sh`, `hunter/lib/mailcmd.sh` (nové)
  - `hunter/lib/common.sh`, `hunter/lib/mail.sh`, `hunter/lib/sms.sh`,
    `hunter/hunter.sh` (upravené)
- [ ] Na kartě založit `hunter/mail.token` — jeden token na řádek,
      každý aspoň 8 znaků, žádné mezery:
  ```sh
  echo 'muj-tajny-token-min-8-znaku' > /tmp/mnt/sdcard/hunter/mail.token
  ```
- [ ] Doplnit do `hunter/config.txt` nové klíče (vzor v
      [hunter/config.txt.example](hunter/config.txt.example)):
      `IMAP_HOST`, `IMAP_PORT` (993), `MAIL_MASTERS`, `AUTH_TYPE`
      (výchozí `TOKEN`), `REQUEST_MAX` (výchozí 5). `MAX_SEND_PER_WAKE`
      zvýšit na aspoň `REQUEST_MAX`, jinak by vyžádané fotky mohly
      vytlačit automatické (výchozí v example je teď 8).
- [ ] Kartu vrátit, připojit `uartlog`.
- [ ] **Ověřit integritu po zkopírování** — `md5sum` na kartě proti
      `md5sum` stejných souborů na build stroji. `sh -n` nestačí,
      poškozený soubor může být pořád syntakticky platný (viz historie
      téhle relace — přenos přes UART jednou takhle poškodil dva
      soubory beze změny velikosti souboru na první pohled).
- [ ] **Ověřit `mailrecv` přímo na zařízení:**
      ```sh
      /tmp/mnt/sdcard/hunter/bin/mailrecv imap.seznam.cz 993 \
        <smtp_user> --pass-file /tmp/mnt/sdcard/hunter/smtp.pass list unseen
      ```
      Očekávej prázdno nebo `UIDVALIDITY|...`/`MSG|...` řádky. `Exec
      format error` = špatné ABI, zkontroluj `-mfp32` a cross-compiler.
- [ ] **Ostrý test kanálu:** pošli z autorizované adresy mail s
      předmětem `HUNTER <tvuj-token> LIST CMD`, pak ručně
      `sh /tmp/mnt/sdcard/hunter/hunter.sh`. Zkontroluj:
  - `log.txt` má `mail prikaz od <adresa>: LIST CMD`
  - `log.txt` **neobsahuje** hodnotu tokenu (`grep '<token>' log.txt`
    prázdné)
  - odpověď s předmětem `HUNTER reply` dorazila a **neobsahuje**
    hodnotu tokenu
  - zkus i `HUNTER <token> LAST 2` — dorazí dvě fotky
- [ ] **Ověřit, že cizí pošta zůstává nedotčená** — pošli běžný mail
      bez prefixu `HUNTER `, spusť `hunter.sh`, zkontroluj že zpráva
      zůstala ve schránce **nepřečtená**.
- [ ] `sh /tmp/mnt/sdcard/hunter/dev-resume.sh` (reboot), sledovat pár
      přirozených probuzení stejně jako ve fázi 7.

## Fáze 9 — aktualizace: fronta a cursor (2026-09-02)

- [ ] `sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600` — **a pak pracovat
      svižně**. Historie z fáze 8: držet `ubia_first` mrtvý přes hodinu
      skončilo restart smyčkou vyvolanou MCU watchdogem.
- [ ] Vytáhnout kartu a **fyzicky přes čtečku** zkopírovat:
  - `hunter/lib/common.sh`, `hunter/lib/command.sh`, `hunter/lib/mail.sh`,
    `hunter/lib/status.sh`, `hunter/lib/sms.sh`, `hunter/lib/mailcmd.sh`,
    `hunter/hunter.sh`
- [ ] **Nespoléhej na tenhle seznam — porovnej md5 všech souborů**
      `hunter/*.sh`, `hunter/lib/*.sh` a `hunter/bin/*` proti repu a
      zkopíruj vše, co se liší. Při nasazení 2026-09-03 byla karta
      pozadu i na `mailcmd.sh` (chyběla jí obalka `mailrecv_run` s
      podporou `--ca` z commitu `e001d92`), přestože ho tenhle seznam
      neobsahoval. Seznam říká, co se změnilo teď; md5 řekne, co je
      na kartě doopravdy.
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
- [ ] **Zkontrolovat `hunter/state/.lock`** — když tam je, smazat ho
      (`rm -rf`). Zabitý běh po sobě zámek nechá, po restartu se jeho
      pid přidělí něčemu jinému, `acquire_lock` ho vyhodnotil jako živý
      a Hunter pak **při každém probuzení jen zapsal „jina instance
      hunter.sh uz bezi, koncim" a skončil** — tiše, navždy. Přesně to
      se stalo 2026-09-01 20:12 a zjistilo se to až o dva dny později
      při nasazení.

      **Od 2026-09-04 to `acquire_lock` řeší sám** (`lock_owner_alive`
      ověřuje přes `/proc/<pid>/cmdline`, že za pidem opravdu stojí
      `hunter.sh`), takže je to pojistka, ne nutnost. Do doby, než na
      kartě bude nová `lib/common.sh`, na to ale spoléhat nelze —
      kontroluj to při každém zásahu do karty.
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

## Fáze 10 — aktualizace: volitelný transport (2026-09-03)

- [ ] `sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600` — **a pak pracovat
      svižně**. Historie z fáze 8: držet `ubia_first` mrtvý přes hodinu
      skončilo restart smyčkou vyvolanou MCU watchdogem.
- [ ] Vytáhnout kartu a **porovnat md5 všech** `hunter/*.sh`,
      `hunter/lib/*.sh` a `hunter/bin/*` proti repu; zkopírovat vše, co
      se liší. Tahle změna se dotýká `lib/common.sh`, `lib/mail.sh` a
      **obou binárek** `bin/mailsend` i `bin/mailrecv`.
- [ ] **Ověřit, že na kartě je opravdu nová binárka** (md5 to chytí jen
      tehdy, když se binárky vůbec přeložily — jednou se na to zapomnělo
      a nikdo si nevšiml):
      ```sh
      /tmp/mnt/sdcard/hunter/bin/mailrecv 2>&1 | grep -q append \
        && echo "OK, umi append" || echo "STARA BINARKA"
      ```
- [ ] **Jednorázově ověřit, že `/proc/<pid>/cmdline` jde na zařízení
      přečíst** — na tom stojí nová kontrola zámku (`lock_owner_alive`).
      Když čitelné není, kód se schválně chová opatrně a považuje
      držitele za živého, což by při zaseklém zámku znamenalo tichý
      návrat k chování z 1. 9.:
      ```sh
      cat /proc/$$/cmdline | tr '\0' ' '; echo
      ```
      Musí vypsat příkazovou řádku shellu, ne prázdno ani chybu.
- [ ] **Ověřit timeout connectu** — `tlsnet` nově nečeká na spojení
      donekonečna (15 s). Bez toho visel `mailrecv` na zaseklém spojení
      tak dlouho, že pojistka musela běh zabít natvrdo a `cleanup`
      neproběhl. Na nesměrovatelnou adresu musí skončit do ~15 s:
      ```sh
      time /tmp/mnt/sdcard/hunter/bin/mailrecv 10.255.255.1 993 \
        x --pass-file /tmp/mnt/sdcard/hunter/smtp.pass list unseen
      ```
      Čekáš `connect() na 10.255.255.1:993 nestihl 15 s` a návrat do
      patnácti vteřin, ne minuty ticha.
- [ ] **Ověřit timeout zápisu** — druhá polovina téže opravy
      (`SO_SNDTIMEO`), a jako jediná není pokrytá žádným testem. Potřebuje
      protistranu, která spojení **přijme, ale nečte**: na Raspberry
      spusť `nc -l -p 2525`, v `hunter/config.txt` dočasně nastav
      `SMTP_HOST=<IP Raspberry>`, `SMTP_PORT=2525`, `SMTP_TLS=none` a
      počkej na fotku. Odesílací buffer se u ~400 kB přílohy zaplní a
      `mailsend` musí skončit chybou do ~30 s, ne viset až na
      `RUN_DEADLINE`. Pak hodnoty vrátit.

      Kdyby to viselo dál, není to kritické — pojistka `deadline_kill_tools`
      zaseklý nástroj zabije tak jako tak. Znamenalo by to jen, že se
      chyba pozná až po třech minutách místo po třiceti vteřinách.
- [ ] **Zkontrolovat `hunter/state/.lock`** — když tam je, smazat ho.
      Viz fáze 9, proč na to nezapomínat.
- [ ] Kartu vrátit, `dev-resume.sh`.
- [ ] **Nejdřív ověřit, že se nic nezměnilo.** Bez zásahu do configu je
      `SEND_TRANSPORT=smtp`, takže fotky musí chodit přesně jako dřív.
      Když nechodí, je chyba v refaktoru, ne v novém transportu.
- [ ] **Teprve pak přepnout** — a znamená to druhé kolo s kartou, protože
      `SEND_TRANSPORT` nejde změnit žádným mailovým příkazem. Rovnou při
      téže příležitosti připrav i ostrý test uložení:
  - `sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600`
  - vytáhnout kartu, do `hunter/config.txt` doplnit
    `SEND_TRANSPORT=smtp-imap` a `IMAP_SAVE_FOLDER=Fotopast`
  - a **dočasně** přepsat `SMTP_PORT` na nepoužívaný port, ať SMTP
    spolehlivě selže a je vidět, že se sáhne po IMAPu
  - kartu vrátit, `sh /tmp/mnt/sdcard/hunter/dev-resume.sh`
- [ ] Počkat na fotku a podívat se do složky `Fotopast` v mailovém
      klientovi — musí tam být zpráva s přílohou. V `log.txt` k tomu
      patří řádek `SMTP selhalo, zkousim ulozit pres IMAP`.
- [ ] **Vrátit `SMTP_PORT` zpět** — třetí a poslední kolo s kartou,
      stejný postup: `dev-stop.sh 600`, vytáhnout, opravit, vrátit,
      `dev-resume.sh`. Bez toho zůstane odesílání mailem rozbité.
- [ ] `HUNTER <token> STATUS` → odpověď musí dorazit stejnou cestou jako
      fotky.
- [ ] **Oddělená složka pro odpovědi.** Do `config.txt` doplnit
      `IMAP_REPLY_FOLDER=Prikazy` (jiná než `IMAP_SAVE_FOLDER`), vrátit
      kartu, `dev-resume.sh`. Poslat `HUNTER <token> STATUS` — odpověď
      musí přistát ve složce `Prikazy`, další fotka pořád ve `Fotopast`.
      Pak `IMAP_REPLY_FOLDER` zase smazat (prázdné = stejná složka jako
      fotky), ať zůstane výchozí chování pro ostrý provoz.
- [ ] **Chybová složka.** Do `config.txt` doplnit `IMAP_ERROR_FOLDER=Errors`
      a dočasně smazat/přejmenovat `hunter/config.txt` jinam tak, aby
      `load_config` selhalo (nebo prostě dočasně vygumovat jeden
      povinný klíč, např. `AT_PORT`). Vrátit kartu, `dev-resume.sh`,
      počkat na probuzení. Ve složce `Errors` musí být zpráva s textem
      chyby; v `log.txt` stejný text. Pak vrátit `config.txt` do
      pořádku a `IMAP_ERROR_FOLDER` zase smazat (prázdné = vypnuto).

## Prvních pár dní sledovat

- [ ] Žádné neočekávané restarty (smyčka resetů = watchdog problém).
- [ ] Fotky chodí e-mailem v rozumném čase po pohybu.
- [ ] `log.txt` se rotuje (limit 1 MB), neroste bez konce.
- [ ] `state/sent_list.txt` a `state/sms_seen.txt` nerostou nesmyslně
      rychle (indikátor, že se něco opakovaně vykonává znovu).

---

## Otevřené otázky, které tenhle checklist NEřeší

Viz [docs/superpowers/specs/2026-08-27-hunter-design.md](docs/superpowers/specs/2026-08-27-hunter-design.md#11-otevřené-body--ověřit-na-zařízení),
sekce 11 — většina bodů je od 2026-08-31 vyřešená přímo na zařízení
(AT port, `AT+CSQ`, `SIGSTOP`+`stopWdg`, baterie přes `AT+CBC`, SMS
probuzení je trvale bezpředmětné). Zbývají hlavně `FOTO` (vyvolání
snímku) a chování `ubia_record.db` při mazání fotek.

Fáze 8 (e-mailové příkazy) má vlastní spec a implementační plán:
[2026-08-31-hunter-mail-commands-design.md](docs/superpowers/specs/2026-08-31-hunter-mail-commands-design.md)
a [2026-08-31-hunter-mail-commands.md](docs/superpowers/plans/2026-08-31-hunter-mail-commands.md).
