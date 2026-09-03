# Hunter — volitelný transport: SMTP, IMAP APPEND, nebo obojí

**Stav:** návrh schválen 2026-09-03, čeká na implementační plán.

## 1. Problém

O2 zablokovalo celou SIM — data i volání — kvůli ochraně proti spamu.
Odesílání pošty přes SMTP přímo z mobilní SIM je pro operátora klasický
podpis spam bota, a Hunter to při výpadku dělá nejhorším možným
způsobem: každé probuzení až `MAX_SEND_PER_WAKE` pokusů, všechny
selžou, za minutu znovu.

Přesnou příčinu zná jen O2 a nedá se z kódu ověřit. Sedí ale na
pozorování „děje se to při testech", protože testy jsou jediné, co dělá
nárazy.

## 2. Proč IMAP APPEND

Uložit zprávu do složky na tomtéž účtu přes `APPEND` **není z pohledu
operátora odesílání pošty**. Je to spojení na port 993, tedy přesně
totéž, jaké zařízení stejně dělá kvůli příkazovému kanálu. Spam
heuristika nemá co chytit — žádné SMTP spojení nevznikne.

Nemá to být náhrada SMTP, ale volba. Proto se transport stává
konfigurovatelným.

## 3. Konfigurace

Dva nové klíče v `config.txt`:

```
# smtp       - jen mailem (vychozi, dnesni chovani)
# imap       - jen ulozit do slozky
# smtp-imap  - mailem; kdyz SMTP selze, ulozit do slozky
# imap-smtp  - do slozky; kdyz IMAP selze, poslat mailem
# smtp+imap  - oboji vzdy, dve kopie
SEND_TRANSPORT=smtp

# Slozka na tomtez uctu, kam se uklada pres IMAP APPEND.
# NESMI byt INBOX - viz nize.
IMAP_SAVE_FOLDER=Fotopast
```

**Výchozí je `smtp`** — po nasazení se nezmění nic, dokud uživatel sám
nepřepne. Aktualizace živé karty tedy nevyžaduje žádný migrační krok.

`SEND_TRANSPORT` řídí **i odpovědi na příkazy** (`STATUS`, `LAST`,
`CLEAR QUEUE`, …), ne jen fotky. Jedno nastavení, žádné dvě poloviny,
které se můžou rozejít. Když je SMTP zablokované, odpověď se objeví ve
složce — uživatel ji uvidí, i když nedorazí do schránky.

**`SEND_TRANSPORT` neovlivňuje příjem příkazů.** Příkazový kanál chodí
přes IMAP vždycky, bez ohledu na nastavení — `SEND_TRANSPORT` řídí jen
směr ven. `SEND_TRANSPORT=smtp` tedy neznamená „IMAP se nepoužívá",
znamená „ven se posílá mailem".

### 3.1 Validace

`load_config` obojí ověří, ve stylu ostatních kontrol tamtéž:

- Neznámá hodnota `SEND_TRANSPORT` → `smtp` (dnešní chování je
  nejbezpečnější fallback).
- `IMAP_SAVE_FOLDER` prázdný → `Fotopast`.
- **`IMAP_SAVE_FOLDER` rovný `INBOX` (bez ohledu na velikost písmen) se
  odmítne** a přepne na `Fotopast`. Důvod není kosmetický: Hunter hledá
  příkazy přes `SEARCH UNSEEN` v INBOXu, takže by si vlastní uložené
  fotky přečetl jako příchozí příkazy. Kontrola musí být v kódu, ne jen
  v dokumentaci.
- Režim, který používá IMAP (`imap`, `smtp-imap`, `imap-smtp`,
  `smtp+imap`) při prázdném `IMAP_HOST` → `smtp`, se záznamem do logu.
  Bez toho by se každé odeslání tiše nezdařilo.

## 4. Dispečer v shellu

`send_snap` a `send_reply_mail` v `hunter/lib/mail.sh` přestanou volat
`mailsend_run` přímo a půjdou přes společného dispečera, který čte
`SEND_TRANSPORT`. Obě funkce si drží dnešní signaturu i návratový kód.

### 4.1 Kdy se zpráva počítá za odeslanou

**Když uspěl aspoň jeden zvolený transport.**

U `smtp+imap` tedy stačí, aby prošel mail. Kdyby se vyžadoval úspěch
obou, výpadek IMAPu by způsobil, že se donekonečna přeposílá fotka,
kterou uživatel dávno má — a to je přesně ta salva, kvůli které blok
vznikl.

U fallback režimů (`smtp-imap`, `imap-smtp`) se druhý transport zkusí
**jen když první selže**. Za normálního provozu tedy nevzniká žádný
provoz navíc.

## 5. Sdílená stavba zprávy (C)

Dnes staví celou MIME zprávu `mailsend.c` inline uprostřed SMTP
konverzace (řádky ~355-393): hlavičky, `multipart/mixed`, textová část,
příloha v base64, závěrečný boundary.

Vytáhne se do sdíleného `mimemsg.c` / `mimemsg.h` — **stejný krok, jaký
se už jednou udělal s `tlsnet.c`, a ze stejného důvodu**: dvě binárky
potřebují tutéž logiku a kopie by se rozešly.

