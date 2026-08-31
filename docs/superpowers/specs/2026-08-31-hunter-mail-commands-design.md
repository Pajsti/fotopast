# Hunter — e-mailové příkazy (návrh)

Datum: 2026-08-31

Navazuje na [2026-08-27-hunter-design.md](2026-08-27-hunter-design.md).
Ten popisuje Hunter jako celek; tenhle dokument řeší **jeden nový
subsystém — příchozí příkazový kanál přes e-mail** — a nahrazuje SMS
příkazy, které na tomto hardwaru prokazatelně nejdou (viz sekce 7.6
původního specu).

## 1. Proč e-mail a co od něj čekat

SMS jako příkazový kanál je na tomto modemu mrtvý — `AT+CLAC` prokázal,
že SMS příkazy ve firmwaru modulu vůbec nejsou. E-mail ten kanál
obnovuje a nepotřebuje k tomu žádnou novou infrastrukturu: účet už kvůli
odesílání fotek máme, TLS/TCP/DNS vrstva je hotová a odzkoušená
v `mailsend`.

**Latence je stejná, jakou měly mít SMS:** příkazy se zpracují při
každém přirozeném probuzení. Zařízení kvůli nim **nelze probudit** — to
bylo samostatně prošetřeno a je to slepá ulička:

> Do SoC vedou jen dva zdroje probuzení: PIR a síťové probuzení přes
> modul (`get4gWakeUpFromMcu`), které řídí keepalive na wowservery
> výrobce. Sada příkazů, kterou hostitel umí poslat MCU
> (`PowerOffWithPir`, `SHUT_DOWN`, `RESET_HOST`, `PIR_OP`,
> `SET_PirInterval`, `SetPirPower`, `4G_Reset`, `DTR_Set`,
> `RegOn_Control`, `Led_Control`), **neobsahuje žádný časovaný budík** a
> firmware nemá ani pracovní režim s periodickým probouzením. IP
> wowserverů se načítají podle `vpgindex` z párovacích dat cloudu a
> protokol běží v uzavřeném firmwaru modulu — přesměrovat si je k sobě
> by znamenalo rozbít párování a reverzovat proprietární protokol.

Ruční probuzení jde přes aplikaci výrobce (živý náhled zařízení
probudí), takže „pošli příkaz mailem, otevři appku" funguje jako
obezlička bez další práce.

## 2. Architektura

Jeden **transportně nezávislý vykonavač**, dva transporty, které do něj
ústí. Dnes je vykonavač schovaný uvnitř `sms.sh`, přestože o SMS nic
neví — vytáhne se, aby ta hranice byla vidět:

```
hunter/lib/command.sh   vykonavač: execute_command(), slovník, wipe
hunter/lib/sms.sh       už jen process_sms()      (transport SMS)
hunter/lib/mailcmd.sh   process_mail()            (transport e-mail, nový)
```

Na straně C přibude `bin/mailrecv` — IMAP klient ve stejném tvaru jako
`smsrecv`, se stejným line-based rozhraním:

```
mailrecv <host> <port> <user> --pass-file <f> list unseen
mailrecv <host> <port> <user> --pass-file <f> seen <uid>

výstup:  MSG|<uid>|<odesílatel>|<předmět>
```

Předmět je schválně **poslední pole** — může obsahovat `|` a shell ho
posbírá stejným trikem (`shift 3; subject="$*"`), jaký `process_sms` už
používá na tělo SMS.

### 2.1 Sdílená síťová vrstva `tlsnet`

`mailsend.c` v sobě nese vlastní DNS resolver, TCP connect a obsluhu TLS
— ~250 řádků, které by `mailrecv` potřeboval taky. Vytáhnou se do
sdíleného `tlsnet.c/h`, přesně jako se to už jednou udělalo
s `atport.c/h` pro AT nástroje.

Přesun je čistě mechanický, žádná změna logiky. **Akceptační podmínka:
po refaktoru musí `mailsend` pořád reálně doručit e-mail** — což je test,
který 2026-08-31 jednou úspěšně proběhl. Alternativa (zduplikovat
resolver) by znamenala dvě kopie ručního skládání DNS paketů.

### 2.2 Proč jen hlavičky

