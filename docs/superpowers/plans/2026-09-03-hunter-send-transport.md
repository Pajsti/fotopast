# Volitelný transport (SMTP / IMAP APPEND) — implementační plán

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aby si uživatel v configu zvolil, jestli fotky odcházejí mailem, ukládají se přes IMAP APPEND do složky na tomtéž účtu, nebo obojí — a aby ta volba platila i pro odpovědi na příkazy.

**Architecture:** Stavba MIME zprávy se vytáhne z `mailsend.c` do sdíleného `mimemsg.c`, který emituje čistou zprávu do vyměnitelného „sinku" — SMTP si přes svůj sink přidá dot-stuffing, IMAP si tímtéž generátorem nejdřív spočítá velikost literálu a pak ho pošle. `mailrecv` dostane příkaz `append`. V shellu přibude jeden dispečer, kterým projdou obě odesílací cesty.

**Tech Stack:** C99 křížově překládaný pro MIPS (uClibc, staticky, mbedTLS), POSIX shell (busybox ash na zařízení, `dash` v testech).

**Spec:** [docs/superpowers/specs/2026-09-03-hunter-send-transport-design.md](../specs/2026-09-03-hunter-send-transport-design.md)

## Global Constraints

Platí pro každý task:

- **Busybox na zařízení nemá `awk`, `sed`, `cut`, `sort`, `uniq`, `wc`, `head`, `tail`, `expr`, `tee` ani `bc`.** Z appletů se smí jen `grep`/`fgrep`, `find`, `tr`, `date`, `mkdir`, `mv`, `rm`, `sync`, `printf`. Field extraction jde přes parametrickou expanzi (`${var#...}`/`${var%...}`) a `case`.
- **`tr` jen s explicitními rozsahy** (`tr 'A-Z' 'a-z'`), nikdy POSIX třídy.
- **Žádný doslovný TAB (0x09) a žádné CR** v souborech pod `hunter/`. **Žádná diakritika v `hunter/**/*.sh` ani v `tests/*.sh`**, včetně komentářů. Dokumentace (`hunter/README.md`, `CHECKLIST.md`, `docs/**`) se píše česky **s** diakritikou.
- **Signály vždy jménem** (`-STOP`, `-CONT`, `-TERM`), nikdy číslem.
- **Aritmetika je 32bitová.**
- **Zařízení nemá zálohované hodiny.** Nic se nesmí spoléhat na to, že `time()` dá správný čas.
- **Testy:** `sh tests/run_tests.sh` (běží pod `dash`). Každý task končí zelenou celou sadou, ne jen svým souborem.
- **C se překládá na Raspberry Pi**, ne na Windows: `ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build`, zdrojáky v `~/fotopast/test_files/`. Křížový překlad potřebuje mbedTLS připravený přes `./build.sh` — když `build/mbedtls` chybí, `make` to sám ohlásí.
- **Nikdy neupravovat `hunter/lib/*.sh` přímo na Pi** — repo na Windows je zdroj pravdy. Na Pi se jen kompiluje C a pouštějí nativní testy.
- **Commity** česky bez diakritiky, krátký předmět (50-60 znaků) ve stylu `git log --oneline`, detail v těle. Na konci `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## Struktura souborů

**Nové:**

| Soubor | Odpovědnost |
|---|---|
| `test_files/mimemsg.h` | Rozhraní generátoru zprávy — struktura zprávy, typ sinku, dvě funkce. |
| `test_files/mimemsg.c` | Stavba RFC 5322 `multipart/mixed` zprávy do sinku; base64 přílohy; sink s dot-stuffingem pro SMTP. Žádná závislost na `tlsnet` — proto se dá přeložit nativně a testovat. |
| `test_files/mimemsg_test.c` | Nativní test generátoru: shoda počítacího a zapisovacího průchodu, a že dot-stuffing dělá jen SMTP sink. |
| `tests/test_transport.sh` | Shell testy dispečera a validace configu. |

**Měněné:**

| Soubor | Změna |
|---|---|
| `test_files/mailsend.c` | Přestane stavět zprávu sám, použije `mimemsg`. Dot-stuffing a ukončovací tečku si drží jako své rámování. |
| `test_files/mailrecv.c` | Nový příkaz `append <slozka>`; `SELECT INBOX` se pro něj přeskočí. |
| `test_files/Makefile` | `mimemsg.o`, linkování do obou binárek, cíl `hosttest`. |
| `hunter/lib/common.sh` | `SEND_TRANSPORT` a `IMAP_SAVE_FOLDER` — výchozí hodnoty a validace. |
| `hunter/lib/mail.sh` | Dispečer `send_message`; `send_snap` a `send_reply_mail` přes něj. |
| `hunter/config.txt.example` | Dva nové klíče s komentáři. |
| `hunter/README.md` | Popis transportu. |
| `CHECKLIST.md` | Fáze 10 — nasazení. |
| `tests/fixture_subprocess.sh` | Falešný `mailrecv` se naučí `append`. |

---

### Task 1: Konfigurační klíče a jejich validace

Spec 3 a 3.1. Čistě shellový task, nezávislý na céčku — dá se udělat a zrevidovat samostatně.

Validace není kosmetika. `IMAP_SAVE_FOLDER=INBOX` by způsobil, že si Hunter přečte vlastní uložené fotky jako příchozí příkazy, protože příkazy hledá přes `SEARCH UNSEEN` v INBOXu. To je tichá chyba, a proto ji odmítá kód, ne dokumentace.

**Files:**
- Modify: `hunter/lib/common.sh` (v `load_config`, k ostatním výchozím hodnotám a kontrolám)
- Modify: `hunter/config.txt.example`
- Create: `tests/test_transport.sh`

**Interfaces:**
- Consumes: nic z předchozích tasků.
- Produces: proměnné `SEND_TRANSPORT` (jedna z `smtp`, `imap`, `smtp-imap`, `imap-smtp`, `smtp+imap`) a `IMAP_SAVE_FOLDER` (neprázdný řetězec, nikdy `INBOX` v žádné velikosti písmen). Konzumuje Task 5.

- [ ] **Step 1: Napiš padající test**

Vytvoř `tests/test_transport.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# --- vychozi hodnoty ---
assert_eq "vychozi SEND_TRANSPORT je smtp" "$SEND_TRANSPORT" "smtp"
assert_eq "vychozi IMAP_SAVE_FOLDER je Fotopast" "$IMAP_SAVE_FOLDER" "Fotopast"

# --- platne hodnoty projdou beze zmeny ---
for v in smtp imap smtp-imap imap-smtp smtp+imap; do
    SEND_TRANSPORT="$v"; IMAP_HOST="imap.example.com"
    validate_transport
    assert_eq "platna hodnota $v se nemeni" "$SEND_TRANSPORT" "$v"
done

# --- neznama hodnota spadne na smtp ---
SEND_TRANSPORT="posta"; IMAP_HOST="imap.example.com"
validate_transport
assert_eq "neznama hodnota spadne na smtp" "$SEND_TRANSPORT" "smtp"

SEND_TRANSPORT=""; IMAP_HOST="imap.example.com"
validate_transport
assert_eq "prazdna hodnota spadne na smtp" "$SEND_TRANSPORT" "smtp"

# --- IMAP rezim bez IMAP_HOST spadne na smtp ---
SEND_TRANSPORT="imap"; IMAP_HOST=""
validate_transport
assert_eq "imap bez IMAP_HOST spadne na smtp" "$SEND_TRANSPORT" "smtp"

SEND_TRANSPORT="smtp-imap"; IMAP_HOST=""
validate_transport
assert_eq "smtp-imap bez IMAP_HOST spadne na smtp" "$SEND_TRANSPORT" "smtp"

# --- smtp bez IMAP_HOST je v poradku, IMAP nepotrebuje ---
SEND_TRANSPORT="smtp"; IMAP_HOST=""
validate_transport
assert_eq "smtp bez IMAP_HOST zustava smtp" "$SEND_TRANSPORT" "smtp"

# --- INBOX se odmita, at je napsany jakkoli ---
IMAP_HOST="imap.example.com"
for f in INBOX inbox InBoX; do
    SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER="$f"
    validate_transport
    assert_eq "slozka $f se odmita" "$IMAP_SAVE_FOLDER" "Fotopast"
