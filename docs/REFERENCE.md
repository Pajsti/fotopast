# Hunter — kompletní referenční dokumentace

> Tohle je jeden souhrnný dokument, který dává dohromady fakta rozeseta
> po [README.md](../hunter/README.md), [CHECKLIST.md](../CHECKLIST.md)
> a specifikacích v `docs/superpowers/specs/`. Necílí na to je
> nahradit — README zůstává provozní návod k nasazení, CHECKLIST
> zůstává testovací seznam. Hledáš-li návod, jak Huntera **běžně
> používat** (posílání příkazů, co který dělá), je to
> [guide.md](../guide.md), ne tenhle dokument. Tenhle dokument je
> referenční mapa: architektura, kompletní seznam souborů/konfigurace/
> příkazů, chování při chybách a obnova po nehodě. Datum poslední
> revize: 2026-09-23.

## Obsah

1. [Co Hunter dělá a proč](#1-co-hunter-dělá-a-proč)
2. [Architektura — mapa souborů](#2-architektura--mapa-souborů)
3. [Životní cyklus jednoho probuzení](#3-životní-cyklus-jednoho-probuzení)
4. [Soubory na SD kartě — co je nutné pro běh](#4-soubory-na-sd-kartě--co-je-nutné-pro-běh)
5. [Stavové soubory — inventář a obnova](#5-stavové-soubory--inventář-a-obnova)
6. [Konfigurace — kompletní referenční tabulka](#6-konfigurace--kompletní-referenční-tabulka)
7. [E-mailové příkazy — kompletní referenční tabulka](#7-e-mailové-příkazy--kompletní-referenční-tabulka)
8. [IMAP transport a tři oddělené složky](#8-imap-transport-a-tři-oddělené-složky)
9. [Zámek a watchdog](#9-zámek-a-watchdog)
10. [Výkon a známé limity](#10-výkon-a-známé-limity)
11. [Testování](#11-testování)
12. [Provozní postupy](#12-provozní-postupy)

---

## 1. Co Hunter dělá a proč

Hunter je vlastní služba běžící z SD karty 4G fotopasti (Ingenic T31,
MIPS/uClibc/busybox), vedle **nezměněné** vendor aplikace `ubia_first`.
Řeší tři věci, které vendor firmware neumí:

1. **Posílá nové fotky e-mailem** (SMTP nebo IMAP APPEND, viz sekce 8).
2. **Přijímá vzdálené příkazy** přes e-mail (`STATUS`, `LAST`, `DATE`,
   `GET`, `WIPE`, správa oprávněných uživatelů...) — SMS příkazy na
   tomto modemu (SIMCom A7670E-MNXY) nefungují vůbec (`AT+CLAC` ukázal,
   že SMS příkazy nejsou ve firmwaru).
3. **Spravuje místo na kartě** — `WIPE CONFIRM` maže už odeslané fotky,
   `MAX_QUEUE`/`CLEAR QUEUE` hlídají, aby nedodělek nerostl bez konce.

Základní princip: Hunter **nikdy neupravuje** `ubia_first` ani jeho
soubory (`ubia_record.db`, `ubia_record.dup`, `logfile.txt`, `HDPIC/`,
`video/`). Jen ho na chvíli zmrazí (`SIGSTOP`/`SIGCONT`), přečte
`snaps/`, a jinak žije vedle něj. Není to démon — je to úloha, kterou
`ubia_first` sám spouští při **každém probuzení** zařízení (viz sekce 3).

Zařízení **nemá zálohovanou reálnou hodinu (RTC)** — čas mezi
probuzeními plave a resetuje se. Proto je cursor (sekce 5) vždy
strukturální ("den X je vyřízený"), nikdy založený na hodinách.

## 2. Architektura — mapa souborů

```
hunter/
├── hunter.sh          orchestrátor - spouští ho sdcard-root/ubia_test
├── lib/
│   ├── common.sh      log, atomické zápisy, zámek, načtení configu,
│   │                  cursor, drobné shellové pomocníky (694 řádků)
│   ├── mail.sh         celá foto-pipeline: kandidáti, čekání na nový
│   │                  snímek, sestavení a odeslání zprávy (370 řádků)
│   ├── mailcmd.sh      transport příkazů přes e-mail/IMAP (139 řádků)
│   ├── command.sh      transportně NEZÁVISLÝ vykonavač příkazů - bere
│   │                  text, vrací odpověď v CMD_REPLY (651 řádků)
│   ├── sms.sh          příjem/vykonání SMS příkazů (97 řádků) - BĚŽÍ
│   │                  KAŽDÉ probuzení (`process_sms` v hunter.sh), ale
│   │                  je to fakticky mrtvý kód: modem SMS textový režim
│   │                  odmítá (`AT+CMGF=1 selhalo`), takže nikdy nic
│   │                  neudělá. Zůstává jako bezpečná no-op větev, ne
│   │                  omylem.
│   └── status.sh       Battery/Signal/Space - vrací číslo s jednotkou
│                       nebo "N/A", nikdy odhad (181 řádků)
├── bin/                zkompilované C binárky (zdroj: test_files/):
│                       atcmd, mailsend, mailrecv, smssend, smsrecv,
│                       snapready, logscan
├── config.txt          skutečná konfigurace (NENÍ ve verzování - secrets)
├── config.txt.example  šablona, okomentovaná - kopíruje se a upravuje
├── smtp.pass           heslo SMTP/IMAP (NENÍ ve verzování)
├── mail.token          tokeny pro e-mailové příkazy (NENÍ ve verzování)
├── dev-stop.sh          zastaví ubia_first pro bezpečnou práci s kartou
├── dev-resume.sh        vrátí ubia_first zpět do provozu
└── state/               runtime stav, viz sekce 5 (NENÍ ve verzování,
                        vzniká za běhu)

sdcard-root/
└── ubia_test            spouštěcí hák - MUSÍ být v KOŘENI SD karty,
                        cesta /tmp/mnt/sdcard/ubia_test je napevno
                        zapsaná v binárce ubia_first (viz sekce 4)

test_files/               zdrojáky C binárek (atcmd.c, mailsend.c,
                        mailrecv.c, tlsnet.c/.h, mimemsg.c/.h, ...) a
                        jejich jednotkové testy - kompilují se na
                        Raspberry Pi (MIPS cross-compile), NIKDY přímo
                        na zařízení

tests/                    shellové testy Hunteru (dash), viz sekce 11

pi-tools/                  pomocné nástroje pro Raspberry Pi (uartlog
                        náhrada minicomu, cross-compile skripty)

docs/superpowers/         spec/plan páry z jednotlivých návrhových cyklů
  specs/, plans/          (historický záznam rozhodnutí, ne živý návod)
```

**Proč `command.sh` nezná transport:** SMS i e-mailové příkazy sdílí
jeden vykonavač (`execute_command`), aby existovala jedna definice
"co příkaz X dělá", ne dvě, co se můžou rozejít. Konkrétní transport
(`sms.sh`, `mailcmd.sh`) jen dekóduje/autorizuje a předá text dál.

## 3. Životní cyklus jednoho probuzení

```
ubia_first (vendor)
  └─ při sd_ready spustí /tmp/mnt/sdcard/ubia_test
       └─ exec hunter/hunter.sh >> hunter/log.txt 2>&1

hunter.sh:
  1. acquire_lock()               - zámek přes mkdir (viz sekce 9)
  2. spustí watchdog na pozadí    - po RUN_DEADLINE (výchozí 180 s)
                                    zabije síťové nástroje, pak hlavní
                                    proces (viz sekce 9)
  3. rotate_log_if_needed()       - log.txt nad 1 MB → log.txt.old
  4. load_config()                - načte config.txt, doplní výchozí
                                    hodnoty, validuje SEND_TRANSPORT
  5. wait_for_at_port()           - krátké čekání na /dev/ttyUSB*
  6. sync_clock_from_modem()      - AT+CCLK?, nastaví systémový čas
  7. process_sms()                - no-op (viz sekce 2)
  8. process_mail()               - přečte IMAP schránku, vykoná
                                    příkazy (STATUS/LAST/WIPE/...)
  9. wait_for_candidates()        - najde nové kompletní fotky (cursor
                                    + sent_list.txt, viz sekce 5)
 10. CLEAR QUEUE / MAX_QUEUE       - případné úpravy fronty podle
                                    příkazů zpracovaných v kroku 8
 11. ensure_app_frozen()          - SIGSTOP na ubia_first (JEN pokud
                                    je co posílat)
 12. odeslání fotek                send_snap() pro každého kandidáta,
                                    max MAX_SEND_PER_WAKE
 13. cleanup() (přes trap)         SIGCONT na ubia_first, zabije
                                    watchdog, uvolní zámek
 14. log "hunter konec"
```

**Deadline-zabitý běh nikdy nedologuje "hunter konec"** — to je
očekávané, ne chyba (viz `hunter.sh` cleanup/trap komentáře). Signálem
zdravého provozu je, že zámek nezůstává trvale obsazený, ne že každý
běh dokončí krok 14.

## 4. Soubory na SD kartě — co je nutné pro běh

Zodpovězeno investigací 2026-09-22. Sloupec **Povinné** znamená: bez
tohoto souboru se Hunter buď vůbec nespustí, nebo se spustí, ale daná
funkce nebude fungovat (upřesněno v poznámce).

| Cesta | Povinné | Co se stane, když chybí |
|---|---|---|
| `/ubia_test` (kořen karty) | **ANO** | `ubia_first` nikdy nespustí `hunter.sh` — cesta je napevno v binárce, nejde obejít ani configem. Bez tohohle souboru Hunter neběží, i kdyby byl `hunter/` dokonalý. |
| `hunter/hunter.sh` | **ANO** | `ubia_test` skončí chybou "No such file" do `log.txt`. |
| `hunter/lib/*.sh` (6 souborů) | **ANO** | `hunter.sh` selže hned na prvním `.` (source) chybějícího souboru. |
| `hunter/bin/*` (7 binárek) | **ANO** | Selže konkrétní funkce, která binárku volá (odeslání, AT příkazy, SMS...), ne celý běh — ale prakticky nepoužitelné bez nich. |
| `hunter/config.txt` | **ANO** | `load_config` to explicitně hlídá (`common.sh:423`): zaloguje `CHYBA: chybi ... config.txt, koncim` a **čistě skončí**, ne pád. |
| `hunter/smtp.pass` | Pro odesílání ano | Binárky `mailsend`/`mailrecv` selžou na `--pass-file`, ale `hunter.sh` samotný neshodí — jen se nic neodešle/nepřijme přes IMAP. |
| `hunter/mail.token` | Pro TOKEN příkazy ano | Běh pokračuje normálně, ale **všechny příkazy v režimu `AUTH_TYPE=TOKEN` se odmítnou** jako neplatný token (`command.sh` line 55: `[ -f "$TOKEN_FILE" ] || return 1`). |
| `hunter/state/` a jeho soubory | NE | Samo se vytvoří (`mkdir -p` v `hunter.sh`), podrobně viz sekce 5. |
| `hunter/dev-stop.sh`, `dev-resume.sh` | NE | Operátorské nástroje pro bezpečnou práci s kartou, nejsou součástí běhu. |
| `hunter/log.txt` | NE | Vytvoří se sám prvním zápisem (`>>`). |
| `<SD>/snaps.lnk` (kořen karty) | NE | Windows zástupce, na Linuxu neaktivní, Hunter na něj nikde neodkazuje (cesta ke snímkům je natvrdo `/tmp/mnt/sdcard/snaps`). **Klidně smazat.** |

### Obnova po naformátování karty

**Nestačí zkopírovat zpátky jen `hunter/`.** Minimální sada pro plně
funkční obnovu:

1. `/ubia_test` do kořene karty (ze zálohy, nebo `sdcard-root/ubia_test`
   z repozitáře).
2. Celá `hunter/` (ze zálohy živé karty, ne z gitu — git verzuje jen
   `config.txt.example`, ne skutečný `config.txt`/`smtp.pass`/
   `mail.token`, protože jsou to secrets).
3. `state/` kopírovat **doporučeno, ne povinné** — bez něj Hunter
   znovu odešle všechny fotky, co kdy na kartě byly (viz sekce 5,
   "oba smazané zároveň").
4. Formátování samo smaže i vendor data (`ubia_record.db`, `snaps/`,
   `HDPIC/`) — to je mimo Hunterovu odpovědnost, řeší to `ubia_first`
   při dalším probuzení sám.

## 5. Stavové soubory — inventář a obnova

Všechny soubory v `hunter/state/` sdílí stejný vzor: **čtení je vždy
chráněné `[ -f soubor ]`** (chybějící = bezpečná výchozí hodnota),
**zápis je vždy `>>` (append)**, který soubor vytvoří sám, pokud
neexistuje. Nic v `hunter/state/` tedy nemusí existovat předem.

| Soubor | Co obsahuje | Když chybí/je smazán |
|---|---|---|
| `cursor.txt` | Den (YYMMDD), od kterého se hledají noví kandidáti | Bere se jako "od nejstaršího dne na kartě". Neškodné samo o sobě — `sent_list.txt` pořád funguje jako filtr, jen se o trochu prodlouží sken (viz sekce 10, "nejhorší případ"). |
| `sent_list.txt` | Cesty ke všem automaticky odeslaným fotkám (cesty ze `snaps/`, kanonická identita) | Příští odeslaná fotka soubor znovu vytvoří, ale do té doby **Hunter neví, co už poslal** — znovu pošle všechny fotky od aktuálního dne cursoru dál. Duplicitní odeslání, ne pád. |
| **Oba výše zároveň** | — | **Nejhorší případ:** rescan od nejstaršího dne + prázdný filtr → **znovu se pošlou úplně všechny fotky, co kdy na kartě byly**, postupně po dávkách `MAX_SEND_PER_WAKE`. |
| `mail_seen.txt` | UID e-mailů, které už byly vykonány jako příkaz | Už vykonaný příkaz vypadá jako nový → **může se vykonat podruhé** (přijde druhá odpověď, případně druhé `WIPE` apod.). |
| `sms_seen.txt` | Totéž pro SMS | Neškodné v praxi — SMS kanál je mrtvý kód (viz sekce 2). |
| `wipe_pending.txt` | Adresa toho, kdo si vyžádal `WIPE`, dokud mazání běží přes víc probuzení | Rozdělané mazání se **zastaví** — zbylé záznamy prostě zůstanou v `sent_list.txt`. Nic se neztratí, jen se nedomaže; stačí poslat `WIPE CONFIRM` znovu. |
| `.lock/` (adresář) | `pid` běžícího `hunter.sh` | Neškodné — `acquire_lock()` si adresář sám vytvoří přes `mkdir`. Podrobně o zotavení ze zaseklého zámku viz sekce 9. |

**Praktický důsledek:** smazání jednotlivých souborů ve `state/` nikdy
neshodí Hunter, jen v horším případě (oba klíčové soubory najednou)
způsobí jednorázové znovuodeslání celé historie fotek. Bezpečné
"tvrdé reset" gesto je tedy smazat celé `state/` — Hunter se z toho
vždy zotaví, jen s cenou duplicitních e-mailů.

## 6. Konfigurace — kompletní referenční tabulka

Zdroj pravdy: [`hunter/config.txt.example`](../hunter/config.txt.example)
(okomentovaný). Tahle tabulka je stručný přehled, ne náhrada čtení
komentářů tam — každý klíč má v `.example` souboru vysvětlené PROČ.

| Klíč | Výchozí | Účel |
|---|---|---|
| `MASTERS` | — | Autorizovaná telefonní čísla pro SMS příkazy (mrtvý kanál, viz sekce 2) |
| `QUALITY` | `HD` | Jen se ukládá/vrací v odpovědi — skutečné překódování JPEGu **není implementováno** |
| `CONFIRM` | `ON` | Potvrzovací SMS na každý vykonaný příkaz (týká se mrtvého SMS kanálu) |
| `SMTP_HOST`, `SMTP_PORT` | — | Povinné jen když `SEND_TRANSPORT` může použít SMTP (`smtp`, `smtp-imap`, `imap-smtp`, `smtp+imap`) |
| `SMTP_USER` | — | **Vždy povinné** — i v čistém `imap` režimu je to IMAP login a `From:` uložené zprávy |
| `SMTP_TO` | — | **Vždy povinné** — `To:` hlavička uložené i odeslané zprávy |
| `SMTP_TLS` | `starttls` | `starttls` (587/25) / `implicit` (465) / `none` (jen test) |
| `IMAP_HOST`, `IMAP_PORT` | — / `993` | Příkazový kanál i IMAP transport fotek/odpovědí/chyb |
| `CA_FILE` | prázdné | Ověření certifikátu SMTP/IMAP. Prázdné = šifrováno, ale identita serveru se NEOVĚŘUJE |
| `SEND_TRANSPORT` | `smtp` | `smtp` / `imap` / `smtp-imap` / `imap-smtp` / `smtp+imap` — kudy jdou fotky a odpovědi. Příjem příkazů vždy přes IMAP, bez ohledu na tuto hodnotu |
| `IMAP_SAVE_FOLDER` | `Fotopast` | Kam se ukládají fotky přes IMAP APPEND. Nesmí být `INBOX` |
| `IMAP_REPLY_FOLDER` | prázdné (= jako fotky) | Kam se ukládají odpovědi na příkazy, nezávisle na fotkách. Nesmí být `INBOX` |
| `IMAP_ERROR_FOLDER` | prázdné (= vypnuto) | Kam se ukládají chybová hlášení (`log_error`), nezávisle na `SEND_TRANSPORT`. Bez limitu na počet. Nesmí být `INBOX` |
| `MAIL_MASTERS` | — | Autorizované e-mailové adresy (malými písmeny) |
| `AUTH_TYPE` | `TOKEN` | `TOKEN` (token + odesílatel) / `SENDER` (jen odesílatel — `From:` je podvrhnutelná!) |
| `REQUEST_MAX` | `5` | Strop počtu fotek na jedno vyžádání (`LAST`/`DATE`/`GET`) |
| `MAX_QUEUE` | `100` | Strop velikosti nedodělku, `0` = bez omezení. Přes strop se nejstarší přeskočí (zapíše do `sent_list.txt`) |
| `WIPE_BATCH` | `500` | Kolik záznamů smaže `WIPE CONFIRM` za jedno spuštění (viz sekce 10) |
| `AT_PORT`, `AT_BAUD` | `/dev/ttyUSB2` / `115200` | Modemový AT port — ověřit při výměně modulu/desky |
| `SNAP_WAIT` | `25` | Vteřin čekání na nový snímek z aktuálního probuzení |
| `MAX_SEND_PER_WAKE` | `8` | Strop fotek na jedno probuzení (ochrana baterie). Vždy ≥ `REQUEST_MAX` (vynuceno) |
| `RUN_DEADLINE` | `180` | Tvrdý strop celého běhu `hunter.sh` ve vteřinách |

## 7. E-mailové příkazy — kompletní referenční tabulka

Podrobný popis a bezpečnostní poznámky viz
[README.md, sekce "Příkazový kanál"](../hunter/README.md). Tvar
předmětu: `HUNTER <token> <příkaz> [argumenty]`.

| Příkaz | Co dělá | Token vždy? |
|---|---|---|
| `STATUS` | Baterie/signál/místo/fronta | ne |
| `LAST <N>` | N nejnovějších fotek (obchází cursor i `sent_list.txt`) | ne |
| `DATE <YYMMDD>` | Fotky z daného dne | ne |
| `GET <jméno>` | Konkrétní soubor | ne |
| `QUALITY HD\|LOW` | Nastaví kvalitu (jen se ukládá, viz sekce 6) | ne |
| `CONFIRM ON\|OFF` | Potvrzovací odpovědi (SMS kanál) | ne |
| `WIPE` / `WIPE CONFIRM` | Smaže už odeslané fotky, dávkováno po `WIPE_BATCH`. Jedno potvrzení stačí — zbytek se domaže sám při dalších probuzeních, na konci přijde `WIPE DONE` | ne |
| `CLEAR QUEUE` | Vyprázdní frontu VČETNĚ trvale vadných souborů (nemaže je z karty) | ne |
| `LIST CMD` | Výpis dostupných příkazů podle `AUTH_TYPE` | ne |
| `ADD <tel\|mail>` | Přidá oprávněného | **ano** |
| `REMOVE <tel\|mail>` | Odebere oprávněného | **ano** |
| `ADD TOKEN <nový>` | Přidá token | **ano** |
| `REMOVE TOKEN <token>` | Odebere token | **ano** |
| `AUTH TYPE TOKEN\|SENDER` | Změna režimu autorizace | **ano** |
| `FOTO` | Nepodporováno (návrhový záměr, ne chybějící implementace) | — |

**Dávkovaný `WIPE`** je nový od 2026-09-23 (viz sekce 10). Při velkém
`sent_list.txt` odpoví `WIPE CONFIRM` hláškou `WIPE STARTED (N photos,
M zbyva, pokracuji sam)` a zbytek se domazává **automaticky po jedné
dávce za probuzení**, vždy až po odeslání fotek. Až je hotovo, přijde
`WIPE DONE` na adresu toho, kdo si o `WIPE` řekl. Rozdělané mazání drží
`state/wipe_pending.txt` (viz sekce 5).

## 8. IMAP transport a tři oddělené složky

`SEND_TRANSPORT` (sekce 6) řídí, kudy jdou fotky a odpovědi na příkazy
— **nikdy příjem příkazů**, ten jde vždy přes IMAP `SEARCH UNSEEN` na
`INBOX`. Tři nezávislé cílové složky pro IMAP APPEND:

| Proměnná | Co tam padá | Výchozí |
|---|---|---|
| `IMAP_SAVE_FOLDER` | Fotky | `Fotopast` |
| `IMAP_REPLY_FOLDER` | Odpovědi na příkazy | stejná jako fotky |
| `IMAP_ERROR_FOLDER` | Chybová hlášení (`log_error`, nezávisle na `SEND_TRANSPORT`) | vypnuto |

Proč tohle existuje: přímé odesílání SMTP z mobilní SIM vypadá pro
operátora jako spam bot — O2 kvůli tomu jednou zablokoval celou SIM
(data i volání). IMAP APPEND je totéž spojení na portu 993, jaké
zařízení stejně dělá kvůli příkazům — operátor nemá co chytit.

Všechny tři složky sdílí stejnou pojistku: **nesmí být `INBOX`** (kvůli
kolizi s `SEARCH UNSEEN`). `IMAP_SAVE_FOLDER`/`IMAP_REPLY_FOLDER` při
porušení spadnou na `Fotopast`; `IMAP_ERROR_FOLDER` se v tom případě
prostě vypne (není kam bezpečně spadnout u funkce, co je stejně
vypnutá ve výchozím stavu).

## 9. Zámek a watchdog

**Zámek** (`state/.lock/`, `acquire_lock`/`release_lock` v
`common.sh`): chrání proti dvěma souběžným `hunter.sh`. Zařízení nemá
zálohovanou RTC a **pidy se recyklují od nízkých čísel po každém
restartu** — proto `lock_owner_alive()` nekontroluje jen "běží ten
pid", ale i "patří `hunter.sh`" (přes `/proc/<pid>/cmdline`) a
speciálně odmítá pid `0` a vlastní pid (`$$`) jako vždy-zbytkové.
Historie: 2026-09-01 zůstal po `SIGKILL` na kartě zámek s pidem, který
po restartu dostal systémový proces — `kill -0` uspělo a Hunter dva dny
jen hlásil "jiná instance už běží". Od opravy (2026-09-08) zámek
funguje spolehlivě v provozu (desítky převzetí zaseklého zámku, žádný
trvalý deadlock).

**Watchdog** (`hunter.sh`, `deadline_kill_tools`): po `RUN_DEADLINE`
(výchozí 180 s) nejdřív pošle `SIGTERM` síťovým nástrojům
(`mailrecv`/`mailsend`/`atcmd`/`smssend`/`smsrecv`), pak hlavnímu
procesu, po 5 s `SIGKILL`. Důvod dvoufázovosti: POSIX shell zaseklý v
příkazové substituci (`$(mailrecv_run ...)`) **odkládá** `SIGTERM`,
dokud dítě neskončí — zabitím dítěte se shell odblokuje a `trap`
proběhne normálně. Bez tohohle kroku skončilo 2026-09-06 osmnáct běhů
za sebou zaseklých s zmraženou `ubia_first` a zámkem na kartě.

**Vnější tvrdé restarty** (mimo Hunterovu kontrolu): pozorováno
2026-09-21 — vendor `ubia_first` se zasekl ve vlastní sleep-preprocessing
proceduře (`ubia_sleep_preproc_ex`, "last time sleep preproc don't end")
a restartoval zařízení každých 30-100 s po dobu 9 minut. Zámek se
choval správně (poctivě přebíral zastaralé zámky), ale žádný běh
nemohl dokončit, dokud se vendor sám nezotavil. Diagnostikovatelné
čistě z `hunter/log.txt` + vendor `logfile.txt` staženými z karty, bez
potřeby UART.

## 10. Výkon a známé limity

Zátěžový test 2026-09-22/23 (`tests/stress_5000.sh`, ruční, mimo běžnou
sadu) — 5000 souborů ve `snaps/` napříč 100 dny, všech 5000 v
`sent_list.txt`. Běží na PC pod `dash`, ne na reálném MIPS busybox
`ash` — čísla jsou tedy **algoritmický** signál (roste to lineárně?
kvadraticky?), ne přesná predikce pro zařízení.

| Scénář | Výsledek |
|---|---|
| Běžný provoz (cursor u posledního dne, 1 nový kandidát) | 146 ms |
| Cursor uvízlý u nejstaršího dne (sken všech 100 dnů) | 4,6 s |
| Největší jedna proměnná v paměti (`_slice`, 50 záznamů/den) | 3 kB — žádné riziko RAM |
| `WIPE CONFIRM` na 5000 záznamech, PŘED opravou | **98,7 s** — blízko `RUN_DEADLINE=180s` |
| `WIPE CONFIRM` na 5000 záznamech, PO opravě (dávkování) | 10 kol × ~10 s (`WIPE_BATCH=500`) |

**Zjištění a oprava:** `wipe_sent_snaps()` čte celý `sent_list.txt`
řádek po řádku (paměťově bezpečné), ale u velkého souboru to trvá
dlouho kvůli forkování (`rm`/`printf` na řádek). Riziko: karta plná
starého odeslaného obsahu = největší `sent_list.txt` = nejpomalejší
`WIPE` — tedy přesně ve chvíli, kdy je `WIPE` nejvíc potřeba. Opraveno
2026-09-23 přidáním `WIPE_BATCH` (sekce 6) — `WIPE CONFIRM` teď
zpracuje nejvýš `WIPE_BATCH` záznamů za jedno probuzení a zbytek si
Hunter odbaví sám při dalších, dokud nedomaže všechno.

`list_unsent_snaps`/`day_fully_sent` (hledání kandidátů) jsou naopak
**cursor-bounded** — `fgrep` proti `sent_list.txt` běží jen na dnech od
cursoru dál, ne na celé historii, takže běžný provoz neroste s
celkovým počtem fotek na kartě, jen s tím, co přibylo od posledního
probuzení. Výjimka: `list_snap_days()` samo o sobě **enumeruje**
(levně, jen jména adresářů) úplně všechny dny, i ty starší než cursor
— při stovkách dnů zanedbatelné, při řádově vyšších počtech potenciální
místo k dalšímu zrychlení, kdyby to bylo potřeba (zatím není — YAGNI).

## 11. Testování

```sh
# jeden test
dash tests/test_lock.sh

# cela bezna sada (rychle, sekundy az nizke desitky sekund)
for f in tests/test_*.sh; do dash "$f"; done

# rucni zatezovy test (NENI v bezne sade, ~2.5 minuty)
dash tests/stress_5000.sh
```

Sada `tests/test_*.sh` (dash, POSIX) pokrývá: zámek (`test_lock.sh`),
watchdog/deadline (`test_deadline.sh`), frontu a cursor
(`test_queue_wake.sh`), transport a IMAP složky (`test_transport.sh`),
chybová hlášení (`test_log_error.sh`), privilegované příkazy včetně
`WIPE`/`WIPE_BATCH` (`test_privileged.sh`), a další (`tests/`
adresář, `assert.sh`/`fixture.sh` jako společná infrastruktura). C
binárky mají vlastní testy v `test_files/` (kompilují a spouští se na
Raspberry Pi).

## 12. Provozní postupy

**Nasazení od nuly, den-za-dnem checklist:** viz
[README.md](../hunter/README.md), sekce "Postup nasazení" a celý
[CHECKLIST.md](../CHECKLIST.md).

**Bezpečná práce s kartou za provozu:**
```sh
sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600   # zastaví ubia_first
# ... vytáhnout kartu, upravit, vrátit ...
sh /tmp/mnt/sdcard/hunter/dev-resume.sh     # vrátí do provozu
```

**Sledování živého provozu:** UART (`uartlog`, viz CHECKLIST) NENÍ pro
běžnou práci potřeba — postačí stažené `hunter/log.txt` +
`logfile.txt` (vendor ULOG, cirkulární 4 MB buffer, binární formát,
čti přes `grep -a`) po vytažení karty. Vendor log je v **lokálním
čase**, Hunterův log v **UTC** (offset +2 h pozorováno 2026-09) — při
korelaci časů to nezapomeň přepočítat.

**Diagnostika bez fyzického přístupu:** většinu problémů (včetně
zaseklého zámku a vendor reboot-smyček, viz sekce 9) jde rozklíčovat
čistě z `hunter/log.txt` + `logfile.txt` staženými z karty. UART/USB-C
nejsou potřeba pro běžnou diagnostiku — USB-C port na tomhle
konkrétním kusu hardwaru navíc **nevede datové piny** (ověřeno
2026-09-22: PC ho při připojení vůbec nerozpozná jako zařízení), takže
přes něj žádný náhradní protokol postavit nejde.

**Bezpečnostně citlivé soubory** (nikdy nečíst/necitovat/nelogovat
jejich obsah): `hunter/smtp.pass`, `hunter/mail.token`, cokoli
odpovídající vzoru `*.pass`/`*pass*.txt` v repozitáři. Token v
předmětu příkazového e-mailu se z bezpečnostních důvodů také nikdy
necituje zpátky v odpovědi (`send_reply_mail`, `mail.sh`).
