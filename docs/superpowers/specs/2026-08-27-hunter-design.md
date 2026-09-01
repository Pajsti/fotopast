# Hunter — návrh služby

Datum: 2026-08-27

## 1. Účel

Malá služba na SD kartě fotopasti, která:

- odesílá nově pořízené fotografie e-mailem,
- přijímá a vykonává SMS příkazy,
- hlásí stav zařízení,
- spravuje místo na kartě.

Původní snímání, PIR workflow a cloudová aplikace zůstávají funkční.

**Stav k 2026-08-31:** e-mailová větev je hotová a **potvrzeně funkční
od konce do konce na reálném zařízení** — `ubia_test` → `hunter.sh`,
reálná fotka, SMTP server potvrdil `250`, a uživatel potvrdil skutečné
doručení (spadlo do spamu — `mailsend` negeneruje `Message-ID`, což je
pro filtry běžný varovný signál; oprava je jednořádková, ale vyžaduje
přebuild binárky, viz otevřený bod níže). SMS větev je implementovaná a
připravená, ale **na tomto kusu hardwaru (SIMCom A7670E-MNXY) nefunguje
— potvrzeno přímo modemem, ne SIM kartou** — viz sekce 7.6. Kód zůstává
v repozitáři beze změny; degraduje bezpečně (SMS se prostě nikdy
nezpracují, žádná chyba, žádný pád) a začne fungovat sám, pokud se
v budoucnu vymění modul za variantu s hlasem/SMS.

Nově zjištěno 2026-08-31: `AT+CBC` je spolehlivý přímý zdroj baterie
(napětí, ne jen dohad z logu — viz sekce 8) a **systémové hodiny na
zařízení se rozcházejí s časem modemu o hodiny** (viz sekce 2.1) —
Hunter proto při startu synchronizuje `date` z `AT+CCLK?`. Zjištěno i
opraveno: appka od nasazení 27.8. nikdy neodeslala e-mail, protože
`hunter/smtp.pass` nebyl na kartě založený (chybějící krok z checklisty,
ne chyba kódu) — po založení souboru odeslání funguje.

### Změna rozsahu oproti `Instructions.txt`

`Instructions.txt` zakazoval jakýkoli zásah do původní aplikace. Toto
omezení bylo uvolněno — zařízení je vlastní a smíme do běhu aplikace
zasahovat. Návrh toho využívá na jediném místě: **dočasně zmrazí
`ubia_first`, aby zařízení nezhaslo dřív, než Hunter dokončí odeslání.**
Nic se nepatchuje, žádný soubor původní aplikace se nepřepisuje.

## 2. Napájecí model

Toto je nejdůležitější fakt celého návrhu.

Zařízení **neběží nepřetržitě**. Cyklus vypadá takto:

```
PIR → MCU zapne SoC → boot (~0,8 s) → ubia_first
    → vyfotí → nahraje do cloudu → požádá MCU o vypnutí → tma
```

Důsledky:

- Hunter **není démon**. Je to úloha, která se při každém probuzení
  podívá, co se od minula nakupilo, a snaží se to dohnat.
- Napájení může zmizet **kdykoli**. Každá operace musí být idempotentní
  a přerušitelná bez ztráty dat.
- `ubia_first` vypnutí iniciuje sám. Jediný spolehlivý způsob, jak si
  koupit čas, je **zmrazit ho signálem `SIGSTOP`**.

### Ověřená zjištění z firmware dumpu

| Zjištění | Význam |
|---|---|
| `ubia_first` spouští `/tmp/mnt/sdcard/ubia_test &` přesně při `sd_ready` | vstupní bod Hunteru; garantuje namountovanou kartu |
| 4G modul je `usb0` (RNDIS, IP `192.168.225.x`, DNS `192.168.225.1`) | **e-mail nepotřebuje modem** — jen TCP socket přes existující rozhraní |
| `ubia_first` drží `/dev/ttyUSB0` i `/dev/ttyUSB1` | kolize hrozí **pouze** u SMS, ne u e-mailu |
| snímek se na kartu **kopíruje** (`cp /tmp/snap_hd.jpg %s`), ne přesouvá | na kartě existuje okamžik s nedopsaným JPEGem |
| `/tmp/stopWdg` umlčí `ubia_watchdog` | ověřeno v praxi skriptem `hunter/dev-stop.sh` |
| `CALLBACK_SCRIPT` v tomto buildu nikdo nečte | na tento hook se nelze spolehnout |
| ADC baterie „not support"; hodnota chodí z MCU přes I2C | Hunter si baterii **nepřečte sám** |