Celý příkaz se nese **v předmětu**, takže `mailrecv` nikdy nestahuje těla
zpráv — stačí `BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)]`. Odpadá tím
parsování MIME, dekódování přenosových kódování i přílohy. Je to řádový
rozdíl ve složitosti klienta.

Potřebná podmnožina IMAPu je proto malá: `LOGIN`, `SELECT INBOX`,
`UID SEARCH UNSEEN`, `UID FETCH`, `UID STORE +FLAGS (\Seen)`, `LOGOUT`.
Implicitní TLS na portu 993 (žádný STARTTLS).

### 2.3 Proč IMAP a ne POP3

POP3 je protokolově zhruba poloviční, ale nezná serverové příznaky
„přečteno" a mazání se potvrzuje až v `QUIT`. Na zařízení, kterému může
kdykoli zmizet napájení, je to nepříjemná sémantika: příkaz vykonán,
spojení spadne, zpráva se vrátí a vykoná se podruhé. IMAP navíc dává
**stabilní UID**, což je přesně ten dedup klíč, který kvůli výpadkům
potřebujeme.

## 3. Příkazový jazyk

### 3.1 Tvar předmětu

```
HUNTER <token> <příkaz> [argumenty]
```

Prefix `HUNTER ` není jen syntaxe, je to **filtr, čeho se Hunter smí
dotknout**. Čte stejnou schránku, ze které odesílá, takže tam chodí i
nedoručenky a běžná pošta. Pravidlo je tvrdé:

> **Zpráva bez prefixu `HUNTER ` se ignoruje a NIKDY se neoznačí jako
> přečtená.** Hunter nesmí sahat na cizí poštu ve schránce.

### 3.2 Slovník

```
STATUS                    stavový řádek (+ TOKENS:<počet>)
LAST <N>                  N nejnovějších fotek
DATE <YYMMDD>             fotky z daného dne
GET <jméno>               konkrétní soubor
QUALITY HD|LOW            kvalita odesílaných fotek
CONFIRM ON|OFF            potvrzovací odpovědi
WIPE CONFIRM              smaže odeslané fotky (bez "CONFIRM" se nevykoná)
LIST CMD                  výpis příkazů
ADD <telefon|e-mail>      ─┐
REMOVE <telefon|e-mail>    │
ADD TOKEN <nový>           ├─ vždy vyžadují token (viz 3.3)
REMOVE TOKEN <token>       │
AUTH TYPE TOKEN|SENDER    ─┘
FOTO                      pořád NOT SUPPORTED (spec 7.4)
```

`ADD`/`REMOVE` rozliší typ argumentu podle tvaru: `+420…` → `MASTERS`
(telefony), cokoli s `@` → `MAIL_MASTERS`, literál `TOKEN` jako druhé
slovo → správa tokenů. Tvary se nemohou splést.

Parsování je case-insensitive přes `case` patterny se znakovými třídami
(`[Ss][Tt]…`), **ne** přes `tr '[:lower:]' '[:upper:]'` — `FEATURE_TR_CLASSES`
je v busyboxu volitelný a tenhle firmware je hodně oříznutý. Stejný důvod
jako v původním `sms.sh`.

### 3.3 Autorizace

Token leží v `hunter/mail.token` vedle `smtp.pass` (obojí v `.gitignore`).
Soubor je **víceřádkový, jeden token na řádek** — každý člověk má vlastní
token, takže odvolání jednoho neznamená měnit token všem. Všechny tokeny
mají stejné oprávnění.

| Režim (`AUTH_TYPE`) | Podmínka pro vykonání |
|---|---|
| `TOKEN` (výchozí) | platný token **a** odesílatel v `MAIL_MASTERS` |
| `SENDER` | jen odesílatel v `MAIL_MASTERS` |

Nad tím jedno pravidlo platné **vždy, bez ohledu na režim**:

> **Příkazy měnící oprávnění — `AUTH TYPE`, `ADD`, `REMOVE`,
> `ADD TOKEN`, `REMOVE TOKEN` — vyžadují platný token i v režimu
> `SENDER`.**

Tím je zaručené, že se z oslabeného režimu jde vždycky vrátit a že si
podvržený mail nemůže sám přidat trvalý přístup.