done

# --- prazdna slozka spadne na vychozi ---
SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER=""
validate_transport
assert_eq "prazdna slozka spadne na Fotopast" "$IMAP_SAVE_FOLDER" "Fotopast"

# --- jina slozka projde ---
SEND_TRANSPORT="imap"; IMAP_SAVE_FOLDER="Archiv/Fotopast"
validate_transport
assert_eq "vlastni slozka projde" "$IMAP_SAVE_FOLDER" "Archiv/Fotopast"

fixture_teardown
finish
```

- [ ] **Step 2: Spusť test, ověř že padá**

Run: `dash tests/test_transport.sh`
Expected: FAIL — `validate_transport: not found`, a výchozí hodnoty nejsou nastavené.

- [ ] **Step 3: Přidej výchozí hodnoty a `validate_transport` do `common.sh`**

V `hunter/lib/common.sh` přidej k ostatním výchozím hodnotám v `load_config` (za `: "${MAX_QUEUE:=100}"` a jeho kontrolu):

```sh
    # Kudy odchazi fotky a odpovedi na prikazy. Prijem prikazu tim
    # dotcen NENI - ten jde pres IMAP vzdycky.
    #   smtp       jen mailem (vychozi, dosavadni chovani)
    #   imap       jen ulozit pres IMAP APPEND do slozky
    #   smtp-imap  mailem; kdyz SMTP selze, ulozit do slozky
    #   imap-smtp  do slozky; kdyz IMAP selze, poslat mailem
    #   smtp+imap  oboji vzdy, dve kopie
    : "${SEND_TRANSPORT:=smtp}"
    : "${IMAP_SAVE_FOLDER:=Fotopast}"
    validate_transport
```

A nad `load_config` (k ostatním sdíleným pomocníkům) novou funkci:

```sh
# validate_transport
# Uklidi SEND_TRANSPORT a IMAP_SAVE_FOLDER na hodnoty, se kterymi se da
# pracovat. Je to samostatna funkce, aby sla testovat bez cteni configu.
#
# Vsechny opravy padaji na "smtp", protoze to je dosavadni chovani -
# spatna konfigurace tedy nikdy nezhorsi to, co uz bezi.
validate_transport() {
    case "$SEND_TRANSPORT" in
        smtp|imap|smtp-imap|imap-smtp|smtp+imap) ;;
        *)
            log "SEND_TRANSPORT neznama hodnota, pouzivam smtp"
            SEND_TRANSPORT=smtp
            ;;
    esac

    # Rezim s IMAPem bez IMAP_HOST by tise selhal pri kazdem odeslani -
    # mailrecv by nemel kam se pripojit. Radsi zpatky na smtp.
    case "$SEND_TRANSPORT" in
        *imap*)
            if [ -z "$IMAP_HOST" ]; then
                log "SEND_TRANSPORT chce IMAP, ale IMAP_HOST je prazdny - pouzivam smtp"
                SEND_TRANSPORT=smtp
            fi
            ;;
    esac

    [ -n "$IMAP_SAVE_FOLDER" ] || IMAP_SAVE_FOLDER=Fotopast

    # INBOX je zakazany: prikazy se hledaji pres SEARCH UNSEEN prave
    # tam, takze by si Hunter vlastni ulozene fotky precetl jako
    # prichozi prikazy. Porovnava se bez ohledu na velikost pismen,
    # protoze IMAP nazev INBOX case-insensitive je.
    _isf_low=$(printf '%s' "$IMAP_SAVE_FOLDER" | tr 'A-Z' 'a-z')
    if [ "$_isf_low" = "inbox" ]; then
        log "IMAP_SAVE_FOLDER nesmi byt INBOX - pouzivam Fotopast"
        IMAP_SAVE_FOLDER=Fotopast
    fi
}
```

- [ ] **Step 4: Spusť test, ověř že prochází**

Run: `dash tests/test_transport.sh`
Expected: PASS, všechny asserty.

- [ ] **Step 5: Doplň klíče do `config.txt.example`**

Do `hunter/config.txt.example` za sekci `# --- IMAP (prikazovy kanal) ---` přidej:

```
# --- Kudy odchazi fotky a odpovedi ---
# Prijem prikazu tim dotcen NENI - ten jde pres IMAP vzdycky.
#
#   smtp       jen mailem (vychozi, dosavadni chovani)
#   imap       jen ulozit pres IMAP APPEND do slozky nize
#   smtp-imap  mailem; kdyz SMTP selze, ulozit do slozky
#   imap-smtp  do slozky; kdyz IMAP selze, poslat mailem
#   smtp+imap  oboji vzdy, dve kopie
#
# Proc to existuje: odesilani SMTP primo z mobilni SIM vypada pro
# operatora jako spam bot a O2 kvuli tomu jednou zablokovalo celou SIM
# (data i volani). IMAP APPEND je totez spojeni na 993, jake zarizeni
# stejne dela kvuli prikazum - operator nema co chytit.
SEND_TRANSPORT=smtp

# Slozka na tomtez uctu, kam se uklada pres IMAP APPEND. Zaklada se
# sama, kdyz neexistuje.
#
# NESMI byt INBOX: prikazy se hledaji pres SEARCH UNSEEN prave tam,
# takze by si Hunter vlastni ulozene fotky precetl jako prichozi
# prikazy. Kdyz sem INBOX napises, kod ho odmitne a pouzije Fotopast.
IMAP_SAVE_FOLDER=Fotopast
```

- [ ] **Step 6: Mutačně ověř kontrolu `INBOX`**

Spec sekce 8 tenhle test jmenuje zvlášť, protože chyba, kterou hlídá, je tichá: kdyby se fotky ukládaly do INBOXu, Hunter by si je při `SEARCH UNSEEN` četl jako příchozí příkazy a nic by to neohlásilo.

Dočasně odstraň z `validate_transport` blok, který INBOX odmítá:

```sh
    _isf_low=$(printf '%s' "$IMAP_SAVE_FOLDER" | tr 'A-Z' 'a-z')
    if [ "$_isf_low" = "inbox" ]; then
        log "IMAP_SAVE_FOLDER nesmi byt INBOX - pouzivam Fotopast"
        IMAP_SAVE_FOLDER=Fotopast
    fi
```

Spusť `dash tests/test_transport.sh` — **všechny tři asserty** „slozka INBOX/inbox/InBoX se odmita" musí spadnout. Pak mutaci vrať a ověř, že je sada zase zelená. Oba výstupy zapiš do reportu.

Kdyby po odstranění bloku testy prošly, netestují to, co mají — a to je horší než žádný test, protože to budí falešnou důvěru přesně tam, kde je selhání neviditelné.

- [ ] **Step 7: Spusť celou sadu**

Run: `sh tests/run_tests.sh`
Expected: všechny sady zelené (14 souborů — nově `test_transport.sh`).

- [ ] **Step 8: Commit**

```bash
git add hunter/lib/common.sh hunter/config.txt.example tests/test_transport.sh
git commit -m "$(printf 'feat: konfigurace transportu SEND_TRANSPORT a IMAP_SAVE_FOLDER\n\nZatim jen klice a jejich validace, odesilani je pouziva az dalsi task.\nVychozi smtp, takze se chovani nemeni, dokud uzivatel neprepne.\n\nIMAP_SAVE_FOLDER=INBOX se odmita v kodu, ne jen v dokumentaci - prikazy\nse hledaji pres SEARCH UNSEEN prave tam, takze by si Hunter vlastni\nulozene fotky precetl jako prichozi prikazy.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"
```

---

### Task 2: Sdílený generátor zprávy `mimemsg`

Spec 5, 5.1, 5.2, 5.3. Nová dvojice souborů plus nativní test. Zatím nikdo `mimemsg` nepoužívá — to přijde v Tasku 3 a 4.

**Proč sink a ne buffer:** IMAP `APPEND` chce velikost literálu dopředu, SMTP jen streamuje. Fotka v base64 má kolem 400 kB a držet ji celou v RAM na tomhle zařízení není přijatelné. Generátor proto poběží nadvakrát — jednou do počítadla, jednou do soketu.