### 2.1 Hodiny nejsou spolehlivé

Zařízení nemá baterií zálohovaný RTC čip a mezi probuzeními neběží NTP
(Linux běží jen pár sekund/desítek sekund). Systémový čas (`date`) proto
mezi boothy volně pluje.

Měřeno 2026-08-31 přímo na zařízení: `date` hlásil `2026-08-30 22:04:44
UTC`, zatímco `AT+CCLK?` (hodiny modemu, synchronizované sítí přes NITZ
při LTE registraci) hlásil `2026-08-31 08:28:41 UTC` — **rozdíl přes 10
hodin**, a Linux navíc ukazoval o kalendářní den méně. Dřív v této
session se v OSD náhledu objevil i rok 2031, což potvrzuje, že jde o
opakovaný, ne jednorázový jev.

**Dopad:** názvy souborů (`snaps/YYMMDD/HHMMSS_...`), `Date:` hlavička
e-mailu, časová razítka v `log.txt` i `sent_list.txt` — všechno, co se
odvozuje ze systémového času, může být hodiny až dny mimo realitu.

**Opatření:** Hunter při startu (krok 4 v 4.2, hned po `touch
/tmp/stopWdg`) zavolá `AT+CCLK?` na `AT_PORT` a pokud odpověď parsuje,
nastaví systémový čas přes `date -s`. Modemové hodiny nejsou dokonalé
(NITZ má vlastní chybu, časové pásmo v odpovědi bývá nespolehlivé), ale
jsou o řády blíž realitě než neupravovaný systémový čas. Pokud parsování
nebo `AT_PORT` selže, Hunter pokračuje s tím, co má — časové razítko je
vždy lepší než pád.

### 2.2 `AT_PORT` nemusí při startu ještě existovat

Zjištěno 2026-08-31 z reálného `log.txt`: `hunter.sh` se spouští tak
brzy po probuzení (`ubia_test` běží při `sd_ready`, viz 4.1), že USB
výčet modemu ještě nemusí mít hotové `/dev/ttyUSB*` uzly — v logu se
střídají běhy, kde `AT_PORT` existuje, a běhy s `atport: open
/dev/ttyUSB2: No such file or directory`.

**Opatření:** `wait_for_at_port()` (common.sh) na začátku běhu krátce
(max ~5 s, po 1 s) čeká, než uzel zařízení vznikne, pak pokračuje tak či
onak. Netýká se odesílání e-mailu (to modem vůbec nepoužívá, viz výše) —
jen signálu, baterie a synchronizace hodin, které bez portu prostě
zůstanou `N/A`, resp. hodiny se nezmění.

### Formát `ubia_record.db` (rozluštěno, ale nepoužíváme)

```
hlavička 12 B:  [0]=0  [4]=počet  [8]=počet
záznam   12 B:  [0:4] timestamp UTC (LE uint32)
                [4:8] 0xFFFF0000 (konstanta)
                [8:12] 0x01040078 (P) | 0x01030078 (N)
```

Ověřeno 8/8 proti názvům souborů. Měnící se bajt je **typ spouště**
(P/N), nikoli úhel PIR — úhel v databázi není.

**Rozhodnutí: databázi nečteme ani do ní nezapisujeme.** Neobsahuje nic,
co by nebylo v názvu souboru (čas i typ), má nedokumentovaný formát a
zrcadlo `.dup` držené v synchronizaci. Zápis by znamenal riziko rozbití
indexu původní aplikace při nulovém zisku. Hunter si vede vlastní
`sent_list.txt`.

## 3. Rozvržení na kartě