**Co je potřeba říct otevřeně:**

- Hlavička `From` jde triviálně podvrhnout. V režimu `SENDER` je proto
  `WIPE` dosažitelný pro kohokoli, kdo zná dvě e-mailové adresy. Je to
  vlastní cena toho režimu, ne chyba návrhu — proto je výchozí `TOKEN`.
- Token je **nositelské heslo v nešifrovaném kanálu**. Uvidí ho každý,
  kdo se dostane do schránky nebo komu se mail přepošle. Proto se token
  nikdy nezaloguje a odpovědi **nikdy necitují příchozí předmět**.
- `ADD TOKEN` nese nový token v předmětu, takže po odeslání leží
  v čitelné podobě ve **dvou** schránkách. Rozdávání tokenů e-mailem to
  má v povaze.
- **Každý token může odvolat kterýkoli jiný, včetně tvého.** Přímý
  důsledek rovných oprávnění; vědomé rozhodnutí.

**Pojistky u tokenů:**

- Nový token musí mít **aspoň 8 znaků a žádnou mezeru** (mezera by
  rozbila parsování předmětu). Přidání existujícího je no-op.
- **Poslední token nelze odebrat.** Jinak by se zařízení v režimu
  `TOKEN` stalo neovladatelným na dálku a jedinou cestou zpět by byl
  fyzický přístup ke kartě.
- Chybějící nebo prázdný `mail.token` v režimu `TOKEN` znamená
  **fail closed** — nevykoná se nic.

### 3.4 `LIST CMD`

Výpis **odráží aktuálně aktivní režim**, takže ukazuje přesně to, co je
právě teď potřeba napsat. Hodnota tokenu se nikdy nevypisuje, jen `<token>`
jako zástupný symbol. Bez diakritiky, stejně jako zbytek zařízení.

```
HUNTER commands (auth mode: TOKEN)

HUNTER <token> STATUS                  stav: baterie/signal/misto
HUNTER <token> LAST <N>                N nejnovejsich fotek
HUNTER <token> DATE <YYMMDD>           fotky z daneho dne
HUNTER <token> GET <jmeno>             konkretni soubor
HUNTER <token> QUALITY HD|LOW          kvalita odesilanych fotek
HUNTER <token> CONFIRM ON|OFF          potvrzovaci odpovedi
HUNTER <token> WIPE CONFIRM            smaze jiz odeslane fotky
HUNTER <token> LIST CMD                tento vypis
HUNTER <token> ADD <tel|mail>          pridat opravneneho   [vzdy token]
HUNTER <token> REMOVE <tel|mail>       odebrat opravneneho  [vzdy token]
HUNTER <token> ADD TOKEN <novy>        pridat token         [vzdy token]
HUNTER <token> REMOVE TOKEN <token>    odebrat token        [vzdy token]
HUNTER <token> AUTH TYPE TOKEN|SENDER  zmena rezimu         [vzdy token]
HUNTER <token> FOTO                    nepodporovano

<token> = kterykoli z tokenu v hunter/mail.token (nikdy se nevypisuje)
```

V režimu `SENDER` zmizí `<token>` u běžných příkazů; u pěti označených
`[vzdy token]` zůstává.

**Známé omezení:** výpis má ~14 řádků — pro e-mail nic, přes SMS by to
byla spousta segmentů. Vykonavač je schválně transportně nezávislý a SMS
na tomto hardwaru nefungují, takže se kvůli mrtvé cestě rozlišování
transportu nezavádí. Kdyby SMS ožily, je to přidání jedné podmínky.

### 3.5 Vyžádání fotek

Vyžádané fotky **obcházejí `sent_list.txt`** — přeposlat už jednou
odeslanou fotku je celý smysl věci. Sbírají se do `REQUESTED_SNAPS`
a odesílají stejnou cestou (`send_snap`) jako automatické, včetně
respektování `QUALITY` (HD → varianta z `HDPIC/`).

Strop je vlastní **`REQUEST_MAX` (výchozí 5)**, oddělený od automatického
`MAX_SEND_PER_WAKE` — o vyžádané fotky si uživatel řekl výslovně. Při
překročení se pošle strop a odpověď to řekne.