**Proč `mimemsg` nesmí volat `tlsnet`:** kdyby volal, nešel by přeložit nativně a nedal by se testovat. Sink je callback, takže `mimemsg.c` nezná ani soket, ani TLS.

**Proč se datum předává zvenčí:** kdyby si `mimemsg` volal `time()` sám, dva průchody by se mohly lišit o sekundu, spočítaná velikost by neseděla na odeslaná data a IMAP literál by se rozešel. Datum si spočítá volající jednou a předá ho.

**Files:**
- Create: `test_files/mimemsg.h`
- Create: `test_files/mimemsg.c`
- Create: `test_files/mimemsg_test.c`
- Modify: `test_files/Makefile`

**Interfaces:**
- Consumes: nic z předchozích tasků.
- Produces: `mimemsg_emit`, `mimemsg_size`, `mimemsg_dotstuff_sink`, `struct mimemsg`, `mimemsg_sink`. Konzumuje Task 3 (`mailsend`) a Task 4 (`mailrecv`).

- [ ] **Step 1: Napiš rozhraní**

Vytvoř `test_files/mimemsg.h`:

```c
/* mimemsg.h - stavba RFC 5322 multipart/mixed zpravy do vymenitelneho
 * sinku.
 *
 * Existuje proto, ze tutez zpravu potrebuji dve binarky: mailsend ji
 * streamuje do SMTP DATA, mailrecv ji uklada pres IMAP APPEND. Kopie by
 * se rozesly - stejny duvod, proc uz drive vznikl tlsnet.c.
 *
 * Generator emituje CISTOU zpravu. Dot-stuffing a ukoncovaci tecka jsou
 * ramovani SMTP, ne soucast zpravy - kdyby je generator delal, kazda
 * ulozena zprava s radkem zacinajicim teckou by se v IMAP slozce
 * poskodila. mailsend si je pridava sam pres mimemsg_dotstuff_sink.
 */
#ifndef MIMEMSG_H
#define MIMEMSG_H

#include <stddef.h>

/* Sink dostava kusy zpravy, ne cele radky. Vraci 0 pri uspechu, -1 pri
 * chybe - generator pak skonci a vrati -1 taky. */
typedef int (*mimemsg_sink)(const char *buf, size_t len, void *ctx);

struct mimemsg {
    const char *from;      /* adresa odesilatele, bez lomenych zavorek */
    const char *to;        /* adresa prijemce, bez lomenych zavorek */
    const char *subject;
    const char *body;      /* text, radky oddelene \n; smi byt "" */
    const char *attach;    /* cesta k JPEG souboru, nebo NULL */
    const char *date;      /* RFC 5322 datum, nebo NULL = hlavicka Date se vynecha */
};

/* Vygeneruje celou zpravu do sinku. Vraci 0 pri uspechu, -1 kdyz sink
 * ohlasil chybu. Kdyz attach nejde otevrit, zprava se posle bez nej a
 * na stderr jde varovani - stejne jako drive v mailsend. */
int mimemsg_emit(const struct mimemsg *m, mimemsg_sink sink, void *ctx);

/* Spocita, kolik bajtu by mimemsg_emit poslal, aniz by neco poslal.
 * Vraci 0 pri uspechu a velikost ulozi do *out.
 *
 * Musi davat presne tolik, kolik pak mimemsg_emit skutecne posle -
 * IMAP APPEND na tom stoji. Proto se datum predava ve struct, ne
 * pocita uvnitr. */
int mimemsg_size(const struct mimemsg *m, size_t *out);

/* Sink pro SMTP: doplnuje dot-stuffing (radek zacinajici teckou by
 * jinak SMTP DATA ukoncil) a predava dal do vnitrniho sinku.
 * Je stavovy - jeden ctx na jednu zpravu, nulovany pred pouzitim. */
struct mimemsg_dotstuff {
    mimemsg_sink inner;
    void *inner_ctx;
    int at_line_start;   /* pred prvnim zapisem nastav na 1 */
};

int mimemsg_dotstuff_sink(const char *buf, size_t len, void *ctx);

#endif
```

- [ ] **Step 2: Napiš padající nativní test**

Vytvoř `test_files/mimemsg_test.c`:

```c
/* mimemsg_test.c - nativni test generatoru zpravy.
 *
 * Prekladá se pro hostitele (make hosttest), ne pro MIPS - overuje
 * logiku stavby zpravy, ktera na cilove platforme nezavisi.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mimemsg.h"

static int fails = 0;

static void ok(const char *what, int cond)
{
    printf("%s %s\n", cond ? "OK  " : "FAIL", what);
    if (!cond) fails++;
}

/* sink, ktery sklada vsechno do pameti */
struct buf { char *p; size_t len, cap; };

static int buf_sink(const char *b, size_t n, void *ctx)
{
    struct buf *o = ctx;
    if (o->len + n + 1 > o->cap) {
        o->cap = (o->len + n + 1) * 2;
        o->p = realloc(o->p, o->cap);
        if (!o->p) return -1;
    }
    memcpy(o->p + o->len, b, n);
    o->len += n;
    o->p[o->len] = '\0';
    return 0;
}

int main(void)
{
    struct mimemsg m;
    struct buf plain = { NULL, 0, 0 };
    struct buf stuffed = { NULL, 0, 0 };
    struct mimemsg_dotstuff ds;
    size_t counted = 0;

    memset(&m, 0, sizeof(m));
    m.from = "fotopast@example.com";
    m.to = "me@example.com";
    m.subject = "HUNTER 260903 121500";
    /* radek zacinajici teckou je jadro testu 5.1 */
    m.body = "BAT:74%\n.tecka na zacatku radku\nkonec\n";
    m.attach = NULL;
    m.date = "Wed, 03 Sep 2026 12:15:00 +0000";

    /* --- pocitaci pruchod se musi shodovat se zapisovacim --- */
    ok("mimemsg_size projde", mimemsg_size(&m, &counted) == 0);
    ok("mimemsg_emit projde", mimemsg_emit(&m, buf_sink, &plain) == 0);
    ok("spocitana velikost sedi na odeslanou", counted == plain.len);

    /* --- generator NEsmi dot-stuffovat --- */
    ok("cista zprava ma radek s jednou teckou",
       strstr(plain.p, "\r\n.tecka na zacatku radku\r\n") != NULL);
    ok("cista zprava nema dvojitou tecku",
       strstr(plain.p, "\r\n..tecka") == NULL);

    /* --- povinne hlavicky --- */
    ok("hlavicka From", strstr(plain.p, "From: <fotopast@example.com>\r\n") != NULL);
    ok("hlavicka To", strstr(plain.p, "To: <me@example.com>\r\n") != NULL);
    ok("hlavicka Subject", strstr(plain.p, "Subject: HUNTER 260903 121500\r\n") != NULL);
    ok("hlavicka Date", strstr(plain.p, "Date: Wed, 03 Sep 2026 12:15:00 +0000\r\n") != NULL);
    /* Ukoncovaci tecka je ramovani SMTP - v ciste zprave nesmi byt
     * vubec, jinak by IMAP literal mel spatnou delku a zprava by se
     * ve slozce utnula. */
    ok("cista zprava neobsahuje SMTP ukoncovaci tecku",
       strstr(plain.p, "\r\n.\r\n") == NULL);

    /* --- SMTP sink dot-stuffing dela --- */
    ds.inner = buf_sink;
    ds.inner_ctx = &stuffed;
    ds.at_line_start = 1;
    ok("emit pres dotstuff sink projde",
       mimemsg_emit(&m, mimemsg_dotstuff_sink, &ds) == 0);
    ok("SMTP varianta ma tecku zdvojenou",
       strstr(stuffed.p, "\r\n..tecka na zacatku radku\r\n") != NULL);
    ok("SMTP varianta je delsi presne o jeden bajt",
       stuffed.len == plain.len + 1);

    /* --- bez data se hlavicka Date vynecha --- */
    {
        struct buf nod = { NULL, 0, 0 };
        m.date = NULL;
        ok("emit bez data projde", mimemsg_emit(&m, buf_sink, &nod) == 0);
        ok("bez data neni hlavicka Date", strstr(nod.p, "Date:") == NULL);
        free(nod.p);
    }

    free(plain.p);
    free(stuffed.p);

    printf("\nselhalo: %d\n", fails);
    return fails ? 1 : 0;
}
```