```
/tmp/mnt/sdcard/
├── snaps/                    (původní aplikace, jen čteme)
├── ubia_record.db            (původní aplikace, nesaháme)
├── ubia_test                 spouštěč — sem sahá ubia_first (viz 4.1)
└── hunter/
    ├── hunter.sh             orchestrátor
    ├── lib/
    │   ├── common.sh         log, atomický zápis, zámek
    │   ├── status.sh         baterie / signál / místo
    │   ├── mail.sh           sestavení a odeslání e-mailu
    │   └── sms.sh            příjem, autorizace, vykonání příkazů
    ├── bin/                  atcmd, smssend, smsrecv, mailsend
    ├── config.txt            konfigurace (viz 9)
    ├── smtp.pass             heslo SMTP, odděleně od configu
    ├── state/
    │   ├── sent_list.txt     odeslané fotografie
    │   └── sms_seen.txt      zpracované SMS (ochrana proti dvojímu výkonu)
    └── log.txt
```

`ubia_test` musí ležet v **kořeni karty**, ne ve složce `hunter/` — cesta
`/tmp/mnt/sdcard/ubia_test` je napevno v binárce `ubia_first`.

`Instructions.txt` počítal s jediným `state.txt`. Nahrazuje ho složka
`state/` se dvěma soubory, protože jde o dvě nezávislé věci s různou
životností: seznam odeslaných fotek a seznam zpracovaných SMS. Fronta
nedodělků se needviduje zvlášť — „nedodělek" je odvozený stav
(soubor ve `snaps/`, který není v `sent_list.txt`), a druhý zdroj pravdy
by se jen rozcházel.

## 4. Posloupnost jednoho probuzení

### 4.1 Vstupní bod

`ubia_first` spouští `/tmp/mnt/sdcard/ubia_test` sám, jakmile je karta
připravená. Tam se zavěsíme — je to lepší než `/config/debug.sh`, protože
garantuje namountovanou kartu a nevyžaduje zásah do systémové části.

`ubia_test` je tedy jednořádkový spouštěč:

```sh
#!/bin/sh
exec /tmp/mnt/sdcard/hunter/hunter.sh >> /tmp/mnt/sdcard/hunter/log.txt 2>&1
```

### 4.2 Hlavní běh

```
 1. zámek        jediná instance; při druhém spuštění okamžitý konec
 2. trap EXIT    pojistka: za všech okolností SIGCONT + úklid stopWdg
 3. deadline     tvrdý strop celého běhu (výchozí 180 s)
 4. touch /tmp/stopWdg
 5. SMS          přijmi, autorizuj, vykonej, odpověz      ← priorita
 6. čekej        na nový snímek z tohoto probuzení (viz 5)
 7. SIGSTOP      ubia_first zmrazen → nezhasne     (jen když je co poslat)
 8. e-mail       odešli nové snímky (usb0), max N za probuzení
 9. sent_list    atomický zápis až po potvrzení serverem
10. SIGCONT      ubia_first dokončí upload a normálně usne
11. prodleva     ~5 s, ať se obnoví heartbeat
12. rm /tmp/stopWdg
```

Kroky 7–10 se přeskočí, když po kroku 6 není **nic** k odeslání — ani
nový snímek, ani nedodělek z minula. Zbytečně mrazit aplikaci kvůli
prázdné frontě nemá smysl a jen by to prodloužilo dobu vzhůru.

Krok 7 je jádro: **`SIGSTOP` nezabíjí, zmrazí.** Zmrazená aplikace
nestihne požádat MCU o vypnutí. Po `SIGCONT` dokončí svůj upload a usne
sama, jako by se nic nestalo — nemusíme nic patchovat.

### 4.3 Bezpečnostní pravidla

Tato tři pravidla jsou nepominutelná; jejich porušení znamená cihlu nebo
smyčku restartů.

1. **`stopWdg` vždy před `SIGSTOP`**, rušit až několik sekund po
   `SIGCONT`. Jinak `ubia_watchdog` uvidí zastaralý `firstProcLastTime`
   a resetuje zařízení.
2. **`trap` na `EXIT`, `INT`, `TERM`, `HUP`** musí za všech okolností
   provést `SIGCONT` a odklidit `stopWdg`. Pád skriptu nesmí nechat
   aplikaci zmrazenou.
3. **Tvrdý strop běhu.** Po vypršení deadline Hunter bezpodmínečně
   uklidí a skončí, i kdyby nic neodeslal. Fotografie se pošle příště.

### 4.4 Chyba SD karty

