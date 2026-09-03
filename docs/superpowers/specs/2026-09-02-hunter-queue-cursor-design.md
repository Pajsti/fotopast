# Hunter — fronta, cursor a škálování na tisíce fotek

Navazuje na [2026-08-27-hunter-design.md](2026-08-27-hunter-design.md)
(základ) a [2026-08-31-hunter-mail-commands-design.md](2026-08-31-hunter-mail-commands-design.md)
(příkazový kanál). Řeší, co se stane, až na kartě nebude pár set fotek,
ale několik tisíc — a přidává dva příkazy pro správu fronty.

## 1. Problém

Změřeno nad skutečným kódem, ne odhadem. Tři nezávislé body, které
neškálují:

### 1.1 Automatická detekce kandidátů

[hunter/lib/mail.sh:16-27](../../../hunter/lib/mail.sh#L16-L27):

```sh
find "$SDCARD/snaps" -type f -name '*.jpg' | while IFS= read -r f; do
    fgrep -qxF "$f" "$STATE_DIR/sent_list.txt" ...
```

`find` vypíše **všechny** soubory (i ty tisíckrát odeslané) a pro každý
se spustí **nový proces** `fgrep`, který lineárně přečte celý
`sent_list.txt`. Při 5 000 fotkách to je ~5 000 forků na probuzení, a
platí se to i při probuzení, kdy nic nepřibylo.

### 1.2 `LAST N` — nejhorší z trojice

[hunter/lib/command.sh:280-304](../../../hunter/lib/command.sh#L280-L304)
hledá N-krát maximum přes celý strom, a každé porovnání forkuje 4×:

```sh
ad=$(snap_date_of "$1"); at=$(snap_time_of "$1")
bd=$(snap_date_of "$2"); bt=$(snap_time_of "$2")
```

Při 5 000 fotkách a `LAST 5` je to řádově **100 000 forků na jeden
příkaz** — přeteče `RUN_DEADLINE` (výchozí 180 s). Komentář v kódu
("pri REQUEST_MAX <= 5 a stovkach souboru je to zanedbatelne") platí,
ale jen pro ty stovky.

### 1.3 Neomezená fronta

Když se nedodělek nafoukne (dlouhá nepřítomnost signálu, vybitá
baterie), Hunter se ho snaží dohnat po `MAX_SEND_PER_WAKE` kusech
donekonečna. Neexistuje způsob, jak říct "tohle už neposílej".

## 2. Co se NEdělá a proč

Původní nápad byl přesouvat odeslané fotky do `sentHD/`/`sentSD/` a
tím zrychlit kontrolu ("soubor není v původní složce = vyřízený").
**Zamítnuto**, ze tří důvodů:

1. **Neřeší 1.2**, což je nejhorší bod. Vyžádané fotky mají záměrně
   dosáhnout i na už odeslané ([command.sh:218](../../../hunter/lib/command.sh#L218)),
   takže `LAST`/`GET` by musely prohledávat obě složky — žádné
   zrychlení.
2. **Nese neověřené riziko.** Sekce 11 základního specu má dodnes
   otevřený bod, jak `ubia_first` snese zmizení souborů, na které
   odkazuje `ubia_record.db`. Dnešní `WIPE` se `HDPIC/` proto nedotýká
   vůbec. Přesouvání by tenhle risk otevřelo naostro (výchozí
   `QUALITY=HD`), a vyžádalo si fyzický test na zařízení.
3. **Cursor (sekce 3) řeší 1.1 stejně dobře a levněji**, bez jediného
   přesunutého souboru.

Rozdělaný pokus o ověření (`hunter/spike_move_test/` na kartě, dva už
odeslané HD snímky) se zahazuje — soubory patří zpět do `HDPIC/`.

## 3. Cursor

Nový stavový soubor `state/cursor.txt`, jeden řádek `YYMMDD`:

> Dny **starší** než tenhle jsou vyřízené. Automatická větev se do nich
> už nikdy nepodívá.

### 3.1 Hledání kandidátů

```
vypiš složky dnů v snaps/           malý seznam, 1 položka na den
ponech jen dny >= cursor
pro každý takový den d:
    slice = fgrep "/snaps/$d/" sent_list.txt      JEDEN fork na den
    pro každý *.jpg v d:
        není-li v slice a projde-li snapready -> kandidát
```

Vedlejší, ale důležitý důsledek: složky dnů i soubory uvnitř se
procházejí **globem, ne `find`em**, takže výstup je nově
**chronologicky vzestupný**. Dnešní `find_ready_candidates` pořadí
negarantuje a říká to i v komentáři. `MAX_QUEUE` (sekce 6) na tuhle
vlastnost spoléhá, když odřezává "nejstarší" — musí být tedy krytá
testem, ne jen předpokládaná.

Druhý důsledek téhož přechodu na glob: strom `snaps/` musí být odteď
přesně **dvě úrovně** — `snaps/<YYMMDD>/*.jpg`, den je složka s názvem
přesně 6 číslic (`snap_num6`), soubory přímo v ní. Dřívější
`find "$SDCARD/snaps" -type f -name '*.jpg'` tenhle předpoklad vstřebával
implicitně (rekurze do libovolné hloubky); nový glob ho **vynucuje** —
cokoli hlouběji nebo ve složce s jiným názvem je pro
`find_ready_candidates` i `day_fully_sent` neviditelné, tedy nemůže ani
kandidovat, ani udržet svůj den otevřený. Praktické riziko je dnes nízké
(`send_snap`/`resolve_attach_path` ve stejném souboru už plochý tvar
předpokládají), ale jde nově o **tvrdý požadavek**, ne o náhodou
fungující vlastnost, kterou dřív absorboval `find`. Nekonzistentně:
`request_date`/`request_get`
([command.sh:335-352](../../../hunter/lib/command.sh#L335-L352)) pořád
používají rekurzivní `find` (viz 8.3, beze změny) — `DATE`/`GET` tedy
dosáhnou i na soubor, který automatická větev nikdy neuvidí.

Klíčová změna není jen zúžení množiny dnů, ale i **jeden `fgrep` na
den místo jednoho na soubor**. Porovnání proti načtenému slice se dělá
shellovým `case` (bez forku), na plnou shodu řádku:

```sh
case "$nl$slice$nl" in
    *"$nl$f$nl"*) continue ;;
esac
```

### 3.2 Kdy se cursor posune

Den `D` se uzavře, když platí obojí:

- každý `*.jpg` v `D` je v `sent_list.txt`, **a**
- existuje složka dne `E` taková, že `E > D`.

První podmínka se řídí **výhradně členstvím v `sent_list.txt`**, ne
kandidaturou. Soubor, který `snapready` odmítá (neúplný, poškozený),
tedy den drží otevřený — viz omezení 9.3. Je to schválně: "neumím ho
poslat" není totéž co "je vyřízený".

Druhá podmínka je záměrně **strukturální, ne podle hodin**. Hodiny
zařízení nemají zálohovaný RTC a mezi probuzeními plavou (základní
spec 2.1), takže "dnešek" není spolehlivá informace. Do nejnovější
složky se pořád zapisuje — ta se nikdy neuzavře, takže rozepsaný nebo
`snapready`-neúplný snímek nemůže propadnout.

Porovnání dnů je **číselné** (`-gt`/`-lt` nad šestimístným číslem),
stejnou technikou jako `snap_newer` — `\>` uvnitř `[ ]` není v POSIXu
definované a busybox ho nemusí mít.

### 3.3 Kdy se posun provádí

**Jednou za probuzení, až po odeslání**, v hlavním toku `hunter.sh` —
ne uvnitř `find_ready_candidates()`. Ta se volá opakovaně z
`wait_for_candidates()` v pollovací smyčce a posouvat cursor v každém
kole by byla zbytečná práce. Posun až po odeslání navíc znamená, že
právě odeslané soubory se do uzavření svého dne započítají hned.

### 3.4 Chybějící cursor

Neexistující `state/cursor.txt` znamená "začni u nejstaršího dne, co je
na kartě" — první běh se tedy chová přesně jako dnešní kód a cursor se
pak posune sám. **Živé nasazení nevyžaduje žádný ruční migrační krok.**

## 4. `sent_list.txt` zůstává beze změny

Zvažovalo se ořezávat ho při posunu cursoru. **Nedělá se**: jakmile
zmizí fork na každý soubor (3.1), velikost souboru přestává hrát roli —
225 kB přečtených jednou za probuzení je nic.

Hlavní důvod je ale jiný: na `sent_list.txt` stojí `WIPE`
([command.sh:535-571](../../../hunter/lib/command.sh#L535-L571)).
Ořezáním by `WIPE` ztratil informaci, co smí smazat. Ponecháním celé
historie zůstává `WIPE` **beze změny** — což je u destruktivního
příkazu ta správná míra odvahy. `WIPE` si navíc `sent_list.txt` po
smazání sám přepisuje bez zaniklých záznamů, takže se dlouhodobě čistí.

## 5. `CLEAR QUEUE`

```
HUNTER <token> CLEAR QUEUE
```

Označí **celou aktuální frontu** za vyřízenou, aniž by ji odeslal —
**včetně souborů, které `snapready` trvale odmítá** (typicky nedopsaný
JPEG po výpadku napájení uprostřed zápisu). Soubory na kartě zůstávají.
Pak se provede posun cursoru (3.2), takže se dohánění nedodělku
zastaví — i pro den, který by jinak zůstal navždy otevřený (rozhodnutí
majitele projektu, 2026-09-03; podrobně viz sekce 9, bod 3).

- **Token není povinný** — příkaz nemění oprávnění, stejně jako `WIPE`.
  Zůstává tedy dostupný i v režimu `SENDER` (viz spec příkazů, 3.3).
- **Bez potvrzovacího slova.** `WIPE` vyžaduje `CONFIRM`, protože maže;
  `CLEAR QUEUE` soubory nechává.
- Odpověď: `QUEUE CLEARED`, **bez počtu**.
- **Přijaté riziko:** fotka, kterou aplikace zrovna dopisuje, `snapready`
  odmítá právě proto, že je rozepsaná — kód nerozliší "rozepsaná" od
  "trvale vadná". `CLEAR QUEUE` ji tedy může označit za vyřízenou, aniž
  kdy dorazí. Vědomé rozhodnutí majitele projektu (2026-09-03): příkaz
  se posílá vědomě a dnešní stav (den zaseklý navždy) je horší.

Proč bez počtu: příkaz sám jen nastaví příznak, skutečné přeskočení
provede `hunter.sh` **až po zpracování všech příkazů**. Musí to tak být
kvůli invariantu 7.1 — `REQUESTED_SNAPS` je konečný teprve, když
doběhnou všechny příkazy daného probuzení. Kdyby v jedné dávce přišel
`CLEAR QUEUE` dřív než `LAST 2`, přeskočil by fotku, kterou má `LAST`
teprve vyžádat. V okamžiku odesílání odpovědi tedy počet ještě není
znám; **loguje se** až při samotném přeskočení.

Implementačně: přeskočené cesty se připíší do `sent_list.txt` — viz
sekce 9, bod 1, včetně důsledku. Vyžádaných fotek se to nesmí dotknout
(sekce 7.1).

## 6. `MAX_QUEUE`

Nový klíč v `config.txt`, výchozí `100`.

Když počet čekajících kandidátů překročí strop, **nejstarší** se
označí za vyřízené (stejným mechanismem jako `CLEAR QUEUE`), dokud se
fronta nevejde pod strop. Bez zásahu uživatele.

Pořadí "nejstarší" je zadarmo — složky dnů se procházejí od nejstarší
a uvnitř dne je čas součástí názvu souboru (`HHMMSS_...`).

Vyhodnocuje se **jednou za probuzení**, po sestavení seznamu čekajících
a před odesíláním, v `hunter.sh` — ne uvnitř `find_ready_candidates()`,
ze stejného důvodu jako u 3.3.

Vztah k `MAX_SEND_PER_WAKE` (kolik se pošle za jedno probuzení) je
kolmý: `MAX_SEND_PER_WAKE` škrtí propustnost, `MAX_QUEUE` omezuje, jak
velký nedodělek má vůbec smysl držet.

## 7. Vyžádané fotky mají přednost

Čtvrtý bod zadání. Přednost **už funguje a je otestovaná** — tenhle
spec ji především nesmí rozbít.

Dnešní stav: vyžádané se před odesíláním předřadí automatickým
kandidátům ([hunter.sh:159-166](../../../hunter/hunter.sh#L159-L166)),
takže při vyčerpání `MAX_SEND_PER_WAKE` odpadnou automatické, ne
vyžádané. Před spojením se odstraní překryv
([hunter.sh:133-157](../../../hunter/hunter.sh#L133-L157)), aby se
tatáž fotka neposlala dvakrát. A vyžádané se **nezapisují** do
`sent_list.txt` ([hunter.sh:182-191](../../../hunter/hunter.sh#L182-L191))
— jinak by se prvním vyžádáním označily za odeslané a už by nikdy
neodešly automaticky. Pokrývají to scénáře B a C v
`tests/test_wake_send.sh`.

### 7.1 Nový invariant: přeskakování se vyžádaných nesmí dotknout

`CLEAR QUEUE` (sekce 5) ani `MAX_QUEUE` (sekce 6) **nesmí** označit za
vyřízenou fotku, která je v `REQUESTED_SNAPS` tohoto probuzení — ani ji
přeskočit, ani ji zapsat do `sent_list.txt`.

Důvod je konkrétní, ne teoretický: přeskočení zapisuje cestu do
`sent_list.txt` (sekce 9, bod 1). Kdyby tudy propadla vyžádaná fotka,
dostane se do `sent_list.txt` cestou, kterou `hunter.sh` záměrně
obchází — a tím **navždy** vypadne z automatického odesílání.

Prakticky: přeskakování pracuje výhradně nad automatickou množinou
kandidátů, a vyžádané z ní musí být vyňaty **dřív**, než se cokoli
zapíše — tedy před spojením obou množin.

Ochrana je záměrně zdvojená a obě poloviny jsou nosné, ne duplicitní.
Bloky `CLEAR QUEUE`/`MAX_QUEUE` v `hunter.sh` běží **před** odstraněním
překryvu s `REQUESTED_SNAPS` (to přichází až u sloučení množin, výše) —
`snap_list`, se kterým obě pracují, tedy v tu chvíli ještě může
obsahovat právě vyžádanou fotku. Jediné, co ji tam chrání, je vlastní
kontrola `REQUESTED_SNAPS` v `skip_snaps` (`lib/common.sh`) přímo v
místě zápisu do `sent_list.txt`. Mutační test potvrdil obě poloviny
zvlášť — odebrání kterékoli z nich pustí reálné selhání. Je to vědomé
"belt-and-braces" pro invariant, jehož porušení je tiché a trvalé (fotka
navždy vypadne z automatiky bez jakékoli chybové hlášky) — příští čtenář
ať jednu z těch dvou kontrol "nezjednoduší" pryč v domnění, že je
zbytečná.

## 8. Oprava `LAST N`

Dvě změny, obě uvnitř `snap_newer()` a `request_last()`. Dosah je
ověřený: `snap_date_of`/`snap_time_of` volá **jen** `snap_newer`, a ten
**jen** `request_last` — nic jiného v `hunter/` ani `tests/`.

### 8.1 Bez forků

`snap_newer` si datum a čas vytáhne parametrickou expanzí místo
`$(...)`:

```sh
sp=${1%/*}; ad=${sp##*/}
sb=${1##*/}; at=${sb%%_*}
```

0 forků na porovnání místo 4. Signatura funkce se nemění, takže
volající se nemění vůbec.

`snap_date_of`/`snap_time_of` zůstávají definované (jsou to čitelné
pojmenované operace), jen se nevolají v horké smyčce.

### 8.2 Předčasné ukončení

`request_last` půjde po složkách dnů **od nejnovější** a skončí, jakmile
má N kusů:

```
dny = složky v snaps/, číselně sestupně
pro každý den:
    vyber nejnovější soubory z tohoto dne (výběr maxima, bez sort)
    přidávej, dokud není N
    máš-li N, konec
```

Při `LAST 5` se typicky sáhne na jeden až dva dny místo N průchodů
celým stromem.

### 8.3 Co se nemění

`request_last` **nesmí** koukat na cursor ani na `sent_list.txt` —
vyžádané fotky mají dosáhnout i na dávno odeslané a na dny za cursorem.
To je celý smysl vyžádání.

`request_date` je už dnes scoped na jeden den. `request_get` dělá jeden
`find` bez forků na soubor — při 5 000 souborech jde o jeden průchod,
přijatelné. Obojí zůstává.

## 9. Známá omezení a přijatá rizika

1. **`WIPE` smaže i přeskočené fotky.** Přeskočené (přes `CLEAR QUEUE`
   nebo `MAX_QUEUE`) se zapisují do `sent_list.txt`, takže je pozdější
   `WIPE CONFIRM` smaže, i když nikdy nedorazily mailem. **Vědomé
   rozhodnutí** (2026-09-02) ve prospěch jednoduchosti — alternativa
   byla samostatný `state/skipped.txt`, který by `WIPE` respektoval.
   Musí být zdokumentováno u `MAX_QUEUE` v `config.txt.example` i v
   `hunter/README.md`.

   Od 2026-09-03 se to týká i **poškozených souborů**, které nově
   uzavírá `CLEAR QUEUE` (sekce 5) — i ty skončí v `sent_list.txt` a
   `WIPE CONFIRM` je z karty smaže. Potvrzeno majitelem projektu
   (2026-09-03) jako žádoucí: nedopsaný JPEG stejně nikdy nedorazí a
   jinak by na kartě ležel napořád.
2. **Skok hodin zpět.** Kdyby se po synchronizaci času zapsal snímek do
   složky dne, která je už za cursorem, automatická větev ho nevyzvedne.
   Zůstává dosažitelný přes `DATE`/`GET`.
3. **Den, který nikdy nedoteče — opraveno, viz `CLEAR QUEUE` (2026-09-03).**
   Trvale neúplný soubor (`snapready` ho nikdy nepustí) držel cursor na
   svém dni napořád. Ověřeno na 20 složkách dnů s jedním takovým
   souborem v nejstarší z nich: přes 12 po sobě jdoucích probuzení se
   `state/cursor.txt` **vůbec nezapsal** a každé probuzení procházelo
   všech 20 složek.

   Dopad **nebyl** omezený na "jednu složku navíc za probuzení", jak
   dřív tvrdil tenhle bod — nic ho neomezovalo. Bylo to celé okno od
   zaseklého dne po dnešek, rostoucí o jednu další složku s každým
   dalším dnem, co přibude na kartě, dokud je zaseklý soubor přítomný.
   Každá složka v okně stojí jeden `fgrep` přes celý `sent_list.txt`
   (3.1) a `wait_for_candidates` (`lib/mail.sh`) tohle opakuje až
   `SNAP_WAIT`-krát za probuzení, dokud nedorazí nový snímek nebo
   nevyprší čas.

   **Vzdálené východisko teď existuje: `CLEAR QUEUE` zaseklý den
   zavírá.** Rozhodnutí majitele projektu (2026-09-03): `CLEAR QUEUE`
   smaže — v tom smyslu, že označí za vyřízené — celou aktuální frontu,
   včetně souborů, které `snapready` trvale odmítá. Chodec `mail.sh`
   (`find_ready_candidates`) je proto rozdělený na společný chodec po
   dnech `list_unsent_snaps <jen_kompletni>` a tenký filtr:
   `list_unsent_snaps 1` je dnešní `find_ready_candidates` (jen
   kandidáti, které `snapready` pustí), `list_unsent_snaps 0` vrací
   úplně všechno nedoslané od cursoru dál, včetně toho, co `snapready`
   odmítá. `CLEAR QUEUE` teď volá tu druhou variantu, takže i zaseklý
   soubor skončí v `sent_list.txt`, jeho den se uzavře (`day_fully_sent`)
   a `cursor_advance` se přes něj konečně posune. `MAX_QUEUE` se
   nemění — dál řeže jen `$snap_list` (jen kompletní soubory), protože
   automatické oříznutí nedodělku má zůstat konzervativní; jde jen o
   ruční `CLEAR QUEUE`. `WIPE CONFIRM` a `DATE`/`GET` se nemění vůbec.

   **Přijaté riziko:** fotka, kterou aplikace zrovna dopisuje, je
   `snapready` odmítána ze stejného důvodu jako trvale vadný soubor —
   kód nerozliší "rozepsaná" od "trvale vadná". `CLEAR QUEUE` ji tedy
   může označit za vyřízenou, aniž kdy dorazí. Vědomé rozhodnutí
   majitele projektu: `CLEAR QUEUE` se posílá vědomě a dnešní stav (den
   zaseklý navždy, jediná cesta ven je fyzický přístup ke kartě) je
   horší. Nejnovější den se záměrně nevyjímá — vyjmutí by jen vrátilo
   díru, kdyby zaseklý soubor ležel právě tam.

   Fyzický přístup ke kartě (smazat/přesunout zaseklý soubor, případně
   ručně opravit `cursor.txt`) zůstává možný, ale **už není jediná
   cesta**. Operátor se o zaseklém dni dál dozví z logu:
   `cursor_advance` (`lib/mail.sh`) hlásí nejvýš jednou za běh, když je
   nejstarší otevřený den totožný s dnem, na kterém cursor už stojí, a
   existuje den novější — spolu s počtem složek, které se teď
   prohledávají.
4. **YY přetečení století** v porovnání dnů — zděděné omezení, už
   popsané v [command.sh:254-256](../../../hunter/lib/command.sh#L254-L256).

## 10. Změny v příkazech a konfiguraci

| Co | Změna |
|---|---|
| `CLEAR QUEUE` | nový příkaz, bez povinného tokenu |
| `LIST CMD` | musí `CLEAR QUEUE` vypsat (existuje test na shodu s dispatch tabulkou) |
| `STATUS` | rozšířit o hloubku fronty — počet čekajících kandidátů po uplatnění cursoru, tvar `FRONTA:<N>` (velkými, ve stylu stávajících `BAT:`/`SIG:`/`SPACE:`/`TOKENS:`) |
| `MAX_QUEUE` | nový klíč, výchozí `100`, s poznámkou k bodu 8.1 |
| `state/cursor.txt` | nový stavový soubor |

## 11. Testy

- cursor se **nikdy** neposune přes nejnovější složku dne
- den se uzavře, až když je **každý** jeho soubor v `sent_list.txt`;
  soubor odmítaný `snapready` ho drží otevřený
- chybějící `cursor.txt` = chování jako dnes (start od nejstaršího dne)
- retirovaný den se už neprochází (ověřit počítáním, ne odhadem)
- `CLEAR QUEUE` vyprázdní frontu a **soubory nechá na kartě**
- `MAX_QUEUE` odřízne nejstarší a fronta se vejde pod strop
- **vyžádaná fotka se přeskočením nikdy nedostane do `sent_list.txt`** —
  `CLEAR QUEUE` i `MAX_QUEUE` ji musí minout a fotka musí odejít
  (invariant 7.1). Bez tohohle testu jde o tichou, trvalou ztrátu
  automatického odesílání pro daný soubor.
- **`LAST` dosáhne na fotky před cursorem** — regrese, která by rozbila
  celý smysl vyžádání
- `snap_newer` dává stejné výsledky jako dnes (dnes ho nepokrývá žádný
  test — přibude)
- stávající scénáře v `tests/test_wake_send.sh` projdou beze změny

## 12. Mimo rozsah

- Přesouvání odeslaných fotek do `sentHD/`/`sentSD/` (sekce 2)
- Optimalizace `request_get` (jeden `find` je přijatelný)
- Mazání `HDPIC/` — `WIPE` se ho nedotýká a tenhle spec na tom nic
  nemění