- [ ] **Step 3: Přidej do Makefile cíl pro nativní test**

V `test_files/Makefile` přidej za `UTIL_TOOLS` řádek a do `.PHONY`:

```make
HOSTCC  ?= cc

.PHONY: all at mail util clean strip hosttest
```

A na konec, před `clean`:

```make
# Nativni test generatoru zpravy. mimemsg.c zamerne nezavisi na tlsnet
# ani na mbedTLS, takze se da prelozit pro hostitele a otestovat.
hosttest: mimemsg.c mimemsg.h mimemsg_test.c
	$(HOSTCC) -O2 -Wall -Wextra -std=gnu99 -o mimemsg_test \
	  mimemsg_test.c mimemsg.c
	./mimemsg_test
```

A do `clean` doplň `mimemsg_test`:

```make
clean:
	rm -f *.o $(ALL_TOOLS) mimemsg_test
```

- [ ] **Step 4: Spusť test, ověř že padá**

Na Pi:

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  'cd ~/fotopast/test_files && make hosttest'
```

Expected: FAIL — `mimemsg.c: No such file or directory`.

- [ ] **Step 5: Napiš `mimemsg.c`**

Vytvoř `test_files/mimemsg.c`.

**Nejdřív přenes dvě funkce doslova z `mailsend.c`:** `b64_encode` (začíná pod komentářem `/* --------- base64 */` kolem řádku 45) a `basename_of` (kolem řádku 210). Zkopíruj je znak po znaku i s komentáři, nepřepisuj je po paměti — base64 se ladí špatně a tenhle kód roky funguje. V `mailsend.c` je zatím nech, smažou se až v Tasku 3.

Zbytek souboru:

```c
/* mimemsg.c - viz mimemsg.h */
#include <stdio.h>
#include <string.h>
#include "mimemsg.h"

/* Boundary je konstantni. Nahodny by nic nepridal: zpravy nejsou
 * vnorene a obsah prilohy je base64, takze se s nim boundary nemuze
 * potkat. */
static const char *BOUNDARY = "hunter-XBOUND-8f2a";

/* --- sem prijdou b64_encode a basename_of, doslova zkopirovane
 *     z mailsend.c (viz text kroku vyse) --- */

static int put(mimemsg_sink sink, void *ctx, const char *s)
{
    return sink(s, strlen(s), ctx);
}

/* Telo po radcich, s normalizaci na CRLF. ZADNY dot-stuffing - ten
 * patri SMTP, viz mimemsg_dotstuff_sink. */
static int emit_text(const char *text, mimemsg_sink sink, void *ctx)
{
    const char *p = text;

    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char line[1024];

        if (len > sizeof(line) - 4) len = sizeof(line) - 4;
        memcpy(line, p, len);
        line[len] = '\0';
        /* useknout pripadny \r na konci, doplnime vlastni CRLF */
        if (len > 0 && line[len - 1] == '\r') line[len - 1] = '\0';
        if (put(sink, ctx, line) < 0) return -1;
        if (put(sink, ctx, "\r\n") < 0) return -1;

        if (!nl) break;
        p = nl + 1;
    }
    return 0;
}

/* 57 vstupnich bajtu = 76 znaku base64, tedy pod limitem 998 znaku
 * z RFC 5322. */
static int emit_base64_file(FILE *f, mimemsg_sink sink, void *ctx)
{
    unsigned char in[57];
    char out[80];
    size_t n;

    while ((n = fread(in, 1, sizeof(in), f)) > 0) {
        b64_encode(in, n, out);
        if (put(sink, ctx, out) < 0) return -1;
        if (put(sink, ctx, "\r\n") < 0) return -1;
    }
    return 0;
}

int mimemsg_emit(const struct mimemsg *m, mimemsg_sink sink, void *ctx)
{
    char line[1024];

    snprintf(line, sizeof(line),
             "From: <%s>\r\n"
             "To: <%s>\r\n"
             "Subject: %s\r\n",
             m->from, m->to, m->subject);
    if (put(sink, ctx, line) < 0) return -1;

    if (m->date) {
        snprintf(line, sizeof(line), "Date: %s\r\n", m->date);
        if (put(sink, ctx, line) < 0) return -1;
    }

    snprintf(line, sizeof(line),
             "MIME-Version: 1.0\r\n"
             "Content-Type: multipart/mixed; boundary=\"%s\"\r\n"
             "\r\n"
             "--%s\r\n"
             "Content-Type: text/plain; charset=us-ascii\r\n"
             "Content-Transfer-Encoding: 7bit\r\n"
             "\r\n",
             BOUNDARY, BOUNDARY);
    if (put(sink, ctx, line) < 0) return -1;

    if (emit_text(m->body ? m->body : "", sink, ctx) < 0) return -1;

    if (m->attach) {
        FILE *f = fopen(m->attach, "rb");
        if (!f) {
            fprintf(stderr, "mimemsg: prilohu %s nelze otevrit, posilam bez ni\n",
                    m->attach);
        } else {
            int rc;
            snprintf(line, sizeof(line),
                     "\r\n--%s\r\n"
                     "Content-Type: image/jpeg; name=\"%s\"\r\n"
                     "Content-Transfer-Encoding: base64\r\n"
                     "Content-Disposition: attachment; filename=\"%s\"\r\n"
                     "\r\n",
                     BOUNDARY, basename_of(m->attach), basename_of(m->attach));
            if (put(sink, ctx, line) < 0) { fclose(f); return -1; }
            rc = emit_base64_file(f, sink, ctx);
            fclose(f);
            if (rc < 0) return -1;
        }
    }

    snprintf(line, sizeof(line), "\r\n--%s--\r\n", BOUNDARY);
    return put(sink, ctx, line);
}

/* sink, ktery jen scita delky */
static int count_sink(const char *buf, size_t len, void *ctx)
{
    (void)buf;
    *(size_t *)ctx += len;
    return 0;
}

int mimemsg_size(const struct mimemsg *m, size_t *out)
{
    size_t n = 0;
    if (mimemsg_emit(m, count_sink, &n) < 0) return -1;
    *out = n;
    return 0;
}

int mimemsg_dotstuff_sink(const char *buf, size_t len, void *ctx)
{
    struct mimemsg_dotstuff *d = ctx;
    size_t i, start = 0;

    for (i = 0; i < len; i++) {
        if (d->at_line_start && buf[i] == '.') {
            /* vysypat, co je pred teckou, pak tecku zdvojit */
            if (i > start && d->inner(buf + start, i - start, d->inner_ctx) < 0)
                return -1;
            if (d->inner(".", 1, d->inner_ctx) < 0) return -1;
            start = i;
        }
        d->at_line_start = (buf[i] == '\n');
    }
    if (len > start && d->inner(buf + start, len - start, d->inner_ctx) < 0)
        return -1;
    return 0;
}
```

- [ ] **Step 6: Spusť nativní test, ověř že prochází**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  'cd ~/fotopast/test_files && make hosttest'
```

Expected: všechny řádky `OK`, `selhalo: 0`, návratový kód 0.

- [ ] **Step 7: Commit**

```bash
git add test_files/mimemsg.h test_files/mimemsg.c test_files/mimemsg_test.c test_files/Makefile
git commit -m "$(printf 'feat: mimemsg - sdilena stavba MIME zpravy do sinku\n\nTutez zpravu budou potrebovat dve binarky: mailsend do SMTP DATA,\nmailrecv do IMAP APPEND. Kopie by se rozesly - stejny duvod, proc uz\ndrive vznikl tlsnet.c.\n\nGenerator emituje cistou zpravu; dot-stuffing je ramovani SMTP a dela\nho az mimemsg_dotstuff_sink. Datum se predava zvenci, aby pocitaci a\nzapisovaci pruchod daly stejny vysledek - na tom stoji IMAP literal.\n\nZatim to nikdo nepouziva, prepojeni prijde v dalsim tasku.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"
```

---

### Task 3: `mailsend` používá `mimemsg`

Spec 5.1. Čistý refaktor — chování `mailsend` se nesmí změnit ani o bajt kromě toho, že zprávu staví někdo jiný.