Když karta chybí nebo je jen pro čtení, `ubia_test` se vůbec nespustí a
zařízení funguje beze změny. Hunter nikdy neblokuje boot ani snímání.

## 5. Detekce nové fotografie

Žádné hlídání složky — busybox nemá `inotifyd` a při krátkém okně to
nemá smysl. Detekce je **rozdíl množin**:

```
kandidáti = snaps/**/*.jpg  −  sent_list.txt
```

Snímek se považuje za připravený k odeslání, až když projde **všemi**
kontrolami:

1. velikost > 0 a nemění se mezi dvěma odečty (odstup ~1 s),
2. soubor končí značkou `FF D9` (JPEG EOI),
3. stáří alespoň 2 s.

Kontrola 2 je podstatná: snímek se na kartu **kopíruje**, takže existuje
okamžik, kdy je na kartě jen jeho část. Bez ověření EOI bychom občas
poslali půlku fotky.

Krok 6 posloupnosti čeká na nového kandidáta do vypršení `SNAP_WAIT`
(výchozí 25 s). Když nic nepřijde, pošle jen nedodělky z minula.

## 6. Odesílání e-mailu

Přes `bin/mailsend`, STARTTLS + AUTH, přílohou je JPEG. Modem se nepoužívá
vůbec — jde to po `usb0`.

**Předmět:** datum a čas pořízení, odvozené z názvu souboru
(`snaps/YYMMDD/HHMMSS_...`), ne z času odeslání.

**Tělo:**

```
Battery: xx%
Signal: xx%
Space: xx.xxxGB
```

Nedostupná hodnota se vypíše jako `N/A` (požadavek `Instructions.txt` —
nikdy neodhadovat).

**Zápis do `sent_list.txt` až po návratovém kódu 0 z `mailsend`**, tedy
po potvrzení serverem. Když zařízení zhasne uprostřed odesílání, snímek
prostě zůstane neodeslaný a pošle se při dalším probuzení. Nikdy
nevznikne stav „označeno jako odeslané, ale nedorazilo".

**Strop na probuzení:** `MAX_SEND_PER_WAKE` (výchozí 3). Zabraňuje tomu,
aby se Hunter při velkém nedodělku snažil odeslat sto fotek a vysál
baterii. Zbytek počká.

## 7. SMS příkazy

> **Nahrazeno 2026-09-01.** Sekce 7.6 níže dokumentuje, jak se na tomto
> modemu (SIMCom A7670E-MNXY) prokázalo přes `AT+CLAC`, že SMS příkazy
> ve firmwaru vůbec nejsou — ne otázka SIM karty ani portu. Příkazový
> kanál, který tahle sekce navrhovala, teď existuje jako **e-mailový**
> kanál — viz
> [2026-08-31-hunter-mail-commands-design.md](2026-08-31-hunter-mail-commands-design.md)
> a jeho implementační plán
> [2026-08-31-hunter-mail-commands.md](../plans/2026-08-31-hunter-mail-commands.md).
> Kód `sms.sh`/`smsrecv`/`smssend` zůstává v repozitáři (degraduje
> bezpečně — `process_sms` prostě nic nenajde a vrátí se) a začne
> fungovat sám, pokud se modul někdy vymění za variantu s SMS. Zbytek
> téhle sekce je ponechán jako záznam původního návrhu a důvodů, proč
> vypadá tak, jak vypadá — nový kanál z něj vychází (stejný vykonavač
> příkazů, stejná dedup-před-vykonáním logika, stejná filozofie
> "neautorizovanému se neodpovídá").

### 7.1 Průběh

```
1. smsrecv list unread        → MSG|index|status|odesílatel|čas|tělo
2. autorizace                 → odesílatel musí být v MASTERS
3. deduplikace                → index+čas už v sms_seen.txt? přeskoč
4. vykonání
5. odpověď                    → jen když CONFIRM=ON
6. smsrecv del <index>        → uklidit úložiště modulu
```

Krok 3 je kvůli výpadku napájení: kdyby zařízení zhaslo mezi vykonáním a
smazáním, příkaz by se při dalším probuzení vykonal podruhé. U `WIPE` by
to bylo nepříjemné.