### 5.1 Dot-stuffing patří transportu, ne zprávě

`mailsend` dnes posílá tělo přes `send_text_dotstuffed()` a zprávu
ukončuje `\r\n.\r\n`. **Obojí je rámování SMTP, ne součást zprávy.**
Kdyby to sdílený generátor zachoval, každá uložená zpráva s řádkem
začínajícím tečkou by se v IMAP složce poškodila.

Sdílený generátor tedy emituje **čistou zprávu**. Dot-stuffing i
ukončovací tečku si přidává `mailsend` sám, až při zápisu do SMTP
`DATA`.

### 5.2 Dva průchody, ne buffer

IMAP `APPEND` chce velikost literálu dopředu (`APPEND slozka {123456}`),
kdežto SMTP jen streamuje do tečky. Fotka v base64 má kolem 400 kB a
držet ji celou v RAM na tomhle zařízení není přijatelné.

Generátor proto poběží **nadvakrát**: první průchod jen počítá bajty,
druhý je posílá. Rozhraní je jeden „sink" — buď počítadlo, nebo zápis
do soketu. Je to pár řádků navíc a ušetří to velkou alokaci.

### 5.3 Hlavička `Date:` a INTERNALDATE

Zařízení nemá zálohované hodiny, takže hlavička `Date:` může být mimo.
To je zděděný stav a nemění se.

Volitelný argument date-time u `APPEND` se ale **vynechá** — server pak
stampne INTERNALDATE sám, což je spolehlivější než hodiny zařízení.

## 6. `append` v `mailrecv` (C)

Přibude příkaz `append <slozka>` vedle dnešních `list unseen` a `seen`.
Session, přihlášení, čekání na tag, literály i quoting už v
`mailrecv.c` jsou.

- **`CREATE` složky před prvním `APPEND`**, chybu „už existuje"
  ignorovat. Uživatel tak nemusí složku zakládat ručně.
- **Synchronizující literál**: poslat `{N}`, počkat na `+`, teprve pak
  data. Nespoléhat na `LITERAL+`, který server nemusí umět.
- **`append` musí přeskočit `SELECT INBOX`.** `mailrecv.c` ho dnes dělá
  bezpodmínečně před rozskokem na příkaz. `APPEND` ho nepotřebuje a
  jeho selhání by zbytečně shodilo uložení.
- Zpráva se ukládá **bez `\Seen`** — ve složce se tedy tváří jako nová.
  Hunter tu složku nikdy neprochází, takže to nic nerozbije.

## 7. Přijatá omezení

1. **IMAP APPEND nedoručí notifikaci.** Zpráva se objeví ve složce, ne
   ve schránce. Při `imap` a `imap-smtp` se uživatel musí do složky sám
   podívat. Vědomé rozhodnutí — proti tomu stojí, že fotka vůbec
   dorazí.
2. **Uloží se jen na účet fotopasti.** `SMTP_TO` může být jiná adresa;
   `APPEND` umí jen tentýž účet, přes který se přihlašuje.
3. **Neřeší to už vzniklý blok.** Transport odstraňuje spouštěč, ne
   následek. Když je SIM zablokovaná, nefunguje ani IMAP.
4. **Velikost zprávy** je limitovaná tím, co server u `APPEND`
   akceptuje. Neověřeno pro Seznam; při odmítnutí se uplatní fallback
   (u `smtp-imap`) nebo se zpráva nezapíše do `sent_list.txt` a zkusí
   se příště.

## 8. Testy

- každá z pěti hodnot `SEND_TRANSPORT` volí správné transporty
- neznámá hodnota spadne na `smtp`
- `IMAP_SAVE_FOLDER=INBOX` se odmítne a přepne na `Fotopast` —
  **s mutační kontrolou**, protože bez téhle validace by si Hunter četl
  vlastní fotky jako příkazy a bylo by to tiché
- fallback: když první transport selže, použije se druhý a fotka skončí
  v `sent_list.txt` **právě jednou**
- `smtp+imap`: úspěch SMTP a selhání IMAP se pořád počítá za odeslané
- odpovědi na příkazy jdou stejným kanálem jako fotky
- sdílený generátor emituje pro SMTP i IMAP **tytéž bajty zprávy**, jen
  SMTP navíc dot-stuffuje — ověřit porovnáním, ne odhadem
- počítací průchod dá stejné číslo jako délka skutečně odeslaných dat

Falešný `mailrecv` v `tests/fixture_subprocess.sh` se musí naučit
`append`.

## 9. Mimo rozsah

- **Backoff po selháních odesílání.** Chceme ho, ale je to samostatná
  změna: tenhle transport řeší „nebýt viděn jako spam", backoff řeší
  „nebušit, když už je zle". Míchat je do jednoho diffu znamená horší
  revizi. Udělá se hned potom.
- **Odesílání přes HTTPS na vlastní službu.** Sáhne se po tom jen
  tehdy, kdyby O2 blokovalo i při slušném chování.
- `FOTO` zůstává neimplementované.