`GET` přijímá **jen holý název souboru**; cokoli obsahující `/` nebo `..`
se odmítne, aby se přes něj nedalo sáhnout mimo `snaps/`.

### 3.6 Odpovědi

Chodí e-mailem zpět odesílateli, když `CONFIRM=ON`, s vlastním předmětem
`HUNTER reply`. Příchozí předmět se **nikdy** necituje (je v něm token).

Neautorizovaná zpráva se zaloguje (bez tokenu), označí jako přečtená a
**odpověď se neposílá** — cizímu nepotvrzujeme, že tu něco existuje.
Stejný princip jako u SMS. Neznámý příkaz od autorizovaného odesílatele
dostane `UNKNOWN CMD`.

## 4. Tok jedním probuzením

```
 1. zámek, trap cleanup, deadline
 2. touch /tmp/stopWdg
 3. wait_for_at_port + sync_clock_from_modem
 4. process_sms         (stávající; na tomto HW tiše no-op)
                        → ensure_app_frozen, až když má co vykonat
 5. process_mail        ← NOVÉ
                        → ensure_app_frozen, až když má co vykonat
 6. wait_for_candidates (automatické nové snímky)
 7. sloučit kandidáty + REQUESTED_SNAPS
 8. je-li co poslat:    → ensure_app_frozen, pak odeslat
 9. cleanup: SIGCONT (když bylo zmrazeno) + rm stopWdg
```

`ensure_app_frozen()` je idempotentní, takže tři volací místa zmrazí
aplikaci dohromady nejvýš jednou.

`process_mail` běží **před** `wait_for_candidates`, aby se vyžádané fotky
připojily do stejné dávky a mrazilo se jen jednou.

### 4.1 `ensure_app_frozen()` — změna oproti stávajícímu chování

Dnes se `ubia_first` mrazí **jen** v fotkové větvi. To je díra: zpracování
příkazů (IMAP + odeslání odpovědi) taky trvá desítky sekund a taky
potřebuje zařízení naživu — a `process_sms` dnes běží nezmrazený úplně
stejně.

Zavádí se `ensure_app_frozen()`: idempotentní, zmrazí nejvýš jednou,
nastaví `STOPPED_APP=1`. Volá ji **jak příkazová, tak fotková větev**,
vždy až ve chvíli, kdy je jisté, že je co dělat. `cleanup()` odmrazí.

Tím se získá obojí: příkazy jsou chráněné stejně jako odesílání fotek, a
zároveň se nemrazí zbytečně při probuzení, kdy není co dělat.

`process_mail` proto nejdřív zavolá `mailrecv list unseen` (rychlé, bez
mrazení) a `ensure_app_frozen` volá teprve tehdy, když v seznamu opravdu
je zpráva s prefixem `HUNTER `.

### 4.2 Deduplikace a výpadek napájení

`state/mail_seen.txt`, řádky ve tvaru `<uidvalidity>|<uid>`.
`UIDVALIDITY` je v klíči proto, že po (vzácném) znovuvytvoření schránky
UID přestanou být jedinečné.

Pořadí je stejné jako u SMS a je záměrné:

```
1. zapiš UID do mail_seen.txt   ← PŘED vykonáním
2. sync
3. vykonej příkaz
4. pošli odpověď (když CONFIRM=ON)
5. označ \Seen na serveru       ← AŽ PO vykonání
```

Když zařízení zhasne mezi 3 a 5, zpráva je na serveru pořád `\Unseen` a
příští probuzení ji uvidí znovu — ale `mail_seen.txt` už UID má, takže se
jen tiše označí jako přečtená **bez druhého vykonání**. U `WIPE` by
dvojí vykonání nevadilo, ale princip platí pro všechny příkazy stejně.

### 4.3 Chybové stavy

