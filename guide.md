# Hunter — návod k používání

Praktický návod pro běžné používání fotopasti s Hunterem. Jak systém
funguje uvnitř a jak ho nasadit/opravit, je v
[docs/REFERENCE.md](docs/REFERENCE.md) a [hunter/README.md](hunter/README.md)
— tenhle dokument je jen o tom, jak s ním pracovat den ze dne.

## 1. Jak to funguje v kostce

Fotopast se probouzí při pohybu, pošle nové fotky e-mailem a při každém
probuzení zkontroluje, jestli jí nepřišel příkaz. Žádný stálý provoz —
mezi probuzeními zařízení "spí" a nic neposlouchá.

Příkazy se posílají **e-mailem** na stejnou adresu, na kterou fotopast
posílá fotky. Odpovědi (podle nastavení) buď přijdou mailem zpátky,
nebo se jen uloží do IMAP složky — viz sekce 3.

## 2. Jak poslat příkaz

Předmět e-mailu musí mít přesně tenhle tvar:

```
HUNTER <token> <příkaz> [argumenty]
```

`<token>` je tajný řetězec z `hunter/mail.token` na kartě — bez něj
(nebo se špatným tokenem) se příkaz odmítne. Přijde odpověď `TOKEN
REQUIRED` nebo se e-mail rovnou ignoruje, podle nastaveného režimu
autorizace (sekce 7).

Příklad: chceš vědět, kolik má fotopast baterie.

```
Předmět: HUNTER muj-tajny-token STATUS
```

**Kdy příkaz doopravdy proběhne:** až při **příštím přirozeném
probuzení** fotopasti (pohyb, nebo jiný spouštěč). Není to okamžité —
pokud fotopast dlouho nikdo nevyruší, může to trvat i hodiny.

## 3. Přehled příkazů

| Příkaz | Co udělá |
|---|---|
| `STATUS` | Baterie, signál, volné místo, velikost fronty |
| `LAST <N>` | Pošle N nejnovějších fotek (i už dříve odeslaných) |
| `DATE <YYMMDD>` | Pošle fotky z konkrétního dne, např. `DATE 260923` |
| `GET <jméno>` | Pošle jeden konkrétní soubor podle jména |
| `QUALITY HD\|LOW` | `HD` = posílat nekomprimovanou verzi z `HDPIC/` (větší příloha), `LOW` = zkomprimovanou z `snaps/` (menší, výchozí) |
| `CONFIRM ON\|OFF` | Zapne/vypne potvrzovací odpovědi na příkazy |
| `WIPE` / `WIPE CONFIRM` | Smaže už odeslané fotky a uvolní místo (sekce 5) |
| `CLEAR QUEUE` | Vyprázdní frontu čekajících fotek (i vadné) — soubory zůstávají na kartě, jen se přestanou nabízet k odeslání |
| `LIST CMD` | Vypíše tenhle seznam přímo do e-mailu, podle aktuálního režimu |
| `ADD <telefon\|e-mail>` | Přidá oprávněného uživatele — pozná se automaticky podle tvaru (`+420...` = telefon, `neco@neco.cz` = e-mail) |
| `REMOVE <telefon\|e-mail>` | Odebere oprávněného uživatele |
| `ADD TOKEN <nový>` | Přidá další platný token |
| `REMOVE TOKEN <token>` | Odebere token (poslední token nejde odebrat — zamkl by tě to venku) |
| `AUTH TYPE TOKEN\|SENDER` | Přepne režim autorizace (sekce 7) |
| `FOTO` | Nepodporováno — fotopast neumí na příkaz vyfotit mimo pohybové spouštění |

Nejaktuálnější seznam (podle toho, v jakém režimu autorizace zrovna
je) dostaneš vždy příkazem `LIST CMD`.

**Poznámka k telefonním číslům:** `MASTERS`/SMS příkazy jsou dnes
fakticky mrtvé — modem v tomhle zařízení SMS příkazy neumí. Živý je
jen e-mailový kanál (`MAIL_MASTERS`).

## 4. Kam co chodí — tři IMAP složky

Fotky, odpovědi na příkazy a chybová hlášení mohou (podle
`SEND_TRANSPORT` v configu) chodit místo klasického e-mailu přímo do
tří **oddělených IMAP složek** na tomtéž účtu — přesně tak, aby se
odesílání z mobilní SIM nechovalo jako spam bot pro operátora.