Neautorizovaná SMS se **smaže bez odpovědi**. Odpovídat cizímu číslu je
zbytečné a prozrazuje to, že zařízení existuje.

### 7.2 Příkazy

| Příkaz | Chování |
|---|---|
| `STATUS` | pošle stavový řádek (viz 8) |
| `QUALITY HD` / `QUALITY LOW` | přepíše `QUALITY` v configu |
| `CONFIRM ON` / `CONFIRM OFF` | přepíše `CONFIRM` v configu |
| `ADD +420…` | přidá číslo do `MASTERS` |
| `WIPE` | smaže snímky (viz 7.3) |
| `FOTO` | **viz 7.4 — zatím neověřitelné** |

Parsování je case-insensitive, přebytečné mezery se ignorují. Neznámý
příkaz → odpověď `UNKNOWN CMD` (jen při `CONFIRM=ON`).

### 7.3 `WIPE`

Maže **výhradně** `snaps/**/*.jpg`, a to jen soubory, které už jsou v
`sent_list.txt`. Nikdy se nedotkne:

- `ubia_record.db` ani `.dup`,
- `logfile.txt`,
- složky `video/`, `HDPIC/`, `System Volume Information`,
- čehokoli mimo `snaps/`.

Po smazání se z `sent_list.txt` odstraní záznamy o neexistujících
souborech, aby soubor nerostl donekonečna.

**Otevřený bod:** není ověřeno, jak původní aplikace snese zmizení
snímků, na které odkazuje `ubia_record.db`. Do ověření (viz 11) se `WIPE`
chová konzervativně — maže jen odeslané a jen na výslovný příkaz.

### 7.4 `FOTO` — otevřený bod

Snímky typu `N` naznačují spouštění po síti (cloudem). Není ověřeno,
jestli umíme vyvolat snímek my, bez znalosti MCU protokolu nebo cloudové
autorizace. **Dokud to není ověřeno, `FOTO` odpoví `FOTO NOT SUPPORTED`.**
Nepředstírá se funkce, která nefunguje.

### 7.5 Buzení pro SMS

Modemy si SMS nevyzvedávají — síť je tlačí sama, jakmile je modul
registrovaný. Polling po pěti minutách by ve skutečnosti znamenal budit
hostitele každých pět minut, což je nejdražší varianta na baterii a ještě
s horší latencí než push.

Cílový stav: modul zůstane registrovaný v úsporném režimu a při příchozí
SMS **vzbudí hostitele**. V `ubia_first` jsou stopy, že ta cesta v
zařízení existuje (`net wake up`, `get4gWakeUpFromMcu`, `wowserver` —
cloud po ní dělá živý náhled).

**Do ověření (viz 11) platí fallback:** SMS se zpracují při každém
přirozeném probuzení. Latence je pak dána četností pohybu před čočkou.

Tenhle bod je teď podřízený sekci 7.6 — nemá smysl řešit probuzení pro
SMS, dokud SMS na modulu vůbec nejdou.

### 7.6 Zjištění: SMS na tomto modulu nefunguje — potvrzeno

Měřeno přímo na zařízení (přes UART, ne z dumpu) po zapojení
`dev-stop.sh`, tedy bez kolize s `ubia_first`:

| Test | Výsledek |
|---|---|
| `AT` na `ttyUSB0`, `ttyUSB3` (5 rychlostí) | žádná odpověď |
| `AT`, `AT+CPIN?`, `AT+CFUN?`, `AT+CREG?`, `AT+CGREG?`, `AT+CSCS=?`, `AT+CMEE=2`, `ATI`, `AT+CPSI?` na `ttyUSB1`/`ttyUSB2` | vše `OK`, plně funkční |
| `AT+CMGF=1`, `AT+CPMS?`, `AT+CPMS=?`, `AT+CSCA?`, `AT+CNMI?`, `AT+GCAP` na `ttyUSB1`/`ttyUSB2` | **vše `ERROR`, konzistentně** |
| Plný cyklus `AT+CFUN=0` → `AT+CFUN=1` → 40 s poslech na URC | `+CPIN: READY` přišlo, **`Call Ready` a `SMS Ready` nikdy** |
| `AT+CMGF=1` znovu po cyklu výše | pořád `ERROR` |