**Files:**
- Modify: `test_files/mailsend.c`
- Modify: `test_files/Makefile` (linkovat `mimemsg.o`)

**Interfaces:**
- Consumes: `mimemsg_emit`, `struct mimemsg`, `struct mimemsg_dotstuff`, `mimemsg_dotstuff_sink` z Tasku 2.
- Produces: nic nového pro další tasky; `mailsend` si drží dnešní argumenty i chování.

- [ ] **Step 1: Přepoj `mailsend.c` na `mimemsg`**

V `test_files/mailsend.c`:

1. Přidej `#include "mimemsg.h"`.
2. **Smaž** `send_text_dotstuffed`, `send_base64_file` a proměnnou `boundary` — nahradil je `mimemsg`.
3. **Smaž i `b64_encode` a `basename_of`** — Task 2 je přenesl do `mimemsg.c` a tady zůstaly jen dočasně. Když je používá ještě něco jiného, překlad to ohlásí a teprve pak je nech.
4. Bloky mezi `DATA` a závěrečnou tečkou (dnes řádky ~355-393) nahraď:

```c
    code = smtp_cmd(rbuf, sizeof(rbuf), "DATA\r\n");
    expect(code, 3, "DATA", rbuf);

    rfc_date(datebuf, sizeof(datebuf));

    {
        struct mimemsg m;
        struct mimemsg_dotstuff ds;

        memset(&m, 0, sizeof(m));
        m.from = from;
        m.to = to;
        m.subject = subject;
        m.body = body;
        m.attach = attach;
        m.date = datebuf;

        ds.inner = smtp_sink;
        ds.inner_ctx = NULL;
        ds.at_line_start = 1;

        if (mimemsg_emit(&m, mimemsg_dotstuff_sink, &ds) < 0)
            tlsnet_die(1, "zpravu se nepodarilo odeslat");
    }

    /* Ukoncovaci tecka je ramovani SMTP, ne soucast zpravy - proto
     * ji pridava mailsend, ne mimemsg. */
    tlsnet_write("\r\n.\r\n", 5);

    code = smtp_read_reply(rbuf, sizeof(rbuf));
    expect(code, 2, "konec DATA", rbuf);
```

5. Přidej sink, který zapisuje do soketu. **Musí být v souboru nad místem, kde ho použiješ** (C potřebuje deklaraci před použitím) — dej ho k ostatním statickým funkcím před `main`:

```c
/* Sink pro mimemsg: zapisuje rovnou do TLS spojeni. */
static int smtp_sink(const char *buf, size_t len, void *ctx)
{
    (void)ctx;
    tlsnet_write(buf, len);
    return 0;
}
```

- [ ] **Step 2: Uprav Makefile**

V `test_files/Makefile` nahraď pravidlo pro `mailsend`:

```make
mimemsg.o: mimemsg.c mimemsg.h
	$(CC) $(CFLAGS) -c -o $@ $<

mailsend: mailsend.c tlsnet.o mimemsg.o
	@test -d "$(MBEDTLS)/include" || \
	  { echo "chybi mbedTLS v $(MBEDTLS) - spust nejdriv ./build.sh"; exit 1; }
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -o $@ mailsend.c tlsnet.o mimemsg.o \
	  -L"$(MBEDTLS)/lib" -lmbedtls -lmbedx509 -lmbedcrypto $(LDFLAGS)
```

- [ ] **Step 3: Přelož a ověř, že je to bez varování**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  'cd ~/fotopast/test_files && make mailsend 2>&1 | tail -20'
```

Expected: překlad projde, **žádné varování** (`CFLAGS` má `-Wall -Wextra`). Varování je nález, ne šum.

- [ ] **Step 4: Ověř, že ve zdrojáku nezůstal mrtvý kód**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  'cd ~/fotopast/test_files && grep -n "send_text_dotstuffed\|send_base64_file\|boundary" mailsend.c'
```

Expected: žádný výstup. Když něco zbylo, buď se to nesmazalo, nebo to `mimemsg` nepřevzal.

- [ ] **Step 5: Spusť nativní test i celou shellovou sadu**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  'cd ~/fotopast/test_files && make hosttest'
sh tests/run_tests.sh
```

Expected: `selhalo: 0`, a všechny shellové sady zelené (ty na `mailsend` používají falešnou binárku, takže je refaktor nemá potkat — a když je potká, je to nález).

- [ ] **Step 6: Commit**

```bash
git add test_files/mailsend.c test_files/Makefile
git commit -m "$(printf 'refactor: mailsend stavi zpravu pres mimemsg\n\nCiste prepojeni, chovani mailsend se nemeni. Dot-stuffing a ukoncovaci\ntecku si mailsend drzi jako sve ramovani SMTP - do sdilene zpravy\nnepatri, jinak by se kazda ulozena zprava s radkem zacinajicim teckou\nv IMAP slozce poskodila.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"
```

---

### Task 4: `append` v `mailrecv`

Spec 6. `mailrecv.c` už má celou IMAP session — přihlášení, tagy, čekání na odpověď, quoting. Přibývá jeden příkaz.

**Files:**
- Modify: `test_files/mailrecv.c`
- Modify: `test_files/Makefile` (linkovat `mimemsg.o`)

**Interfaces:**
- Consumes: `mimemsg_emit`, `mimemsg_size`, `struct mimemsg` z Tasku 2.
- Produces: příkaz `mailrecv <host> <port> <user> [--pass-file F] [--ca F] append <slozka> --from A --to B --subject S --body T [--attach F]`. Konzumuje Task 5.

- [ ] **Step 1: Přidej parsování argumentů `append`**

V `test_files/mailrecv.c` přidej `#include "mimemsg.h"` a za dnešní rozskok na `cmd` doplň proměnné a jejich načtení. Dnešní kód bere `cmd` a jeden `arg`; `append` potřebuje víc:

```c
    /* append ma vlastni pojmenovane argumenty - dnesni cmd/arg na to
     * nestaci. */
    const char *ap_from = NULL, *ap_to = NULL, *ap_subject = NULL;
    const char *ap_body = "", *ap_attach = NULL;

    if (!strcmp(cmd, "append")) {
        int k;
        for (k = i + 1; k < argc; k++) {
            if (!strcmp(argv[k], "--from") && k + 1 < argc)         ap_from = argv[++k];
            else if (!strcmp(argv[k], "--to") && k + 1 < argc)      ap_to = argv[++k];
            else if (!strcmp(argv[k], "--subject") && k + 1 < argc) ap_subject = argv[++k];
            else if (!strcmp(argv[k], "--body") && k + 1 < argc)    ap_body = argv[++k];
            else if (!strcmp(argv[k], "--attach") && k + 1 < argc)  ap_attach = argv[++k];
        }
        if (!arg || !ap_from || !ap_to || !ap_subject) { usage(); return 3; }
    }
```

- [ ] **Step 2: Přeskoč `SELECT INBOX` pro `append`**

`mailrecv.c` dnes volá `select_inbox()` bezpodmínečně před rozskokem na příkaz. `APPEND` ho nepotřebuje a jeho selhání by zbytečně shodilo uložení. Nahraď:

```c
    /* APPEND pracuje s cizi slozkou a zadny SELECT nepotrebuje. Kdyby
     * se delal, selhani SELECTu na INBOXu by shodilo i ukladani, ktere
     * s INBOXem nema nic spolecneho. */
    if (strcmp(cmd, "append") != 0) {
        if (select_inbox() != 0)
            tlsnet_die(1, "SELECT INBOX selhal");
    }
```

- [ ] **Step 3: Doplň větev `append`**

Za dnešní větve `list` a `seen` přidej:

```c
    } else if (!strcmp(cmd, "append")) {
        struct mimemsg m;
        size_t msgsz = 0;
        char qf[512];
        char line[LINE_SZ];

        memset(&m, 0, sizeof(m));
        m.from = ap_from;
        m.to = ap_to;
        m.subject = ap_subject;
        m.body = ap_body;
        m.attach = ap_attach;
        /* Datum necháváme na serveru - hodiny zarizeni nemaji zalohu a
         * INTERNALDATE ze serveru je spolehlivejsi. */
        m.date = NULL;

        imap_quote(arg, qf, sizeof(qf));

        /* Slozku zaloz, kdyz neni. Chyba "uz existuje" je v poradku -
         * IMAP na ni nema zvlastni kod, takze se navratovy kod ignoruje
         * zamerne a pripadny skutecny problem se projevi az na APPEND. */
        next_tag(tag, sizeof(tag));
        imap_send(tag, "CREATE %s", qf);
        (void)imap_wait_tag(tag);

        if (mimemsg_size(&m, &msgsz) != 0)
            tlsnet_die(1, "zpravu se nepodarilo spocitat");

        /* Zadny seznam priznaku za nazvem slozky: zprava se ulozi bez
         * \Seen, takze se ve slozce tvari jako nova. Hunter tu slozku
         * nikdy neprochazi, takze to nic nerozbije. */
        next_tag(tag, sizeof(tag));
        imap_send(tag, "APPEND %s {%lu}", qf, (unsigned long)msgsz);

        /* Synchronizujici literal: server musi odpovedet "+", teprve
         * pak se posilaji data. Na LITERAL+ se nespolehame, server ho
         * nemusi umet. */
        if (imap_readline(line, sizeof(line)) < 0 || line[0] != '+')
            tlsnet_die(1, "server neprijal APPEND literal");

        if (mimemsg_emit(&m, append_sink, NULL) != 0)
            tlsnet_die(1, "zpravu se nepodarilo odeslat");
        tlsnet_write("\r\n", 2);

        rc = imap_wait_tag(tag) == 0 ? 0 : 1;
        if (rc != 0) fprintf(stderr, "mailrecv: APPEND odmitnut\n");
```

A sink — **v souboru nad `main`**, aby byl deklarovaný dřív, než ho větev `append` použije:

```c
/* Sink pro mimemsg: zapisuje rovnou do TLS spojeni. */
static int append_sink(const char *buf, size_t len, void *ctx)
{
    (void)ctx;
    tlsnet_write(buf, len);
    return 0;
}
```

- [ ] **Step 4: Doplň `append` do nápovědy**

Ve funkci `usage()` v `mailrecv.c` přidej řádek s novým příkazem, ve stejném stylu jako stávající:

```
"         append <slozka> --from A --to B --subject S [--body T] [--attach F]\n"
```

- [ ] **Step 5: Uprav Makefile**

```make
mailrecv: mailrecv.c tlsnet.o mimemsg.o
	@test -d "$(MBEDTLS)/include" || \
	  { echo "chybi mbedTLS v $(MBEDTLS) - spust nejdriv ./build.sh"; exit 1; }
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -o $@ mailrecv.c tlsnet.o mimemsg.o \
	  -L"$(MBEDTLS)/lib" -lmbedtls -lmbedx509 -lmbedcrypto $(LDFLAGS)
```

- [ ] **Step 6: Přelož obě binárky, ověř nulová varování**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  'cd ~/fotopast/test_files && make mail 2>&1 | tail -20'
```

Expected: obě binárky se přeloží, žádné varování.

- [ ] **Step 7: Ověř, že `append` opravdu nedělá `SELECT INBOX`**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  'cd ~/fotopast/test_files && grep -n -B3 "select_inbox()" mailrecv.c'
```

Expected: volání je uvnitř podmínky, která `append` vynechává. Kdyby bylo bezpodmínečné, Step 2 se neprovedl.

- [ ] **Step 8: Commit**

```bash
git add test_files/mailrecv.c test_files/Makefile
git commit -m "$(printf 'feat: mailrecv umi append do slozky\n\nUlozeni zpravy pres IMAP APPEND na tentyz ucet. Session, tagy i quoting\nuz v mailrecv byly, pribyva prikaz a stavba zpravy pres mimemsg.\n\nVelikost literalu se zjisti pocitacim pruchodem generatoru, takze se\nfotka nemusi drzet v pameti. Literal je synchronizujici - na LITERAL+\nse nespolehame. Datum nechavame stampnout server, hodiny zarizeni\nnemaji zalohu.\n\nappend zamerne preskakuje SELECT INBOX: pracuje s cizi slozkou a\nselhani SELECTu by shodilo ukladani, ktere s INBOXem nesouvisi.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"
```

---

### Task 5: Dispečer v shellu

Spec 4 a 4.1. Tady se to spojí dohromady.

**Files:**
- Modify: `hunter/lib/mail.sh` (nový `send_message`, `send_via_smtp`, `send_via_imap`; `send_snap` a `send_reply_mail` přes ně)
- Modify: `tests/fixture_subprocess.sh` (falešný `mailrecv` se naučí `append`)
- Modify: `tests/test_transport.sh` (testy dispečera)

**Interfaces:**
- Consumes: `SEND_TRANSPORT` a `IMAP_SAVE_FOLDER` z Tasku 1; `mailrecv append` z Tasku 4; `mailrecv_run` z `hunter/lib/mailcmd.sh` (existuje).
- Produces: `send_message <komu> <predmet> <telo> [priloha]` → 0, když uspěl aspoň jeden zvolený transport. `send_snap` a `send_reply_mail` si drží dnešní signaturu i význam návratového kódu.

- [ ] **Step 1: Nauč falešný `mailrecv` příkaz `append`**

V `tests/fixture_subprocess.sh` nahraď blok falešného `mailrecv`:

```sh
    # mailrecv cte z $FIX/mail_listing.txt (vychozi prazdny = zadny mail)
    : > "$FIX/mail_listing.txt"
    cat > "$HDIR/bin/mailrecv" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/mail_listing.txt" 2>/dev/null; exit 0 ;;
    seen) shift; echo "\$@" >> "$FIX/mail_seen.log"; exit 0 ;;
    append) echo "\$@" >> "$FIX/append.log"; exit \$(cat "$FIX/append_rc" 2>/dev/null || echo 0) ;;
  esac
done
exit 0
EOF
    chmod +x "$HDIR/bin/mailrecv"
```

A do `subproc_fixture_setup` k ostatním výchozím souborům přidej:

```sh
    : > "$FIX/append.log"
```

Tentýž mechanismus přidej i falešnému `mailsend`, ať jde nechat selhat:

```sh
    cat > "$HDIR/bin/mailsend" <<EOF
#!/bin/sh
echo "\$@" >> "$FIX/mailsend.log"
exit \$(cat "$FIX/mailsend_rc" 2>/dev/null || echo 0)
EOF
    chmod +x "$HDIR/bin/mailsend"
```

- [ ] **Step 2: Napiš padající testy dispečera**

Do `tests/test_transport.sh` přidej před `fixture_teardown`:

```sh
# --- dispecer ---
# Falesne transporty: misto binarek jen zapisuji, ze byly zavolany, a
# vraci navratovy kod z promenne. Testuje se rozhodovani, ne odesilani.
SMTP_CALLS=""; IMAP_CALLS=""
SMTP_RC=0; IMAP_RC=0
send_via_smtp() { SMTP_CALLS="$SMTP_CALLS smtp"; return "$SMTP_RC"; }
send_via_imap() { IMAP_CALLS="$IMAP_CALLS imap"; return "$IMAP_RC"; }

reset_calls() { SMTP_CALLS=""; IMAP_CALLS=""; SMTP_RC=0; IMAP_RC=0; }

# smtp: jen SMTP
reset_calls; SEND_TRANSPORT=smtp
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp: uspech" "$r" "0"
assert_eq "smtp: volan SMTP" "$SMTP_CALLS" " smtp"
assert_eq "smtp: IMAP nevolan" "$IMAP_CALLS" ""

# imap: jen IMAP
reset_calls; SEND_TRANSPORT=imap
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "imap: uspech" "$r" "0"
assert_eq "imap: SMTP nevolan" "$SMTP_CALLS" ""
assert_eq "imap: volan IMAP" "$IMAP_CALLS" " imap"

# smtp-imap: kdyz SMTP projde, IMAP se NEvola
reset_calls; SEND_TRANSPORT=smtp-imap
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp-imap pri uspechu: uspech" "$r" "0"
assert_eq "smtp-imap pri uspechu: IMAP nevolan" "$IMAP_CALLS" ""

# smtp-imap: kdyz SMTP selze, pouzije se IMAP
reset_calls; SEND_TRANSPORT=smtp-imap; SMTP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp-imap pri selhani: uspech pres IMAP" "$r" "0"
assert_eq "smtp-imap pri selhani: IMAP volan" "$IMAP_CALLS" " imap"

# smtp-imap: kdyz selzou oba, selhani
reset_calls; SEND_TRANSPORT=smtp-imap; SMTP_RC=1; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp-imap oba selhaly: selhani" "$r" "1"

# imap-smtp: obracene poradi
reset_calls; SEND_TRANSPORT=imap-smtp; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "imap-smtp pri selhani IMAP: uspech pres SMTP" "$r" "0"
assert_eq "imap-smtp: SMTP volan" "$SMTP_CALLS" " smtp"

# smtp+imap: oba vzdy
reset_calls; SEND_TRANSPORT=smtp+imap
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp+imap: uspech" "$r" "0"
assert_eq "smtp+imap: volan SMTP" "$SMTP_CALLS" " smtp"
assert_eq "smtp+imap: volan IMAP" "$IMAP_CALLS" " imap"

# smtp+imap: uspech SMTP a selhani IMAP se PORAD pocita za odeslane -
# jinak by vypadek IMAPu poslal fotku, kterou uzivatel uz ma, znovu a
# znovu (spec 4.1)
reset_calls; SEND_TRANSPORT=smtp+imap; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp+imap: staci jeden uspech" "$r" "0"
assert_eq "smtp+imap: presto se zkusily oba" "$IMAP_CALLS" " imap"

# smtp+imap: oba selhaly
reset_calls; SEND_TRANSPORT=smtp+imap; SMTP_RC=1; IMAP_RC=1
send_message "a@b.c" "predmet" "telo" && r=0 || r=1
assert_eq "smtp+imap oba selhaly: selhani" "$r" "1"

# --- odpovedi na prikazy jdou stejnym kanalem jako fotky (spec 3) ---
# Kdyby send_reply_mail volalo mailsend primo, nastaveni by se rozeslo
# na dve poloviny a pri zablokovanem SMTP by uzivatel neprisel jen o
# fotky, ale i o zpetnou vazbu, jestli prikaz vubec probehl.
reset_calls; SEND_TRANSPORT=imap
send_reply_mail "a@b.c" "BAT:74%" && r=0 || r=1
assert_eq "odpoved pri imap: uspech" "$r" "0"
assert_eq "odpoved pri imap: SMTP nevolan" "$SMTP_CALLS" ""
assert_eq "odpoved pri imap: volan IMAP" "$IMAP_CALLS" " imap"

reset_calls; SEND_TRANSPORT=smtp
send_reply_mail "a@b.c" "BAT:74%" && r=0 || r=1
assert_eq "odpoved pri smtp: volan SMTP" "$SMTP_CALLS" " smtp"
assert_eq "odpoved pri smtp: IMAP nevolan" "$IMAP_CALLS" ""
```

- [ ] **Step 3: Spusť test, ověř že padá**

Run: `dash tests/test_transport.sh`
Expected: FAIL — `send_message: not found`.

- [ ] **Step 4: Napiš dispečera v `mail.sh`**

V `hunter/lib/mail.sh` nahraď dnešní `send_snap` a `send_reply_mail` a přidej nad ně dispečera:

```sh
# send_via_smtp <komu> <predmet> <telo> [priloha]
send_via_smtp() {
    if [ -n "$4" ]; then
        mailsend_run \
            --host "$SMTP_HOST" --port "$SMTP_PORT" \
            --user "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
            --to "$1" --subject "$2" --body "$3" --attach "$4" \
            --tls "$SMTP_TLS" \
            >> "$LOG_FILE" 2>&1
    else
        mailsend_run \
            --host "$SMTP_HOST" --port "$SMTP_PORT" \
            --user "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
            --to "$1" --subject "$2" --body "$3" \
            --tls "$SMTP_TLS" \
            >> "$LOG_FILE" 2>&1
    fi
}

# send_via_imap <komu> <predmet> <telo> [priloha]
# Ulozi zpravu pres IMAP APPEND do IMAP_SAVE_FOLDER na tomtez uctu.
# Neni to odeslani - zprava se objevi ve slozce, ne ve schrance.
send_via_imap() {
    if [ -n "$4" ]; then
        mailrecv_run append "$IMAP_SAVE_FOLDER" \
            --from "$SMTP_USER" --to "$1" --subject "$2" --body "$3" \
            --attach "$4" \
            >> "$LOG_FILE" 2>&1
    else
        mailrecv_run append "$IMAP_SAVE_FOLDER" \
            --from "$SMTP_USER" --to "$1" --subject "$2" --body "$3" \
            >> "$LOG_FILE" 2>&1
    fi
}

# send_message <komu> <predmet> <telo> [priloha]
# Odesle zpravu podle SEND_TRANSPORT. Vraci 0, kdyz uspel ASPON JEDEN
# zvoleny transport (spec 4.1) - kdyby se u smtp+imap vyzadovaly oba,
# vypadek IMAPu by donekonecna preposilal fotku, kterou uzivatel uz ma.
send_message() {
    case "$SEND_TRANSPORT" in
        smtp)
            send_via_smtp "$1" "$2" "$3" "$4"
            ;;
        imap)
            send_via_imap "$1" "$2" "$3" "$4"
            ;;
        smtp-imap)
            send_via_smtp "$1" "$2" "$3" "$4" && return 0
            log "SMTP selhalo, zkousim ulozit pres IMAP"
            send_via_imap "$1" "$2" "$3" "$4"
            ;;
        imap-smtp)
            send_via_imap "$1" "$2" "$3" "$4" && return 0
            log "IMAP selhalo, zkousim poslat mailem"
            send_via_smtp "$1" "$2" "$3" "$4"
            ;;
        smtp+imap)
            _sm_ok=1
            send_via_smtp "$1" "$2" "$3" "$4" && _sm_ok=0
            send_via_imap "$1" "$2" "$3" "$4" && _sm_ok=0
            return "$_sm_ok"
            ;;
        *)
            # validate_transport tohle nema propustit; kdyby ano, at to
            # aspon nekonci tise.
            log "SEND_TRANSPORT neznama hodnota v send_message, pouzivam smtp"
            send_via_smtp "$1" "$2" "$3" "$4"
            ;;
    esac
}
```

Pak přepiš `send_snap` tak, aby zůstala jeho dnešní logika sestavení a jen odeslání šlo přes dispečera:

```sh
send_snap() {
    snap_path="$1"
    fname=$(basename "$snap_path")
    daydir=$(basename "$(dirname "$snap_path")")
    hhmmss="${fname%%_*}"
    subject=$(format_subject "$daydir" "$hhmmss")
    body=$(build_status_body)
    attach_path=$(resolve_attach_path "$snap_path" "$daydir" "$fname")
    log "kvalita: QUALITY=$QUALITY, priloha=$attach_path"

    send_message "$SMTP_TO" "$subject" "$body" "$attach_path"
}
```

A `send_reply_mail`:

```sh
send_reply_mail() {
    send_message "$1" "HUNTER reply" "$2"
}
```

- [ ] **Step 5: Spusť test, ověř že prochází**

Run: `dash tests/test_transport.sh`
Expected: PASS, všechny asserty včetně dispečera.

- [ ] **Step 6: Napiš test skutečného běhu — fallback a `sent_list.txt`**

Testy výše ověřují rozhodování dispečera na úrovni funkcí. Spec sekce 8 ale žádá i to, že se fotka při fallbacku zapíše do `sent_list.txt` **právě jednou** — a to je vlastnost těla `hunter.sh`, které nejde nasourcovat. Musí se pustit skutečný proces.

Do `tests/test_queue_wake.sh` přidej na konec (soubor dnes obsahuje scénáře A-H, tvůj bude **I**; nepřeznačuj stávající):

