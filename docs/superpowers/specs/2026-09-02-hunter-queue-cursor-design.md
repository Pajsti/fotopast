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

Označí **všechny aktuálně čekající** fotky za vyřízené, aniž by je
odeslal. Soubory na kartě zůstávají. Pak se provede posun cursoru
(3.2), takže se dohánění nedodělku zastaví.

- **Token není povinný** — příkaz nemění oprávnění, stejně jako `WIPE`.
  Zůstává tedy dostupný i v režimu `SENDER` (viz spec příkazů, 3.3).
- **Bez potvrzovacího slova.** `WIPE` vyžaduje `CONFIRM`, protože maže;
  `CLEAR QUEUE` soubory nechává.
- Odpověď: `QUEUE CLEARED (<N> skipped)`.

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
2. **Skok hodin zpět.** Kdyby se po synchronizaci času zapsal snímek do
   složky dne, která je už za cursorem, automatická větev ho nevyzvedne.
   Zůstává dosažitelný přes `DATE`/`GET`.
3. **Den, který nikdy nedoteče.** Trvale neúplný soubor (`snapready` ho
   nikdy nepustí) drží cursor na svém dni napořád — `MAX_QUEUE` ho
   přeskočí jen tehdy, když nedodělek naroste přes strop; jediný
   zaseklý soubor pod stropem se sám nevyřeší. Dopad je ale omezený:
   prochází se navíc jedna složka dne za probuzení, ne celá historie.
   Ruční východisko je `CLEAR QUEUE`.
4. **YY přetečení století** v porovnání dnů — zděděné omezení, už
   popsané v [command.sh:254-256](../../../hunter/lib/command.sh#L254-L256).

## 10. Změny v příkazech a konfiguraci

| Co | Změna |
|---|---|
| `CLEAR QUEUE` | nový příkaz, bez povinného tokenu |
| `LIST CMD` | musí `CLEAR QUEUE` vypsat (existuje test na shodu s dispatch tabulkou) |
| `STATUS` | rozšířit o hloubku fronty — počet čekajících kandidátů po uplatnění cursoru, tvar `fronta:<N>` |
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