`AT+CPSI?` mezitím vrátil kompletní, validní data o LTE buňce
(`LTE,Online,230-02,...,EUTRAN-BAND3,...`) — modul je prokazatelně plně
zaregistrovaný v síti se silným signálem. Modem (`ATI`) se hlásí jako
**SIMCom A7670E-MNXY**.

**Interpretace:** SIMCom vyrábí datové-only varianty A7670E bez SMS/hlasu
(potvrzeno pro příponu `-LNXY-UBL`; naše `-MNXY` je jiná přípona, ale
vzorec chování — vše síťové/SIM funguje, celá skupina SMS příkazů padá
jednotně na obou reálných portech — sedí na tuhle kategorii, ne na
problém s konkrétním portem nebo na časování).

**Dořešeno 2026-08-31 — `AT+CLAC`:** místo honby za `+CME ERROR` kódem se
ukázal přímější test. `AT+CLAC` nechá modem vypsat **úplný seznam AT
příkazů, které jeho firmware vůbec zná** (několik set položek — síť, SIM,
GNSS, STK, diagnostika, PSM...). V celém výpisu **není jediný SMS
příkaz**: chybí `CMGF`, `CMGS`, `CMGL`, `CMGR`, `CMGD`, `CMGW`, `CNMI`,
`CPMS`, `CSCA`, `CSMS` — celá skupina TS 27.005. Tohle je silnější důkaz
než jakýkoli `+CME ERROR` kód: je to sebehlášení modemu o vlastní
schopnosti, nezávislé na SIM kartě i na tom, který port se použije.
**Konzultace jiné SIM karty je tím bezpředmětná** — SIM karta nemůže
přidat příkaz do AT tabulky, kterou má firmware modemu pevně
zkompilovanou.

Zajímavé (ale ne SMS-relevantní) věci, které `AT+CLAC` zároveň odhalil a
které se hodí jinam v návrhu: `AT+CBC` (baterie, viz sekce 8), `AT+CCLK`
(hodiny modemu, viz sekce 2.1), `AT+CTBURST`/`AT+LTEPOWER` (řízení
vysílacího výkonu — případně relevantní pro bod 10 v sekci 11, pokud se
restarty ukážou být brownoutem při vysílání).

**Dopad na zbytek návrhu:** `hunter/lib/sms.sh`, `bin/smssend`,
`bin/smsrecv` zůstávají v kódu beze změny. `process_sms()` v `hunter.sh`
zavolá `smsrecv list unread`, to interně selže na `AT+CMGF=1` a vrátí
prázdno — funkce se čistě vrátí, žádná fotka ani e-mail tím není
ovlivněný. Pokud se SMS podpora (jinou SIM, jiným modulem) v budoucnu
potvrdí, kód začne fungovat bez úprav.

## 8. Stav zařízení

| Hodnota | Zdroj | Spolehlivost |
|---|---|---|
| `Space` | `df /tmp/mnt/sdcard` | spolehlivé, bez závislostí |
| `Signal` | `AT+CSQ` na volném AT portu, `rssi × 100 / 31`; `99` → `N/A` | závisí na volném portu |
| `Battery` | `AT+CBC` na `AT_PORT` | **ověřeno 2026-08-31**, viz níže |

Baterii si Hunter po I2C od MCU přečíst nemůže — do té linky lézt
nebudeme, rozbilo by to protokol původní aplikace. Původní plán (parsovat
`_battery=` z `logfile.txt`) je nahrazen přímějším zdrojem: `AT+CBC` je
standardní příkaz (je v `AT+CLAC` výpisu, viz 7.6) a modul na něj
odpovídá napětím baterie, např. `+CBC: 4.011V`. `bin/logscan` (dřív
určený pro `logfile.txt`) se použije místo toho na parsování téhle
odpovědi. Napětí se do `%` převádí lineární aproximací pro 1-článkovou
Li-ion/LiPo (prázdno ~3.3V, plno ~4.2V); mimo tento rozsah se ořízne na
0–100 %. Selže-li `AT_PORT` nebo parsování, `Battery: N/A`.

Nedostupná hodnota je vždy `N/A`, nikdy odhad.

## 9. Konfigurace

`hunter/config.txt`, formát `KLÍČ=HODNOTA`, komentáře `#`:

```
MASTERS=+420123456789,+420987654321
QUALITY=HD
CONFIRM=ON

SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=fotopast@gmail.com
SMTP_TO=me@example.com
SMTP_TLS=starttls

AT_PORT=/dev/ttyUSB2
AT_BAUD=115200

SNAP_WAIT=25
MAX_SEND_PER_WAKE=3
RUN_DEADLINE=180
```

Heslo je zvlášť v `hunter/smtp.pass` a předává se přes `--pass-file`,
protože obsah příkazové řádky je vidět v `ps`.

Zápis configu (příkazy `QUALITY`, `CONFIRM`, `ADD`) je **atomický**:
zápis do `config.txt.tmp`, `sync`, `mv`. Výpadek uprostřed nikdy nenechá
poloviční config.

## 10. Odolnost proti výpadku

| Riziko | Opatření |
|---|---|
| zhasnutí uprostřed odesílání | `sent_list.txt` až po potvrzení serverem |
| zhasnutí mezi vykonáním a smazáním SMS | `sms_seen.txt` před vykonáním |
| poloviční config / stav | zápis do `.tmp` + `sync` + `mv` |
| pád skriptu se zmrazenou aplikací | `trap` na EXIT/INT/TERM/HUP |
| zaseknutý Hunter | tvrdý deadline, pak bezpodmínečný úklid |
| dvojí spuštění | zámek na začátku |
| nedopsaný JPEG | ověření `FF D9` + stabilní velikost |
| watchdog reset | `stopWdg` před `SIGSTOP`, prodleva po `SIGCONT` |

## 11. Otevřené body — ověřit na zařízení

Tyto body nejsou z dumpu zjistitelné a musí se změřit **před** dokončením
implementace. Do té doby má každý z nich definované konzervativní
chování.

1. ~~Který `/dev/ttyUSB*` odpovídá na AT a je volný.~~ **Vyřešeno
   2026-08-30, jinak než čekáno:** `ttyUSB1` i `ttyUSB2` odpovídají na
   základní AT (nezávisle na tom, jestli `ubia_first` běží), `ttyUSB0` a
   `ttyUSB3` neodpovídají na žádné z 5 testovaných rychlostí. Ale ani
   jeden z odpovídajících portů nepodporuje SMS příkazy — viz 7.6. Config
   necháváme na `ttyUSB2` (funkční pro `AT+CSQ`/`STATUS`, jen ne pro SMS).
2. ~~Zda `AT+CSQ` funguje.~~ **Ověřeno 2026-08-30: ano**, na `ttyUSB1` i
   `ttyUSB2`.
3. ~~Zda příchozí SMS vzbudí hostitele.~~ **Trvale bezpředmětné,
   uzavřeno 2026-08-31:** SMS na tomto modemu nejdou vůbec (potvrzeno
   `AT+CLAC`, viz 7.6), takže probouzení pro SMS nemá co řešit.
4. ~~Zda je `_battery=` v `logfile.txt`.~~ **Bezpředmětné, vyřešeno jinak
   2026-08-31:** místo hledání v logu se baterie čte přímo přes
   `AT+CBC` (viz sekce 8) — spolehlivější zdroj, ověřený na zařízení
   (`+CBC: 4.011V`).
5. ~~Zda `SIGSTOP` + `stopWdg` skutečně oddálí vypnutí.~~ **Ověřeno
   2026-08-31, přímo z `log.txt` na zařízení:** appka běžela naostro
   (přes `ubia_test`) od 27.8. a v logu je přes 10 cyklů `ubia_first
   (pid …) zmrazen` → `ubia_first pokracuje` → `hunter konec`, bez
   jediného watchdog resetu mezi nimi. Byl to nejrizikovější bod celého
   návrhu — teď potvrzený opakovaně na reálném hardwaru, ne jen
   v simulaci.
6. **Jak aplikace snese smazání snímků**, na které odkazuje
   `ubia_record.db`. → jinak `WIPE` jen pro odeslané.
7. **Zda umíme vyvolat snímek** (příkaz `FOTO`). → jinak
   `FOTO NOT SUPPORTED`.