```sh
# --- I: SMTP selze, fotka se ulozi pres IMAP a do sent_list.txt se
# dostane PRAVE JEDNOU (spec 4.1 + 8) ---
subproc_fixture_setup 8
subproc_mk_snap 260828 010000

# SEND_TRANSPORT se do configu dopisuje az tady, aby ostatni scenare
# jely na vychozim smtp.
printf 'SEND_TRANSPORT=smtp-imap\nIMAP_SAVE_FOLDER=Fotopast\n' >> "$HDIR/config.txt"
# mailsend selze, mailrecv append projde
echo 1 > "$FIX/mailsend_rc"

subproc_run_hunter

sl=$(cat "$STATE_DIR/sent_list.txt" 2>/dev/null)
ap=$(cat "$FIX/append.log" 2>/dev/null)

assert_contains "I: SMTP se zkusilo" "$(cat "$FIX/mailsend.log")" "010000"
assert_contains "I: po selhani SMTP se ulozilo pres IMAP append" "$ap" "Fotopast"
assert_contains "I: fotka je v sent_list" "$sl" "010000"
assert_eq "I: v sent_list je PRAVE JEDEN zaznam" \
    "$(printf '%s\n' "$sl" | grep -c '010000')" "1"

subproc_fixture_teardown
```

- [ ] **Step 7: Spusť test skutečného běhu**

Run: `dash tests/test_queue_wake.sh`
Expected: PASS včetně scénáře I.

- [ ] **Step 8: Spusť celou sadu**

Run: `sh tests/run_tests.sh`
Expected: všechny sady zelené. Stávající testy odesílání (`test_wake_send.sh`, `test_queue_wake.sh` scénáře A-H) mají `SEND_TRANSPORT` nenastavený, tedy výchozí `smtp` — musí projít beze změny. Kdyby nějaký spadl, je to nález: znamená to, že refaktor změnil chování výchozí cesty.

- [ ] **Step 9: Mutačně ověř, že test na `smtp+imap` není bezobsažný**

Dočasně změň ve `send_message` větev `smtp+imap` tak, aby vyžadovala oba úspěchy:

```sh
        smtp+imap)
            send_via_smtp "$1" "$2" "$3" "$4" || return 1
            send_via_imap "$1" "$2" "$3" "$4"
            ;;
```

Spusť `dash tests/test_transport.sh` — assert „smtp+imap: staci jeden uspech" **musí spadnout**. Pak mutaci vrať a ověř, že je sada zase zelená. Obojí zapiš do reportu. Bez téhle kontroly by test mohl procházet i s chybnou logikou a invariant ze spec 4.1 by nehlídal nic.

- [ ] **Step 10: Commit**

```bash
git add hunter/lib/mail.sh tests/fixture_subprocess.sh tests/test_transport.sh tests/test_queue_wake.sh
git commit -m "$(printf 'feat: dispecer odesilani podle SEND_TRANSPORT\n\nsend_snap i send_reply_mail jdou pres jednoho dispecera, takze jedno\nnastaveni ridi fotky i odpovedi a nemuzou se rozejit.\n\nUspech = aspon jeden zvoleny transport. U smtp+imap by vyzadovani obou\nzpusobilo, ze vypadek IMAPu donekonecna preposila fotku, kterou\nuzivatel uz ma - a to je presne ta salva, kvuli ktere blok vznikl.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"
```

---

### Task 6: Dokumentace a nasazení

**Files:**
- Modify: `hunter/README.md`
- Modify: `CHECKLIST.md`

- [ ] **Step 1: `hunter/README.md` — popis transportu**

Za odstavec o e-mailových příkazech přidej sekci:

```markdown
### Kudy fotky odcházejí

Výchozí je klasické odeslání mailem přes SMTP. `SEND_TRANSPORT` v
configu ale umí i uložit zprávu přes **IMAP APPEND** do složky na
tomtéž účtu (`IMAP_SAVE_FOLDER`, výchozí `Fotopast`) — buď místo mailu,
nebo jako záloha, když SMTP selže.

| Hodnota | Co dělá |
|---|---|
| `smtp` | jen mailem (výchozí, dosavadní chování) |
| `imap` | jen uložit do složky |
| `smtp-imap` | mailem; když SMTP selže, uložit do složky |
| `imap-smtp` | do složky; když IMAP selže, poslat mailem |
| `smtp+imap` | obojí vždy, dvě kopie |

**Proč to existuje:** odesílání SMTP přímo z mobilní SIM vypadá pro
operátora jako spam bot a O2 kvůli tomu jednou zablokovalo celou SIM,
data i volání. IMAP APPEND je totéž spojení na port 993, jaké zařízení
stejně dělá kvůli příkazům — heuristika nemá co chytit.

Nastavení platí **i pro odpovědi na příkazy**. Když je SMTP zablokované,
odpověď na `STATUS` se objeví ve složce.

**Příjem příkazů to neovlivňuje** — ten jde přes IMAP vždycky.

**Co za to:** zpráva uložená do složky nedorazí jako nová pošta, takže
nepřijde notifikace — do složky se musíš podívat. A uloží se jen na účet
fotopasti; `SMTP_TO` může být jiná adresa, ale `APPEND` umí jen tentýž
účet, přes který se přihlašuje.

`IMAP_SAVE_FOLDER` **nesmí být `INBOX`**: příkazy se hledají přes
`SEARCH UNSEEN` právě tam, takže by si Hunter vlastní uložené fotky
přečetl jako příchozí příkazy. Když tam INBOX napíšeš, kód ho odmítne
a použije `Fotopast`.
```

- [ ] **Step 2: `CHECKLIST.md` — nová fáze**

Za Fázi 9 přidej:

```markdown
## Fáze 10 — aktualizace: volitelný transport (2026-09-03)

- [ ] `sh /tmp/mnt/sdcard/hunter/dev-stop.sh 600` — **a pak pracovat
      svižně**. Historie z fáze 8: držet `ubia_first` mrtvý přes hodinu
      skončilo restart smyčkou vyvolanou MCU watchdogem.
- [ ] Vytáhnout kartu a **porovnat md5 všech** `hunter/*.sh`,
      `hunter/lib/*.sh` a `hunter/bin/*` proti repu; zkopírovat vše, co
      se liší. Tahle změna se dotýká `lib/common.sh`, `lib/mail.sh` a
      **obou binárek** `bin/mailsend` i `bin/mailrecv`.
- [ ] **Zkontrolovat `hunter/state/.lock`** — když tam je, smazat ho.
      Viz fáze 9, proč na to nezapomínat.
- [ ] Kartu vrátit, `dev-resume.sh`.
- [ ] **Nejdřív ověřit, že se nic nezměnilo.** Bez zásahu do configu je
      `SEND_TRANSPORT=smtp`, takže fotky musí chodit přesně jako dřív.
      Když nechodí, je chyba v refaktoru, ne v novém transportu.
- [ ] Teprve pak přepnout: do `hunter/config.txt` doplnit
      `SEND_TRANSPORT=smtp-imap` a `IMAP_SAVE_FOLDER=Fotopast`.
- [ ] Ostrý test uložení: dočasně zablokovat SMTP (např. `SMTP_PORT`
      přepsat na nepoužívaný port), počkat na fotku, pak se podívat do
      složky `Fotopast` v mailovém klientovi. Musí tam být zpráva
      s přílohou. Pak `SMTP_PORT` vrátit.
- [ ] `HUNTER <token> STATUS` → odpověď musí dorazit stejnou cestou jako
      fotky.
```

- [ ] **Step 3: Ověř, že v device souborech nezůstala diakritika**

```bash
LC_ALL=C grep -rln '[^ -~]' hunter/lib hunter/hunter.sh tests/*.sh
```

Expected: prázdný výstup. (`hunter/README.md` je z pravidla vyňatý — čte se na počítači a píše se česky s diakritikou.)

- [ ] **Step 4: Poslední běh celé sady**

Run: `sh tests/run_tests.sh`
Expected: všechny sady zelené.

- [ ] **Step 5: Commit**

```bash
git add hunter/README.md CHECKLIST.md
git commit -m "$(printf 'docs: volitelny transport - README a CHECKLIST faze 10\n\nNasazeni ma dva kroky zamerne: nejdriv overit, ze se s vychozim smtp\nnic nezmenilo, teprve pak prepnout. Kdyz fotky prestanou chodit uz v\nprvnim kroku, je chyba v refaktoru, ne v novem transportu.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"
```