| Co | Kam (výchozí název) |
|---|---|
| Fotky | `Fotopast` |
| Odpovědi na příkazy (`STATUS`, `LAST`, ...) | stejná složka jako fotky, pokud v configu není nastavená vlastní |
| Chybová hlášení | vypnuto, pokud v configu není zapnutá vlastní složka |

Když fotky nebo odpovědi nechodí do schránky jako nová pošta, koukni
se nejdřív do těchhle IMAP složek — nová pošta v nich **nevyvolá
notifikaci**, musíš se tam podívat sám.

## 5. WIPE — mazání odeslaných fotek

`WIPE CONFIRM` maže soubory, které už byly úspěšně odeslané (nikdy
nesahá na čekající frontu ani na cizí soubory — jen na to, co je v
interním seznamu "odesláno").

**Velká fronta se maže po dávkách, automaticky:**

```
HUNTER <token> WIPE CONFIRM
→ "WIPE STARTED (500 photos, 4533 zbyva, pokracuji sam, 98.4GB free)"
```

Stačí **jedno** potvrzení. Fotopast si zbytek domaže sama při dalších
přirozených probuzeních (vždy až po odeslání aktuálních fotek, aby
mazání neukrajovalo z toho hlavního). Až je hotovo úplně všechno,
přijde:

```
"WIPE DONE (posledni davka 33 photos, 98.9GB free)"
```

Menší fronta, která se vejde do jedné dávky, doběhne rovnou:

```
"WIPE DONE (12 photos, 98.9GB free)"
```

Rozdělané mazání jde kdykoliv zastavit — smaž `hunter/state/wipe_pending.txt`
z karty. Zbylé (ještě nesmazané) fotky zůstanou v pořádku, jen se
nedomažou, dokud nepošleš `WIPE CONFIRM` znovu.

## 6. Fronta

`STATUS` hlásí `FRONTA:<N>` — kolik fotek čeká na odeslání. Fronta má
strop (v configu `MAX_QUEUE`, výchozí 100); co je přes strop, to se
nejstarší tiše přeskočí — soubor zůstane na kartě, jen se přestane
nabízet.

Když je fronta zbytečně velká (typicky po dlouhé odmlce), `CLEAR
QUEUE` ji rovnou vyprázdní celou — i soubory, které fotopast trvale
odmítá jako vadné (nedopsaný JPEG po výpadku napájení apod.).

## 7. Kdo smí posílat příkazy

Dva režimy (`AUTH TYPE`):

- **`TOKEN`** (výchozí, doporučené) — příkaz musí nést platný token
  A odesílatel musí být v seznamu oprávněných.
- **`SENDER`** — stačí, aby odesílatel byl v seznamu oprávněných.
  **Pozor:** hlavička `From:` jde snadno podvrhnout — v tomhle režimu
  je i `WIPE` dosažitelný pro kohokoli, kdo zná dvě adresy. Příkazy
  měnící oprávnění (`AUTH TYPE`, `ADD`, `REMOVE`, `ADD TOKEN`,
  `REMOVE TOKEN`) vyžadují token **vždy**, bez ohledu na režim.

## 8. Časté situace

**Fotka/odpověď nedorazila.** Nejdřív zkontroluj IMAP složky (sekce
4) — může to čekat tam, ne v hlavní schránce. Pak `STATUS` — `FRONTA`
ukáže, jestli fotka vůbec čeká na odeslání.

**Příkaz se neprovedl.** Zkontroluj přesný tvar předmětu (`HUNTER
<token> PŘÍKAZ`) a že token sedí. Špatný token = `TOKEN REQUIRED`
nebo úplné ticho, podle situace.

**`WIPE` mi nesmazal, co jsem čekal.** Maže jen soubory z interního
seznamu "odesláno" — pokud fotka nikdy neodešla (např. dlouho čekala
ve frontě), `WIPE` na ni nesáhne. `CLEAR QUEUE` fotku z fronty odebere
a **tím ji zařadí mezi "vyřízené"** — teprve pak ji příští `WIPE`
smaže i fyzicky.

**Nejde se dostat k žádnému příkazu (ztracený token).** Bez fyzického
přístupu ke kartě se to bohužel nedá obejít — token se vytváří jen
lokálním zápisem do `hunter/mail.token`.

## Technické zázemí

Kompletní architektura, konfigurační klíče, chování při chybách a
postup obnovy po nehodě: [docs/REFERENCE.md](docs/REFERENCE.md).
Postup nasazení a fyzická práce s kartou: [hunter/README.md](hunter/README.md)
a [CHECKLIST.md](CHECKLIST.md).