8. ~~Skutečný `+CME ERROR` kód pro `AT+CMGF=1`.~~ **Bezpředmětné,
   vyřešeno jinak 2026-08-31:** `AT+CLAC` dal přímější a silnější důkaz —
   viz 7.6.
9. ~~Zda jiná SIM karta změní výsledek `AT+CMGF=1`.~~ **Zamítnuto
   2026-08-31 jako zbytečné:** `AT+CLAC` prokázal, že SMS příkazy chybí
   ve firmwaru modemu, ne v SIM kartě. SIM kartu není potřeba zkoušet.
10. **Proč se zařízení opakovaně restartuje samo**, i když nikdo nebyl
    fyzicky u fotopasti a nehýbal se před čočkou. **Živě pozorováno
    2026-08-31:** během této session se zařízení restartovalo bez zásahu
    a `ubia_first` se rozeběhl znovu — `/tmp/stopWdg` i `/tmp/hunter_hold`
    byly po restartu pryč (očekávané, `/tmp` je tmpfs), takže **dev-stop
    ochrana nepřežila reboot** a měření od tohoto bodu dál je potřeba
    brát s rezervou, dokud se dev-mode neudělá trvalý (viz bod 11 níže).
    **Z velké části vysvětleno 2026-08-31:** boot log při těchto
    restartech přímo obsahuje `SetWifiMcuEvenType[1619] is pir wake up` —
    tedy jde o skutečná, legitimní PIR probuzení (opakovaný pohyb u
    zařízení během práce na něm), ne o poruchu nebo watchdog smyčku.
    V jedné session bylo pozorováno probuzení každých ~60–90 s po dobu
    několika minut, což odpovídá pohybu lidí okolo zařízení při
    nasazování/testování, ne anomálii. Zbývá ověřit, jestli se stejná
    frekvence objevuje i bez lidí v místnosti (viz `pi-tools/uartlog`
    puštěný dlouhodobě, `CHECKLIST.md` "Hned teď") — pokud ano, teprve
    tehdy hledat jinou příčinu (`wowserver`, brownout při vysílání
    přes `AT+CTBURST`/`AT+LTEPOWER`, nebo vlastní `hunter_deadman.sh`).
11. **`dev-stop.sh` chrání jen aktuální boot session.** Nově zjištěno
    2026-08-31 (viz bod 10) — `/tmp/stopWdg`, `/tmp/hunter_hold` i
    `hunter_deadman.sh` žijí v tmpfs a restart je smaže. Návrh opravy:
    lepivý příznak na kartě (`hunter/DEV_MODE`, mimo tmpfs), který
    `hunter.sh` při každém probuzení zkontroluje a pokud existuje, hned
    zastaví `ubia_first` a nastaví `stopWdg` znovu — bez ručního zásahu
    po každém restartu. Zatím neimplementováno.
12. **`mailsend` negeneruje hlavičku `Message-ID`.** Potvrzeno
    2026-08-31: první reálný e-mail doručen, ale do spamu — chybějící
    `Message-ID` je pravděpodobně jeden z důvodů (RFC 5322 ji doporučuje,
    filtry její absenci často penalizují). Oprava je malá (přidat
    `Message-ID: <...>\r\n` do hlaviček v `test_files/mailsend.c`), ale
    vyžaduje přebuild mipsel binárky a její nasazení na kartu (fyzicky
    přes čtečku - binárka je moc velká na spolehlivý přenos přes UART
    heredoc, viz `pi-tools/README.md`). Nízká priorita, funkčnost tím
    není blokovaná.

## 12. Mimo rozsah

- **Náhrada původní aplikace vlastním snímáním a PIR.** Vyžadovalo by
  znovupostavení Ingenic IMP SDK, ISP tuningu pro senzor `sc235hai` a
  reverz I2C protokolu s MCU. Obojí je nedokumentované a poměr práce k
  užitku je špatný — `ubia_first` umí přesně ty dvě věci, které my
  neumíme.
- Zápis do `ubia_record.db`.
- Odesílání videa (`video/`, `HDPIC/`).
- Teplota a stav PIR ve `STATUS` (volitelné rozšíření podle
  `Instructions.txt`).
- Diakritika v SMS (textový režim + `CSCS="GSM"` je ASCII; příkazy i
  stavové zprávy jsou ASCII, takže to nevadí).