| Selhání | Chování |
|---|---|
| IMAP nedostupný (DNS/TCP/TLS) | zaloguj, pokračuj bez příkazů — fotky se pošlou normálně |
| `LOGIN` odmítnut | zaloguj, pokračuj bez příkazů |
| `mail.token` chybí/prázdný, režim `TOKEN` | fail closed: nevykoná se nic, zaloguj |
| odpověď se nepodaří odeslat | příkaz **je** vykonaný a označený `\Seen` — nevykonávat znovu, jen zalogovat |
| vyžádaná fotka neexistuje | odpověď `NOT FOUND`, zbytek dávky se pošle |
| `REQUEST_MAX` překročen | pošli strop, odpověď to řekne |
| předmět kódovaný RFC 2047 | prefix nesedí → zpráva se ignoruje (viz 3.4) |

Společný princip: **selhání příkazového kanálu nikdy nesmí shodit
odesílání fotek.** Fotky jsou primární funkce, příkazy druhotná.

## 5. Konfigurace

Nové klíče v `hunter/config.txt`:

```
IMAP_HOST=imap.seznam.cz
IMAP_PORT=993
MAIL_MASTERS=paja.stindl@seznam.cz
AUTH_TYPE=TOKEN
REQUEST_MAX=5
```

Přihlašovací jméno i heslo se sdílí s odesíláním (`SMTP_USER`,
`smtp.pass`) — je to tentýž účet. Token je zvlášť v `hunter/mail.token`.

`.gitignore` se rozšíří o `hunter/mail.token`.

## 6. Testování

Pořadí je zvolené tak, aby se nejlevnější a nejrizikovější věci ověřily
dřív, než se na nich začne stavět.

1. **Ověřit IMAP na Seznamu z Raspberry** (`openssl s_client -connect
   imap.seznam.cz:993`), ještě než vznikne řádek kódu. Potvrdí, že
   aplikační heslo přes IMAP projde, a dá reálné odpovědi serveru, proti
   kterým se dá psát parser.
2. **Extrakce `tlsnet`** — přeložit, znovu odeslat reálný e-mail. Musí
   dorazit; jinak se refaktor vrací zpět.
3. **`mailrecv` proti reálné schránce z Raspberry.** Je to obyčejný
   TCP/TLS klient, takže se přeloží i nativně pro aarch64 — vývoj
   protokolu tedy probíhá na Pi proti skutečnému serveru, ne na
   fotopasti. Tohle je hlavní úspora času.
4. **Shellové testy s podvrženým `mailrecv`** (stejný postup, jaký se
   osvědčil u `AT+CBC`/`AT+CCLK`: fake binárka v `PATH`, ověřuje se
   chování funkcí). Matice, kterou musí projít:

   | Situace | Očekávání |
   |---|---|
   | `TOKEN`: platný token + master | vykoná |
   | `TOKEN`: platný token + cizí odesílatel | odmítne, bez odpovědi |
   | `TOKEN`: špatný token + master | odmítne, bez odpovědi |
   | `SENDER`: bez tokenu + master | vykoná |
   | `SENDER`: bez tokenu + `ADD TOKEN` | odmítne (oprávnění chce token) |
   | `SENDER`: s tokenem + `AUTH TYPE TOKEN` | vykoná, režim se vrátí |
   | předmět bez prefixu `HUNTER ` | nedotčeno, **neoznačí se přečtené** |
   | `REMOVE TOKEN` posledního tokenu | odmítne |
   | `GET ../../etc/passwd` | odmítne |
   | `WIPE` bez `CONFIRM` | nevykoná |
   | výpadek mezi vykonáním a `\Seen` | podruhé se nevykoná |

5. **Nasazení a ostrý test** — poslat skutečný příkazový mail a ověřit
   odpověď i doručení vyžádaných fotek.

Přenos na kartu: `mailrecv` je binárka o stovkách kB, takže **fyzicky
přes čtečku**, ne přes UART heredoc (viz `pi-tools/README.md` — přes UART
se ztrácejí tabulátory a živé probuzení přenos rozbije).

## 7. Mimo rozsah

- **Probouzení zařízení e-mailem.** Prošetřeno, není cesta — viz sekce 1.
- Parsování těl zpráv a příloh (příkaz je vždy v předmětu).
- Dekódování RFC 2047 v předmětu.
- Rozlišení transportu ve vykonavači kvůli délce odpovědi (SMS jsou na
  tomto HW mrtvé).
- Oddělený „vlastnický" token s vyššími právy — všechny tokeny mají
  vědomě stejné oprávnění.
