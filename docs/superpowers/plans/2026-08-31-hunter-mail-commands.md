# Hunter — e-mailové příkazy: implementační plán

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Přidat Hunterovi příchozí příkazový kanál přes e-mail (IMAP), který nahradí SMS příkazy nefunkční na tomto hardwaru.

**Architecture:** Jeden transportně nezávislý vykonavač příkazů (`hunter/lib/command.sh`) a dva transporty, které do něj ústí — stávající `sms.sh` a nový `mailcmd.sh`. Na straně C přibude `bin/mailrecv` (minimální IMAP klient) a sdílená síťová vrstva `tlsnet`, vytažená ze stávajícího `mailsend.c`. Celý příkaz se nese v předmětu zprávy, takže klient nikdy nestahuje těla ani přílohy.

**Tech Stack:** C99 staticky křížově překládaný pro mipsel (uClibc 0.9.33.2), mbedTLS 2.28.8, POSIX shell (busybox ash), IMAP4rev1 přes implicitní TLS.

**Spec:** [docs/superpowers/specs/2026-08-31-hunter-mail-commands-design.md](../specs/2026-08-31-hunter-mail-commands-design.md)

## Global Constraints

Platí pro **každou** úlohu v tomto plánu.

- **Busybox na zařízení NEMÁ** `awk`, `sed`, `cut`, `sort`, `uniq`, `wc`, `head`, `tail`, `expr`, `tee`, `bc`, `od`, `hexdump`, `nc`, `inotifyd`. K dispozici je jen: `case`, parametrická expanze `${v#...}`/`${v%...}`, `$(( ))`, `read`, `trap`, a z appletů `grep`/`fgrep`, `tr`, `printf`, `find`, `stat`, `df`, `dd`, `date`, `mkdir`, `mv`, `rm`, `cp`, `touch`, `sleep`, `kill`, `pidof`, `md5sum`, `tftp`.
- **`tr` jen s explicitními rozsahy** (`tr 'A-Z' 'a-z'`), nikdy s POSIX třídami (`[:lower:]`) — `FEATURE_TR_CLASSES` je v busyboxu volitelný a tenhle build je oříznutý.
- **Case-insensitivita přes `case` patterny** se znakovými třídami (`[Ss][Tt][Aa]…`), ne přes `tr`.
- **Signály vždy jménem** (`kill -STOP`, `kill -CONT`), nikdy číslem — MIPS má jiná čísla než x86/ARM.
- **Žádné doslovné tabulátory** v souborech, které jdou na zařízení — busybox ash je při přenosu přes UART požírá jako doplňování příkazů. Tab se tvoří přes `"$(printf '\t')"`. Viz `pi-tools/README.md`.
- **Bez diakritiky** ve všech řetězcích, které zařízení vypisuje nebo odesílá (ASCII only). Komentáře v kódu taky bez diakritiky, konzistentně se stávajícím kódem.
- **Křížový překlad:** `CFLAGS = -O2 -Wall -Wextra -std=gnu99 -static -mfp32`, `CROSS = mipsel-linux-gnu-`. `-mfp32` sladí FP ABI přesně s `ubia_first`.
- **Token se NIKDY nezaloguje ani nevrátí v odpovědi.** Odpovědi nikdy necitují příchozí předmět.
- **Selhání příkazového kanálu nikdy nesmí shodit odesílání fotek.** Fotky jsou primární funkce.
- **Nasazení binárek fyzicky přes čtečku karet**, ne přes UART heredoc.
- Build stroj je Raspberry Pi: `ssh -F C:/Users/Public/fotopast/.ssh/config fotopast-build`. Zdrojáky v `~/fotopast/`.

---

### Task 1: Inicializace gitu

Bez verzování se v Tasku 3 refaktoruje `mailsend.c` — jediná prokazatelně funkční součást systému — bez možnosti návratu. `.gitignore` v repozitáři už existuje, jen se nikdy nespustil `git init`.

**Files:**
- Create: `.git/` (inicializace)
- Modify: `.gitignore`

- [ ] **Step 1: Ověřit, že opravdu není inicializovaný**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git rev-parse --is-inside-work-tree 2>&1 || echo "NENI REPO - pokracuj"
```

Expected: `fatal: not a git repository` → pokračuj. Pokud repo existuje, přeskoč na Step 3.

- [ ] **Step 2: Inicializovat**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git init
git branch -M main
```

- [ ] **Step 3: Doplnit `.gitignore` o nový soubor s tajemstvím**

Přidej na konec sekce se secrets (za řádek `hunter/smtp.pass`):

```
hunter/mail.token
```

- [ ] **Step 4: Zkontrolovat, co se chystá commitnout**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add -A
git status
```

Expected: **NESMÍ** tam být `hunter/config.txt`, `hunter/smtp.pass`, `hunter/mail.token`, `hunter/log.txt`, `test_files/build/`, `dump/`. Pokud `dump/` (firmware výpis, ~stovky MB) v seznamu je, přidej ho do `.gitignore` a `git reset` + `git add -A` znovu.

- [ ] **Step 5: První commit**

```bash
git commit -m "chore: initial commit - Hunter pred pridanim e-mailovych prikazu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Ověřit IMAP na Seznamu

Brána před vším ostatním: pokud Seznam nepustí IMAP s aplikačním heslem, celý návrh padá a nemá smysl psát řádek kódu. Zároveň to dá reálné odpovědi serveru, proti kterým se v Tasku 4–6 píše parser.

**Files:** žádné (jen ověření)

**Interfaces:**
- Produces: potvrzené `IMAP_HOST`/`IMAP_PORT` a ukázka reálných odpovědí serveru pro Task 4–6.

- [ ] **Step 1: Ověřit dostupnost portu z Raspberry**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  "openssl s_client -connect imap.seznam.cz:993 -crlf -quiet 2>/dev/null" </dev/null | head -3
```

Expected: uvítací řádek `* OK ...IMAP4rev1...`. Když spojení selže, zkus `imap.seznam.cz:143` se `-starttls imap` a zapiš zjištěné do Tasku 12 místo portu 993.

- [ ] **Step 2: Ověřit přihlášení aplikačním heslem**

Heslo je v `hunter/smtp.pass` na SD kartě. Zkopíruj ho na Pi do `~/imap.pass` (mimo repozitář) a spusť:

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
P=\$(cat ~/imap.pass)
printf \"a1 LOGIN fotopast.pajsti@seznam.cz %s\r\na2 SELECT INBOX\r\na3 UID SEARCH UNSEEN\r\na4 LOGOUT\r\n\" \"\$P\" |
openssl s_client -connect imap.seznam.cz:993 -crlf -quiet 2>/dev/null
"'
```

Expected: `a1 OK ... LOGIN completed`, `a2 OK [READ-WRITE] SELECT completed`, `* SEARCH ...`, `a3 OK`.

Když přijde `a1 NO`, aplikační heslo pro IMAP neplatí — zastav se a vyžádej si od uživatele heslo s povoleným IMAP přístupem. **Dál nepokračuj**, celý plán na tom stojí.

- [ ] **Step 3: Uložit ukázku odpovědi FETCH pro psaní parseru**

Pošli si do schránky testovací mail s předmětem `HUNTER testtoken STATUS`, pak:

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
P=\$(cat ~/imap.pass)
printf \"a1 LOGIN fotopast.pajsti@seznam.cz %s\r\na2 SELECT INBOX\r\na3 UID SEARCH UNSEEN\r\na4 UID FETCH * (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])\r\na5 LOGOUT\r\n\" \"\$P\" |
openssl s_client -connect imap.seznam.cz:993 -crlf -quiet 2>/dev/null
" ' | tee ~/imap-sample.txt
```

Expected: uvidíš tvar odpovědi s literálem, např.:
```
* 12 FETCH (UID 4711 BODY[HEADER.FIELDS (FROM SUBJECT)] {68}
From: Pavel <paja.stindl@seznam.cz>
Subject: HUNTER testtoken STATUS

)
a4 OK ...
```
Tenhle výstup je referencí pro Task 5. Zapiš si skutečné pořadí polí — některé servery vrací `BODY[...]` před `UID`.

- [ ] **Step 4: Commit poznámky**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
# zaznamenej overene hodnoty do specu, sekce 5
git add docs/
git commit -m "docs: overen IMAP pristup na Seznamu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Vytáhnout `tlsnet` z `mailsend.c`

Čistě mechanický přesun, žádná změna logiky. Akceptační podmínka je tvrdá: **po refaktoru musí `mailsend` pořád reálně doručit e-mail.**

**Files:**
- Create: `test_files/tlsnet.h`
- Create: `test_files/tlsnet.c`
- Modify: `test_files/mailsend.c` (odebrání přesunutých funkcí + `#include "tlsnet.h"`)
- Modify: `test_files/Makefile`

**Interfaces:**
- Produces: `tlsnet.h` — používá ho `mailsend.c` i `mailrecv.c` (Task 4).

- [ ] **Step 1: Vytvořit `test_files/tlsnet.h`**

```c
/* tlsnet.h - sdilena sitova vrstva pro mailsend a mailrecv.
 *
 * Vytazeno z mailsend.c, aby se DNS resolver, TCP connect a obsluha TLS
 * nemusely duplikovat. Stejny duvod, proc vznikl atport.c/h pro AT
 * nastroje.
 *
 * Drzi JEDNO spojeni v globalnim stavu - oba nastroje jsou jednorazove
 * a vic spojeni najednou nepotrebuji.
 */
#ifndef TLSNET_H
#define TLSNET_H

#include <stddef.h>

/* Jmeno programu do chybovych hlasek ("mailsend: ..."). */
void tlsnet_set_progname(const char *name);

/* Vypise hlasku na stderr a ukonci program s danym kodem. */
void tlsnet_die(int code, const char *msg);

/* Zapne vypis komunikace na stderr (prefixy "C: " a "S: "). */
void tlsnet_set_verbose(int on);

/* Prelozi hostname na IPv4 vlastnim DNS dotazem (obchazi glibc
 * getaddrinfo, ktery ve staticky linkovane binarce potrebuje NSS
 * moduly pres dlopen). Vraci 0 pri uspechu. */
int tlsnet_resolve(const char *host, char *ipbuf, size_t iplen);

/* Naveze TCP spojeni. Pri chybe vola tlsnet_die(). */
void tlsnet_connect(const char *host, const char *port);

/* Povysi existujici TCP spojeni na TLS. cafile smi byt NULL (pak se
 * certifikat serveru neoveruje - varuje se na stderr). */
void tlsnet_handshake(const char *host, const char *cafile);

/* Zapis/cteni. Automaticky posilaji pres TLS, pokud uz probehl
 * handshake, jinak pres holy socket. */
void tlsnet_write(const char *buf, size_t len);
int  tlsnet_read(char *buf, size_t len);

/* 1 kdyz uz bezi TLS. */
int tlsnet_is_tls(void);

void tlsnet_close(void);

#endif
```

- [ ] **Step 2: Vytvořit `test_files/tlsnet.c` přesunem funkcí**

Z `mailsend.c` **vyjmi** (ne zkopíruj) tyhle části a vlož do `tlsnet.c`:

- všechny `#include` pro mbedTLS a sockety
- globály `net_ctx`, `ssl_ctx`, `ssl_conf`, `entropy`, `ctr_drbg`, `cacert`, `use_tls`, `verbose`
- `die()` → přejmenuj na `tlsnet_die()`, prefix ber z nové statické proměnné `progname`
- `first_nameserver()`, `build_dns_query()`, `skip_dns_name()`, `dns_query_a()`, `resolve_ipv4()` → poslední přejmenuj na `tlsnet_resolve()`
- `net_connect_manual()` → `tlsnet_connect()`
- `tls_handshake()` → `tlsnet_handshake()`
- `io_write()` → `tlsnet_write()`, `io_read()` → `tlsnet_read()`

Přidej na začátek:

```c
#include "tlsnet.h"

static const char *progname = "tlsnet";

void tlsnet_set_progname(const char *name) { progname = name; }
void tlsnet_set_verbose(int on) { verbose = on; }
int  tlsnet_is_tls(void) { return use_tls; }

void tlsnet_die(int code, const char *msg)
{
    fprintf(stderr, "%s: %s\n", progname, msg);
    exit(code);
}
```

`IO_TIMEOUT_MS` a `RBUF_SZ` přesuň taky.

- [ ] **Step 3: Upravit `mailsend.c`**

Nahoře přidej `#include "tlsnet.h"`, odeber přesunuté funkce a globály. Všechna volání přejmenuj:

| Staré | Nové |
|---|---|
| `die(c, m)` | `tlsnet_die(c, m)` |
| `net_connect_manual(h, p)` | `tlsnet_connect(h, p)` |
| `tls_handshake(h, ca)` | `tlsnet_handshake(h, ca)` |
| `io_write(b, l)` | `tlsnet_write(b, l)` |
| `io_read(b, l)` | `tlsnet_read(b, l)` |
| `use_tls` | `tlsnet_is_tls()` |

V `main()` hned na začátku přidej:

```c
    tlsnet_set_progname("mailsend");
```

a tam, kde se zpracovává `-v`:

```c
        else if (!strcmp(argv[i], "-v")) { verbose = 1; tlsnet_set_verbose(1); }
```

- [ ] **Step 4: Upravit `Makefile`**

Nahraď pravidlo `mailsend` a přidej `tlsnet.o`:

```make
MAIL_TOOLS = mailsend mailrecv

tlsnet.o: tlsnet.c tlsnet.h
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -c -o $@ $<

mailsend: mailsend.c tlsnet.o
	@test -d "$(MBEDTLS)/include" || \
	  { echo "chybi mbedTLS v $(MBEDTLS) - spust nejdriv ./build.sh"; exit 1; }
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -o $@ mailsend.c tlsnet.o \
	  -L"$(MBEDTLS)/lib" -lmbedtls -lmbedx509 -lmbedcrypto $(LDFLAGS)
```

- [ ] **Step 5: Přeložit**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  "cd ~/fotopast/test_files && make mailsend 2>&1 | tail -20"
```

Expected: překlad bez chyb a bez varování o implicitních deklaracích.

- [ ] **Step 6: Přeložit mbedTLS nativně pro Pi**

Nativní build je potřeba pro Tasky 3–6: `mailsend` i `mailrecv` jsou
obyčejní TCP/TLS klienti, takže se dají odladit proti skutečnému serveru
přímo na Pi, bez nasazování na fotopast. Ušetří to většinu času.

**Vlastní zdrojový strom** (`mbedtls-src-native`), oddělený od
křížového — `make clean` ve sdíleném stromě by smazal mipsel objekty:

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
set -e
cd ~/fotopast/test_files
NAT=\$PWD/build/mbedtls-native
if [ -f \$NAT/lib/libmbedtls.a ]; then echo NATIVE_MBEDTLS_UZ_JE; exit 0; fi
mkdir -p \$NAT/include \$NAT/lib
if [ ! -d build/mbedtls-src-native ]; then
  git clone --depth 1 --branch v2.28.8 \
    https://github.com/Mbed-TLS/mbedtls.git build/mbedtls-src-native
fi
cd build/mbedtls-src-native
make -j4 lib CFLAGS=\"-O2 -fno-strict-aliasing\"
cp -r include/mbedtls \$NAT/include/
if [ -d include/psa ]; then cp -r include/psa \$NAT/include/; fi
cp library/libmbedtls.a library/libmbedx509.a library/libmbedcrypto.a \$NAT/lib/
echo NATIVE_MBEDTLS_OK
"'
```

Expected: `NATIVE_MBEDTLS_OK` (nebo `NATIVE_MBEDTLS_UZ_JE`).

Pozn.: `if [ -d ... ]; then ... fi` místo `[ -d ... ] && ...` je záměr —
pod `set -e` by neúspěšný test s `&&` ukončil celý skript.

- [ ] **Step 7: Regresní test — reálné odeslání**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
set -e
cd ~/fotopast/test_files
NAT=\$PWD/build/mbedtls-native
gcc -O2 -std=gnu99 -I\$NAT/include -o /tmp/mailsend_native mailsend.c tlsnet.c \
    -L\$NAT/lib -lmbedtls -lmbedx509 -lmbedcrypto
/tmp/mailsend_native --host smtp.seznam.cz --port 465 \
   --user fotopast.pajsti@seznam.cz --pass-file ~/imap.pass \
   --to paja.stindl@seznam.cz --subject \"tlsnet refaktor test\" \
   --body \"regresni test po vytazeni tlsnet\" --tls implicit
"'
```

Expected: `MAIL ODESLAN (250)` a **mail skutečně dorazí do schránky**.
Když nedorazí, refaktor se vrací (`git checkout test_files/`) a hledá se
chyba — dál se nepokračuje.

- [ ] **Step 8: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add test_files/tlsnet.c test_files/tlsnet.h test_files/mailsend.c test_files/Makefile
git commit -m "refactor: vytahnout sitovou vrstvu z mailsend do tlsnet

Overeno realnym odeslanim e-mailu po refaktoru.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `mailrecv` — kostra a přihlášení

**Files:**
- Create: `test_files/mailrecv.c`
- Modify: `test_files/Makefile`

**Interfaces:**
- Consumes: `tlsnet.h` z Tasku 3.
- Produces: `imap_readline()`, `imap_read_bytes()`, `imap_send()`, `next_tag()`, `imap_wait_tag()` — používá je Task 5 a 6.

- [ ] **Step 1: Napsat `test_files/mailrecv.c`**

```c
/* mailrecv.c - minimalni IMAP klient pro prikazovy kanal Hunteru.
 *
 * Cte JEN hlavicky (From, Subject) neprectenych zprav - cely prikaz se
 * nese v predmetu, takze tela ani prilohy nikdy nestahujeme. Tim odpada
 * parsovani MIME a dekodovani prenosovych kodovani.
 *
 * Pouziti:
 *   mailrecv <host> <port> <user> --pass-file <f> list unseen
 *   mailrecv <host> <port> <user> --pass-file <f> seen <uid>
 *
 * Vystup pro "list unseen", jeden radek na zpravu:
 *   MSG|<uid>|<odesilatel>|<predmet>
 *
 * Predmet je POSLEDNI pole zamerne - muze obsahovat "|" a shell ho
 * posbira pres `shift 3; subject="$*"`.
 *
 * Odesilatel se vraci VZDY malymi pismeny, aby porovnani v shellu
 * nemuselo resit velikost pismen.
 *
 * Navratovy kod: 0 = ok, 1 = chyba protokolu/prihlaseni, 2 = sit/TLS,
 *                3 = spatne argumenty.
 */
#include "tlsnet.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>

#define LINE_SZ 4096
#define INBUF_SZ 8192

static char inbuf[INBUF_SZ];
static size_t inlen = 0, inpos = 0;
static int tagseq = 0;

/* ----------------------------------------------------- ctecí vrstva */

static int raw_fill(void)
{
    int n;
    if (inpos > 0) {                 /* posun zbytek na zacatek */
        memmove(inbuf, inbuf + inpos, inlen - inpos);
        inlen -= inpos;
        inpos = 0;
    }
    if (inlen >= INBUF_SZ) return -1;
    n = tlsnet_read(inbuf + inlen, INBUF_SZ - inlen);
    if (n <= 0) return -1;
    inlen += (size_t)n;
    return n;
}

/* Precte jeden radek bez CRLF. Vraci delku, nebo -1 pri chybe. */
static int imap_readline(char *out, size_t outsz)
{
    size_t o = 0;
    for (;;) {
        while (inpos < inlen) {
            char c = inbuf[inpos++];
            if (c == '\n') {
                if (o > 0 && out[o - 1] == '\r') o--;
                out[o] = '\0';
                return (int)o;
            }
            if (o + 1 < outsz) out[o++] = c;
        }
        if (raw_fill() < 0) return -1;
    }
}

/* Precte presne n bajtu (IMAP literal {n}). */
static int imap_read_bytes(char *out, size_t n)
{
    size_t got = 0;
    while (got < n) {
        while (inpos < inlen && got < n) out[got++] = inbuf[inpos++];
        if (got < n && raw_fill() < 0) return -1;
    }
    return (int)got;
}

/* ----------------------------------------------------- odesilani */

static void next_tag(char *buf, size_t sz)
{
    snprintf(buf, sz, "a%d", ++tagseq);
}

static void imap_send(const char *tag, const char *fmt, ...)
{
    char line[LINE_SZ];
    va_list ap;
    size_t n;

    snprintf(line, sizeof(line), "%s ", tag);
    n = strlen(line);
    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    n = strlen(line);
    snprintf(line + n, sizeof(line) - n, "\r\n");

    tlsnet_write(line, strlen(line));
}

/* Je radek dokoncenim naseho tagu? */
static int is_tagged(const char *line, const char *tag)
{
    size_t t = strlen(tag);
    return strncmp(line, tag, t) == 0 && line[t] == ' ';
}

/* Skoncil tag OK? */
static int tag_ok(const char *line, const char *tag)
{
    return strncmp(line + strlen(tag) + 1, "OK", 2) == 0;
}

/* Cte radky az k dokonceni tagu. Vraci 0 = OK, 1 = NO/BAD, -1 = chyba. */
static int imap_wait_tag(const char *tag)
{
    char line[LINE_SZ];
    for (;;) {
        if (imap_readline(line, sizeof(line)) < 0) return -1;
        if (is_tagged(line, tag)) return tag_ok(line, tag) ? 0 : 1;
    }
}

/* ----------------------------------------------------- pomocne */

static char *read_pass_file(const char *path)
{
    static char buf[256];
    char err[300];
    FILE *f = fopen(path, "r");
    size_t n;

    if (!f) {
        snprintf(err, sizeof(err), "nelze otevrit --pass-file (%s)", path);
        tlsnet_die(3, err);
    }
    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' '))
        buf[--n] = '\0';
    if (n == 0) tlsnet_die(3, "--pass-file je prazdny");
    return buf;
}

/* IMAP quoted string: obalit uvozovkami, escapovat \ a " */
static void imap_quote(const char *in, char *out, size_t outsz)
{
    size_t o = 0;
    if (outsz < 3) { out[0] = '\0'; return; }
    out[o++] = '"';
    for (; *in && o + 2 < outsz - 1; in++) {
        if (*in == '"' || *in == '\\') out[o++] = '\\';
        out[o++] = *in;
    }
    out[o++] = '"';
    out[o] = '\0';
}

static void usage(void)
{
    fprintf(stderr,
        "pouziti: mailrecv <host> <port> <user> --pass-file <f> "
        "list unseen | seen <uid>\n");
}

/* ----------------------------------------------------- main */

int main(int argc, char **argv)
{
    const char *host, *port, *user, *pass = NULL, *cmd, *arg = NULL;
    char tag[16], qu[512], qp[512];
    int i, rc;

    tlsnet_set_progname("mailrecv");

    if (argc < 7) { usage(); return 3; }
    host = argv[1];
    port = argv[2];
    user = argv[3];

    for (i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--pass-file") && i + 1 < argc)
            pass = read_pass_file(argv[++i]);
        else if (!strcmp(argv[i], "-v"))
            tlsnet_set_verbose(1);
        else break;
    }
    if (!pass) { usage(); return 3; }
    if (i >= argc) { usage(); return 3; }

    cmd = argv[i++];
    if (i < argc) arg = argv[i];

    tlsnet_connect(host, port);
    tlsnet_handshake(host, NULL);

    /* uvitaci radek serveru */
    {
        char line[LINE_SZ];
        if (imap_readline(line, sizeof(line)) < 0)
            tlsnet_die(2, "server neposlal uvitani");
        if (strncmp(line, "* OK", 4) != 0)
            tlsnet_die(1, "server neni pripraveny");
    }

    imap_quote(user, qu, sizeof(qu));
    imap_quote(pass, qp, sizeof(qp));
    next_tag(tag, sizeof(tag));
    imap_send(tag, "LOGIN %s %s", qu, qp);
    if (imap_wait_tag(tag) != 0)
        tlsnet_die(1, "prihlaseni odmitnuto");

    rc = 0;
    /* podprikazy doplni Task 5 a 6 */
    if (!strcmp(cmd, "noop")) {
        rc = 0;
    } else {
        fprintf(stderr, "mailrecv: neznamy prikaz '%s'\n", cmd);
        rc = 3;
    }
    (void)arg;

    next_tag(tag, sizeof(tag));
    imap_send(tag, "LOGOUT");
    imap_wait_tag(tag);
    tlsnet_close();
    return rc;
}
```

- [ ] **Step 2: Přidat pravidlo do `Makefile`**

```make
mailrecv: mailrecv.c tlsnet.o
	@test -d "$(MBEDTLS)/include" || \
	  { echo "chybi mbedTLS v $(MBEDTLS) - spust nejdriv ./build.sh"; exit 1; }
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -o $@ mailrecv.c tlsnet.o \
	  -L"$(MBEDTLS)/lib" -lmbedtls -lmbedx509 -lmbedcrypto $(LDFLAGS)
```

- [ ] **Step 3: Přeložit nativně pro Pi a otestovat přihlášení**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
cd ~/fotopast/test_files
NAT=\$HOME/fotopast/test_files/build/mbedtls-native
gcc -O2 -std=gnu99 -I\$NAT/include -o /tmp/mailrecv mailrecv.c tlsnet.c \
    -L\$NAT/lib -lmbedtls -lmbedx509 -lmbedcrypto
/tmp/mailrecv imap.seznam.cz 993 fotopast.pajsti@seznam.cz --pass-file ~/imap.pass noop
echo \"exit=\$?\"
"'
```

Expected: `exit=0`, žádný výstup na stdout.

- [ ] **Step 4: Ověřit, že špatné heslo selže**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
echo spatneheslo > /tmp/bad.pass
/tmp/mailrecv imap.seznam.cz 993 fotopast.pajsti@seznam.cz --pass-file /tmp/bad.pass noop
echo \"exit=\$?\"
rm -f /tmp/bad.pass
"'
```

Expected: `mailrecv: prihlaseni odmitnuto` a `exit=1`.

- [ ] **Step 5: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add test_files/mailrecv.c test_files/Makefile
git commit -m "feat: mailrecv - kostra IMAP klienta a prihlaseni

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `mailrecv list unseen`

**Files:**
- Modify: `test_files/mailrecv.c`

**Interfaces:**
- Consumes: `imap_readline()`, `imap_read_bytes()`, `imap_send()`, `next_tag()`, `is_tagged()`, `tag_ok()` z Tasku 4.
- Produces: výstupní formát `MSG|<uid>|<odesilatel>|<predmet>` — parsuje ho `process_mail()` v Tasku 12.

- [ ] **Step 1: Doplnit parsování hlaviček do `mailrecv.c`**

Vlož před `main()`:

```c
/* ----------------------------------------------------- hlavicky */

static void lowercase(char *s)
{
    for (; *s; s++) *s = (char)tolower((unsigned char)*s);
}

static void trim_ws(char *s)
{
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == ' ' || s[n-1] == '\t')) s[--n] = '\0';
}

/* Z "Pavel <a@b.cz>" udela "a@b.cz"; bez <> vezme cely retezec.
 * Vystup je vzdy malymi pismeny. */
static void extract_addr(const char *v, char *out, size_t outsz)
{
    const char *lt = strchr(v, '<');
    size_t n;

    if (lt) {
        const char *gt = strchr(lt + 1, '>');
        if (gt) {
            n = (size_t)(gt - lt - 1);
            if (n >= outsz) n = outsz - 1;
            memcpy(out, lt + 1, n);
            out[n] = '\0';
            lowercase(out);
            return;
        }
    }
    while (*v == ' ' || *v == '\t') v++;
    snprintf(out, outsz, "%s", v);
    trim_ws(out);
    lowercase(out);
}

/* Projde blok hlavicek a vytahne From a Subject. Rozbaluje pokracovaci
 * radky (radek zacinajici mezerou/tabem patri k predchozi hlavicce). */
static void parse_headers(char *blk, char *from, size_t fromsz,
                          char *subj, size_t subjsz)
{
    char *line, *save;
    char cur[LINE_SZ];
    int which = 0;               /* 0 = nic, 1 = From, 2 = Subject */

    from[0] = '\0';
    subj[0] = '\0';
    cur[0] = '\0';

    for (line = blk; line && *line; line = save) {
        char *nl = strchr(line, '\n');
        if (nl) { *nl = '\0'; save = nl + 1; } else { save = NULL; }
        { size_t l = strlen(line); if (l > 0 && line[l-1] == '\r') line[l-1] = '\0'; }

        if (*line == ' ' || *line == '\t') {          /* pokracovani */
            if (which) {
                size_t c = strlen(cur);
                const char *p = line;
                while (*p == ' ' || *p == '\t') p++;
                snprintf(cur + c, sizeof(cur) - c, " %s", p);
            }
            continue;
        }

        /* novy radek uzavira predchozi hlavicku */
        if (which == 1) extract_addr(cur, from, fromsz);
        else if (which == 2) { trim_ws(cur); snprintf(subj, subjsz, "%s", cur); }
        which = 0;
        cur[0] = '\0';

        if (strncasecmp(line, "From:", 5) == 0) {
            which = 1;
            snprintf(cur, sizeof(cur), "%s", line + 5);
        } else if (strncasecmp(line, "Subject:", 8) == 0) {
            which = 2;
            snprintf(cur, sizeof(cur), "%s", line + 8);
        }
    }
    if (which == 1) extract_addr(cur, from, fromsz);
    else if (which == 2) { trim_ws(cur); snprintf(subj, subjsz, "%s", cur); }
}
```

Poznámka: `strncasecmp` je v `<strings.h>` — přidej ten include.

- [ ] **Step 2: Doplnit `UID SEARCH` a `UID FETCH`**

Vlož před `main()`:

```c
/* Nacte UID neprectenych zprav do pole. Vraci pocet, -1 pri chybe. */
static int search_unseen(char *uids[], int maxuids)
{
    char tag[16], line[LINE_SZ];
    int count = 0;

    next_tag(tag, sizeof(tag));
    imap_send(tag, "UID SEARCH UNSEEN");

    for (;;) {
        if (imap_readline(line, sizeof(line)) < 0) return -1;
        if (is_tagged(line, tag)) return tag_ok(line, tag) ? count : -1;

        if (strncmp(line, "* SEARCH", 8) == 0) {
            char *p = line + 8;
            while (*p && count < maxuids) {
                char *e;
                while (*p == ' ') p++;
                if (!*p) break;
                e = p;
                while (*e && *e != ' ') e++;
                {
                    size_t n = (size_t)(e - p);
                    char *u = malloc(n + 1);
                    if (!u) return -1;
                    memcpy(u, p, n);
                    u[n] = '\0';
                    uids[count++] = u;
                }
                p = e;
            }
        }
    }
}

/* Stahne hlavicky jedne zpravy. Vraci 0 pri uspechu. */
static int fetch_one(const char *uid, char *from, size_t fromsz,
                     char *subj, size_t subjsz)
{
    char tag[16], line[LINE_SZ];

    from[0] = '\0';
    subj[0] = '\0';

    next_tag(tag, sizeof(tag));
    imap_send(tag, "UID FETCH %s (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])", uid);

    for (;;) {
        char *br;
        if (imap_readline(line, sizeof(line)) < 0) return -1;
        if (is_tagged(line, tag)) return tag_ok(line, tag) ? 0 : -1;

        /* literal na konci radku: "... {123}" */
        br = strrchr(line, '{');
        if (br && strchr(br, '}')) {
            long n = strtol(br + 1, NULL, 10);
            if (n > 0 && n < 65536) {
                char *blk = malloc((size_t)n + 1);
                if (!blk) return -1;
                if (imap_read_bytes(blk, (size_t)n) < 0) { free(blk); return -1; }
                blk[n] = '\0';
                parse_headers(blk, from, fromsz, subj, subjsz);
                free(blk);
            }
        }
    }
}
```

- [ ] **Step 3: Doplnit `SELECT INBOX` a zachycení `UIDVALIDITY`**

Bez `SELECT` IMAP odmítne `UID SEARCH` i `UID STORE` — schránka musí být
nejdřív vybraná. `SELECT` je zároveň jediné místo, kde server hlásí
`UIDVALIDITY`, které potřebuje deduplikace v Tasku 12: po (vzácném)
znovuvytvoření schránky začnou UID od začátku a bez tohoto čísla by se
nový příkaz mohl tiše přeskočit jako „už zpracovaný".

Vlož před `main()`:

```c
static char uidvalidity[32] = "0";

/* Vybere INBOX a zachyti UIDVALIDITY z "* OK [UIDVALIDITY 1234] ...".
 * Vraci 0 pri uspechu. */
static int select_inbox(void)
{
    char tag[16], line[LINE_SZ];

    next_tag(tag, sizeof(tag));
    imap_send(tag, "SELECT INBOX");

    for (;;) {
        char *p;
        if (imap_readline(line, sizeof(line)) < 0) return -1;
        if (is_tagged(line, tag)) return tag_ok(line, tag) ? 0 : -1;

        p = strstr(line, "[UIDVALIDITY ");
        if (p) {
            size_t i = 0;
            p += strlen("[UIDVALIDITY ");
            while (*p >= '0' && *p <= '9' && i < sizeof(uidvalidity) - 1)
                uidvalidity[i++] = *p++;
            uidvalidity[i] = '\0';
        }
    }
}
```

- [ ] **Step 4: Napojit podpříkaz `list unseen` v `main()`**

Nahraď blok `if (!strcmp(cmd, "noop"))`:

```c
    if (select_inbox() != 0)
        tlsnet_die(1, "SELECT INBOX selhal");

    rc = 0;
    if (!strcmp(cmd, "list") && arg && !strcmp(arg, "unseen")) {
        char *uids[256];
        char from[512], subj[LINE_SZ];
        int n, k;

        n = search_unseen(uids, 256);
        if (n < 0) {
            rc = 1;
        } else {
            /* UIDVALIDITY jde prvni - shell si ho zapamatuje a pouzije
             * jako soucast dedup klice. */
            printf("UIDVALIDITY|%s\n", uidvalidity);
            for (k = 0; k < n; k++) {
                if (fetch_one(uids[k], from, sizeof(from),
                              subj, sizeof(subj)) == 0) {
                    printf("MSG|%s|%s|%s\n", uids[k], from, subj);
                }
                free(uids[k]);
            }
            fflush(stdout);
        }
    } else if (!strcmp(cmd, "noop")) {
        rc = 0;
    } else {
        fprintf(stderr, "mailrecv: neznamy prikaz '%s'\n", cmd);
        rc = 3;
    }
```

- [ ] **Step 5: Přeložit a otestovat proti reálné schránce**

Pošli si do schránky mail s předmětem `HUNTER testtoken STATUS` (nechej ho nepřečtený), pak:

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
cd ~/fotopast/test_files
NAT=\$HOME/fotopast/test_files/build/mbedtls-native
gcc -O2 -std=gnu99 -I\$NAT/include -o /tmp/mailrecv mailrecv.c tlsnet.c \
    -L\$NAT/lib -lmbedtls -lmbedx509 -lmbedcrypto
/tmp/mailrecv imap.seznam.cz 993 fotopast.pajsti@seznam.cz --pass-file ~/imap.pass list unseen
"'
```

Expected — nejdřív jeden řádek s `UIDVALIDITY`, pak jeden řádek na každou nepřečtenou zprávu:
```
UIDVALIDITY|1441987654
MSG|4711|paja.stindl@seznam.cz|HUNTER testtoken STATUS
```

Ověř, že adresa je **malými písmeny** a že předmět je celý (i s mezerami).

- [ ] **Step 6: Ověřit, že zpráva zůstala nepřečtená**

Spusť stejný příkaz **podruhé**. Expected: stejný výstup — `BODY.PEEK` nesmí nastavit `\Seen`. Kdyby zpráva zmizela, je v kódu `BODY[` místo `BODY.PEEK[`.

- [ ] **Step 7: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add test_files/mailrecv.c
git commit -m "feat: mailrecv list unseen - vypis neprectenych zprav

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `mailrecv seen <uid>`

**Files:**
- Modify: `test_files/mailrecv.c`

**Interfaces:**
- Produces: podpříkaz `seen <uid>` — volá ho `process_mail()` v Tasku 12.

- [ ] **Step 1: Doplnit podpříkaz do `main()`**

Do řetězce `else if` v `main()` přidej před větev `noop`:

```c
    } else if (!strcmp(cmd, "seen") && arg) {
        next_tag(tag, sizeof(tag));
        imap_send(tag, "UID STORE %s +FLAGS (\\Seen)", arg);
        rc = (imap_wait_tag(tag) == 0) ? 0 : 1;
```

- [ ] **Step 2: Přeložit a otestovat**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build 'bash -c "
cd ~/fotopast/test_files
NAT=\$HOME/fotopast/test_files/build/mbedtls-native
gcc -O2 -std=gnu99 -I\$NAT/include -o /tmp/mailrecv mailrecv.c tlsnet.c \
    -L\$NAT/lib -lmbedtls -lmbedx509 -lmbedcrypto
UID=\$(/tmp/mailrecv imap.seznam.cz 993 fotopast.pajsti@seznam.cz --pass-file ~/imap.pass list unseen | head -1 | cut -d\| -f2)
echo \"oznacuji UID=\$UID\"
/tmp/mailrecv imap.seznam.cz 993 fotopast.pajsti@seznam.cz --pass-file ~/imap.pass seen \$UID
echo \"exit=\$?\"
/tmp/mailrecv imap.seznam.cz 993 fotopast.pajsti@seznam.cz --pass-file ~/imap.pass list unseen
"'
```

Expected: `exit=0`, a druhý `list unseen` už tu zprávu **neobsahuje**.

- [ ] **Step 3: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add test_files/mailrecv.c
git commit -m "feat: mailrecv seen - oznaceni zpravy jako prectene

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Testovací harness a vytažení vykonavače

Čistý refaktor — žádná změna chování. Zároveň vzniká testovací infrastruktura, kterou používají všechny další shellové úlohy.

**Files:**
- Create: `tests/assert.sh`
- Create: `tests/fixture.sh`
- Create: `tests/run_tests.sh`
- Create: `tests/test_command.sh`
- Create: `hunter/lib/command.sh`
- Modify: `hunter/lib/sms.sh`

**Interfaces:**
- Produces: `execute_command(<text>)` nastavující `CMD_REPLY`; `wipe_sent_snaps()` nastavující `WIPE_COUNT`. Používá je Task 8–12.

- [ ] **Step 1: Vytvořit `tests/assert.sh`**

```sh
# tests/assert.sh - minimalni tvrzeni pro shellove testy.
# Zdrojuje se z kazdeho tests/test_*.sh.

TEST_FAILED=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        printf '  OK   %s\n' "$1"
    else
        printf '  FAIL %s\n    dostal:  %s\n    cekal:   %s\n' "$1" "$2" "$3"
        TEST_FAILED=1
    fi
}

assert_contains() {
    case "$2" in
        *"$3"*) printf '  OK   %s\n' "$1" ;;
        *) printf '  FAIL %s\n    v "%s" chybi "%s"\n' "$1" "$2" "$3"
           TEST_FAILED=1 ;;
    esac
}

assert_not_contains() {
    case "$2" in
        *"$3"*) printf '  FAIL %s\n    v "%s" nemelo byt "%s"\n' "$1" "$2" "$3"
                TEST_FAILED=1 ;;
        *) printf '  OK   %s\n' "$1" ;;
    esac
}

finish() { exit "$TEST_FAILED"; }
```

- [ ] **Step 2: Vytvořit `tests/fixture.sh`**

```sh
# tests/fixture.sh - postavi docasne prostredi Hunteru pro testy.
#
# Vytvori adresar s bin/, state/, config.txt a mail.token, nastavi
# HUNTER_DIR/SDCARD/LOG_FILE a nacte knihovny. Kazdy test si vola
# fixture_setup na zacatku a fixture_teardown na konci.

fixture_setup() {
    FIX=$(mktemp -d)
    HUNTER_DIR="$FIX/hunter"
    SDCARD="$FIX/sdcard"
    STATE_DIR="$HUNTER_DIR/state"
    CONFIG_FILE="$HUNTER_DIR/config.txt"
    LOG_FILE="$HUNTER_DIR/log.txt"
    TOKEN_FILE="$HUNTER_DIR/mail.token"

    mkdir -p "$HUNTER_DIR/bin" "$STATE_DIR" "$SDCARD/snaps/260828" "$SDCARD/HDPIC/260828"
    : > "$LOG_FILE"

    cat > "$CONFIG_FILE" <<'EOF'
MASTERS=+420603284430
MAIL_MASTERS=paja.stindl@seznam.cz
QUALITY=HD
CONFIRM=ON
AUTH_TYPE=TOKEN
SMTP_HOST=smtp.example.cz
SMTP_PORT=465
SMTP_USER=fotopast@example.cz
SMTP_TO=paja.stindl@seznam.cz
SMTP_TLS=implicit
IMAP_HOST=imap.example.cz
IMAP_PORT=993
AT_PORT=/dev/null
AT_BAUD=115200
SNAP_WAIT=1
MAX_SEND_PER_WAKE=3
REQUEST_MAX=5
RUN_DEADLINE=180
EOF

    printf 'tajnytoken1\n' > "$TOKEN_FILE"

    # fake snapready: vsechno je "pripravene"
    printf '#!/bin/sh\nexit 0\n' > "$HUNTER_DIR/bin/snapready"
    chmod +x "$HUNTER_DIR/bin/snapready"

    # fake atcmd: nic nevraci (STATUS pak da N/A)
    printf '#!/bin/sh\nexit 1\n' > "$HUNTER_DIR/bin/atcmd"
    chmod +x "$HUNTER_DIR/bin/atcmd"

    ROOT=$(cd "$(dirname "$0")/.." && pwd)
    . "$ROOT/hunter/lib/common.sh"
    . "$ROOT/hunter/lib/status.sh"
    . "$ROOT/hunter/lib/mail.sh"
    . "$ROOT/hunter/lib/command.sh"

    load_config
}

fixture_teardown() {
    [ -n "$FIX" ] && rm -rf "$FIX"
}

# fixture_snap <YYMMDD> <HHMMSS> - vyrobi dvojici snaps/ + HDPIC/
fixture_snap() {
    mkdir -p "$SDCARD/snaps/$1" "$SDCARD/HDPIC/$1"
    printf 'jpegdata' > "$SDCARD/snaps/$1/$2_000_65535_P.jpg"
    printf 'hdjpegdata' > "$SDCARD/HDPIC/$1/$2_000_65535_PH.jpg"
}
```

- [ ] **Step 3: Vytvořit `tests/run_tests.sh`**

```sh
#!/bin/sh
# tests/run_tests.sh - spusti vsechny tests/test_*.sh pres dash.
#
# dash je zastupce za busybox ash - oba jsou striktne POSIX, takze co
# projde v dash, projde i na zarizeni. Bash by propustil bashismy, ktere
# by na zarizeni spadly.

DIR=$(cd "$(dirname "$0")" && pwd)
PASS=0
FAIL=0

for t in "$DIR"/test_*.sh; do
    printf '== %s\n' "$(basename "$t")"
    if dash "$t"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

printf '\nprosly: %d   selhaly: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

Nastav spustitelnost: `chmod +x tests/run_tests.sh`

- [ ] **Step 4: Napsat padající test pro `execute_command`**

`tests/test_command.sh`:

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

CMD_REPLY=""
execute_command "STATUS"
assert_contains "STATUS vraci BAT" "$CMD_REPLY" "BAT:"

CMD_REPLY=""
execute_command "status"
assert_contains "STATUS je case-insensitive" "$CMD_REPLY" "BAT:"

CMD_REPLY=""
execute_command "QUALITY LOW"
assert_eq "QUALITY LOW odpoved" "$CMD_REPLY" "QUALITY SET TO LOW"
assert_eq "QUALITY LOW v pameti" "$QUALITY" "LOW"
assert_contains "QUALITY LOW v configu" "$(cat "$CONFIG_FILE")" "QUALITY=LOW"

CMD_REPLY=""
execute_command "neznamy prikaz"
assert_eq "neznamy prikaz" "$CMD_REPLY" "UNKNOWN CMD"

fixture_teardown
finish
```

- [ ] **Step 5: Spustit test — musí selhat**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && sh tests/run_tests.sh
```

Expected: FAIL — `command.sh` neexistuje, `execute_command: not found`.

- [ ] **Step 6: Vytvořit `hunter/lib/command.sh` přesunem z `sms.sh`**

Přesuň z `hunter/lib/sms.sh` funkce `execute_sms_command` a `wipe_sent_snaps` do nového `hunter/lib/command.sh`. Zachovej **všechny komentáře** (vysvětlují, proč se nepoužívá `$()` ani `tr`), jen uprav jména:

- `execute_sms_command` → `execute_command`
- `SMS_REPLY` → `CMD_REPLY` (všude v těle funkce)

Hlavička souboru:

```sh
# command.sh - transportne NEZAVISLY vykonavac prikazu.
#
# Bere text prikazu a vraci odpoved v globalni promenne CMD_REPLY.
# O tom, jestli prikaz prisel SMS nebo e-mailem, nevi nic - to je vec
# transportu (lib/sms.sh, lib/mailcmd.sh).
#
# Odpoved se NEVRACI pres stdout/$() - `$(...)` v POSIX shellu vzdy
# spousti subshell, a kdyby volajici zabalil tenhle call do neho, zmeny
# MASTERS/QUALITY/CONFIRM udelane uvnitr by se ztratily za hranici
# funkce. Proto globalni promenna a volani PRIMO.
#
# Case-insensitivita je resena `case` patterny se znakovymi tridami
# ([Ss][Tt]...), NE pres `tr '[:lower:]' '[:upper:]'` - POSIX tridy v tr
# (FEATURE_TR_CLASSES) jsou v busyboxu volitelne a tenhle firmware je
# hodne oriznuty.
```

- [ ] **Step 7: Upravit `hunter/lib/sms.sh`**

Zůstane v něm jen `process_sms`. Uvnitř nahraď:

```sh
        SMS_REPLY=""
        execute_sms_command "$body"
        reply="$SMS_REPLY"
```

za:

```sh
        CMD_REPLY=""
        execute_command "$body"
        reply="$CMD_REPLY"
```

Do hlavičky souboru přidej, že vykonavač se přesunul do `command.sh`.

- [ ] **Step 8: Zdrojovat nový soubor v `hunter.sh`**

V `hunter/hunter.sh` přidej za `. "$HUNTER_DIR/lib/status.sh"`:

```sh
. "$HUNTER_DIR/lib/command.sh"
```

- [ ] **Step 9: Spustit testy — musí projít**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && sh tests/run_tests.sh
```

Expected: `prosly: 1   selhaly: 0`

- [ ] **Step 10: Ověřit syntaxi všech shellových souborů**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
for f in hunter/hunter.sh hunter/lib/*.sh; do dash -n "$f" && echo "OK $f"; done
```

- [ ] **Step 11: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add tests/ hunter/lib/command.sh hunter/lib/sms.sh hunter/hunter.sh
git commit -m "refactor: vytahnout vykonavac prikazu do lib/command.sh + testovaci harness

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Tokeny a autorizace

**Files:**
- Create: `tests/test_auth.sh`
- Modify: `hunter/lib/command.sh`
- Modify: `hunter/lib/common.sh`
- Modify: `hunter/config.txt.example`

**Interfaces:**
- Produces: `load_tokens()`, `is_valid_token(<t>)`, `add_token(<t>)`, `remove_token(<t>)` nastavující `TOKEN_COUNT`; `is_mail_master(<addr>)`; `authorize_mail(<from>, <subject>)` nastavující `AUTH_OK`, `AUTH_CMD`, `AUTH_HAS_TOKEN`. Používá je Task 9–12.

- [ ] **Step 1: Napsat padající testy `tests/test_auth.sh`**

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# --- rezim TOKEN ---
authorize_mail "paja.stindl@seznam.cz" "HUNTER tajnytoken1 STATUS"
assert_eq "TOKEN: platny token + master"        "$AUTH_OK"  "1"
assert_eq "TOKEN: prikaz bez tokenu"            "$AUTH_CMD" "STATUS"
assert_eq "TOKEN: priznak tokenu"               "$AUTH_HAS_TOKEN" "1"

authorize_mail "cizi@example.com" "HUNTER tajnytoken1 STATUS"
assert_eq "TOKEN: platny token + cizi odesilatel" "$AUTH_OK" "0"

authorize_mail "paja.stindl@seznam.cz" "HUNTER spatnytoken STATUS"
assert_eq "TOKEN: spatny token" "$AUTH_OK" "0"

authorize_mail "paja.stindl@seznam.cz" "HUNTER STATUS"
assert_eq "TOKEN: bez tokenu" "$AUTH_OK" "0"

# --- rezim SENDER ---
set_config_value AUTH_TYPE SENDER
AUTH_TYPE=SENDER

authorize_mail "paja.stindl@seznam.cz" "HUNTER STATUS"
assert_eq "SENDER: bez tokenu + master"   "$AUTH_OK"  "1"
assert_eq "SENDER: prikaz"                "$AUTH_CMD" "STATUS"
assert_eq "SENDER: priznak tokenu"        "$AUTH_HAS_TOKEN" "0"

authorize_mail "paja.stindl@seznam.cz" "HUNTER tajnytoken1 STATUS"
assert_eq "SENDER: s tokenem taky projde" "$AUTH_OK" "1"
assert_eq "SENDER: token rozpoznan"       "$AUTH_HAS_TOKEN" "1"

authorize_mail "cizi@example.com" "HUNTER STATUS"
assert_eq "SENDER: cizi odesilatel" "$AUTH_OK" "0"

set_config_value AUTH_TYPE TOKEN
AUTH_TYPE=TOKEN

# --- velikost pismen v adrese ---
authorize_mail "Paja.Stindl@Seznam.CZ" "HUNTER tajnytoken1 STATUS"
assert_eq "adresa case-insensitive" "$AUTH_OK" "1"

# --- sprava tokenu ---
load_tokens
assert_eq "pocet tokenu na zacatku" "$TOKEN_COUNT" "1"

add_token "druhytoken2"
assert_eq "po pridani"       "$ADD_TOKEN_RESULT" "OK"
load_tokens
assert_eq "pocet po pridani" "$TOKEN_COUNT" "2"

add_token "druhytoken2"
assert_eq "duplicitni pridani je no-op" "$ADD_TOKEN_RESULT" "EXISTS"

add_token "kratky"
assert_eq "kratky token odmitnut" "$ADD_TOKEN_RESULT" "TOO_SHORT"

add_token "token s mezerou"
assert_eq "token s mezerou odmitnut" "$ADD_TOKEN_RESULT" "BAD_CHARS"

is_valid_token "druhytoken2" && r=1 || r=0
assert_eq "novy token plati" "$r" "1"

remove_token "druhytoken2"
assert_eq "odebrani"       "$REMOVE_TOKEN_RESULT" "OK"
load_tokens
assert_eq "pocet po odebrani" "$TOKEN_COUNT" "1"

remove_token "tajnytoken1"
assert_eq "posledni token nelze odebrat" "$REMOVE_TOKEN_RESULT" "LAST"
load_tokens
assert_eq "pocet zustal" "$TOKEN_COUNT" "1"

remove_token "neexistujici9"
assert_eq "odebrani neexistujiciho" "$REMOVE_TOKEN_RESULT" "NOT_FOUND"

# --- fail closed ---
rm -f "$TOKEN_FILE"
load_tokens
assert_eq "chybejici soubor = 0 tokenu" "$TOKEN_COUNT" "0"
authorize_mail "paja.stindl@seznam.cz" "HUNTER tajnytoken1 STATUS"
assert_eq "TOKEN rezim bez tokenu = fail closed" "$AUTH_OK" "0"

fixture_teardown
finish
```

- [ ] **Step 2: Spustit — musí selhat**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && dash tests/test_auth.sh
```

Expected: `authorize_mail: not found`

- [ ] **Step 3: Doplnit `TOKEN_FILE` do `load_config`**

V `hunter/lib/common.sh` ve funkci `load_config()` přidej za `. "$CONFIG_FILE"`:

```sh
    : "${AUTH_TYPE:=TOKEN}"
    : "${MAIL_MASTERS:=}"
    : "${REQUEST_MAX:=5}"
    : "${IMAP_PORT:=993}"
    : "${TOKEN_FILE:=$HUNTER_DIR/mail.token}"
```

`IMAP_HOST` **nepatří** mezi povinné klíče v cyklu `for req in ...` — bez něj se má e-mailový kanál jen tiše vypnout, ne shodit celý běh.

- [ ] **Step 4: Implementovat správu tokenů v `hunter/lib/command.sh`**

Vlož na začátek souboru za hlavičku:

```sh
# --- tokeny ---------------------------------------------------------
#
# mail.token je viceradkovy, jeden token na radek. Kazdy clovek ma
# vlastni token, takze odvolani jednoho neznamena menit token vsem.
# Vsechny tokeny maji STEJNE opravneni (vedome rozhodnuti, viz spec 3.3).
#
# Hodnota tokenu se NIKDY nezaloguje ani nevraci v odpovedi.

# load_tokens -> nastavi TOKEN_COUNT
load_tokens() {
    TOKEN_COUNT=0
    [ -f "$TOKEN_FILE" ] || return 0
    while IFS= read -r t || [ -n "$t" ]; do
        [ -n "$t" ] && TOKEN_COUNT=$((TOKEN_COUNT + 1))
    done < "$TOKEN_FILE"
    return 0
}

# is_valid_token <token> -> navratovy kod 0 = plati
is_valid_token() {
    [ -n "$1" ] || return 1
    [ -f "$TOKEN_FILE" ] || return 1
    while IFS= read -r t || [ -n "$t" ]; do
        [ "$t" = "$1" ] && return 0
    done < "$TOKEN_FILE"
    return 1
}

# add_token <token> -> ADD_TOKEN_RESULT = OK|EXISTS|TOO_SHORT|BAD_CHARS
add_token() {
    nt="$1"

    case "$nt" in
        *" "*|*"$(printf '\t')"*) ADD_TOKEN_RESULT=BAD_CHARS; return 1 ;;
    esac
    # min. 8 znaku. Busybox nema wc; `case` s osmi otazniky nezavisi ani
    # na ${#var}, ktere neni ve vsech ash buildech spolehlive.
    case "$nt" in
        ????????*) ;;
        *) ADD_TOKEN_RESULT=TOO_SHORT; return 1 ;;
    esac

    if is_valid_token "$nt"; then
        ADD_TOKEN_RESULT=EXISTS; return 0
    fi

    printf '%s\n' "$nt" >> "$TOKEN_FILE"
    sync
    ADD_TOKEN_RESULT=OK
    return 0
}

# remove_token <token> -> REMOVE_TOKEN_RESULT = OK|NOT_FOUND|LAST
remove_token() {
    rt="$1"

    if ! is_valid_token "$rt"; then
        REMOVE_TOKEN_RESULT=NOT_FOUND; return 1
    fi

    load_tokens
    # Posledni token nejde odebrat - v rezimu TOKEN by se zarizeni stalo
    # neovladatelnym na dalku a jedinou cestou zpet by byl fyzicky
    # pristup ke karte.
    if [ "$TOKEN_COUNT" -le 1 ]; then
        REMOVE_TOKEN_RESULT=LAST; return 1
    fi

    tmp="$TOKEN_FILE.tmp.$$"
    : > "$tmp"
    while IFS= read -r t || [ -n "$t" ]; do
        [ -z "$t" ] && continue
        [ "$t" = "$rt" ] && continue
        printf '%s\n' "$t" >> "$tmp"
    done < "$TOKEN_FILE"
    sync
    mv -f "$tmp" "$TOKEN_FILE"
    sync
    REMOVE_TOKEN_RESULT=OK
    return 0
}
```

Poznámka k minimální délce: `${#nt}` v busybox ash funguje, ale pro jistotu je tam i `case` s osmi otazníky, který nezávisí na ničem.

- [ ] **Step 5: Implementovat autorizaci**

Pokračuj v `hunter/lib/command.sh`:

```sh
# --- autorizace -----------------------------------------------------

# is_mail_master <adresa> -> 0 = je v MAIL_MASTERS
# Adresa uz prichazi malymi pismeny z mailrecv; MAIL_MASTERS z configu
# snizime taky (tr s EXPLICITNIMI rozsahy - POSIX tridy busybox nemusi
# mit).
is_mail_master() {
    [ -n "$MAIL_MASTERS" ] || return 1
    ml=$(printf '%s' "$MAIL_MASTERS" | tr 'A-Z' 'a-z')
    a=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case ",$ml," in
        *",$a,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# authorize_mail <odesilatel> <predmet>
# Nastavi:
#   AUTH_OK        1 = smi se vykonat
#   AUTH_CMD       prikaz bez prefixu a bez tokenu
#   AUTH_HAS_TOKEN 1 = ve zprave byl platny token
#
# Prefix "HUNTER " uz musi byt oriznuty volajicim? NE - resi se tady,
# aby transport nemusel znat format.
authorize_mail() {
    AUTH_OK=0
    AUTH_CMD=""
    AUTH_HAS_TOKEN=0

    from="$1"
    subj=$(trim "$2")

    # musi zacinat prefixem
    case "$subj" in
        [Hh][Uu][Nn][Tt][Ee][Rr]" "*) ;;
        *) return 1 ;;
    esac
    rest=$(trim "${subj#* }")

    # prvni slovo muze byt token
    first="${rest%% *}"
    if is_valid_token "$first"; then
        AUTH_HAS_TOKEN=1
        # kdyz za tokenem uz nic neni, prikaz je prazdny
        if [ "$first" = "$rest" ]; then
            AUTH_CMD=""
        else
            AUTH_CMD=$(trim "${rest#* }")
        fi
    else
        AUTH_CMD="$rest"
    fi

    is_mail_master "$from" || return 1

    case "$AUTH_TYPE" in
        [Ss][Ee][Nn][Dd][Ee][Rr]) AUTH_OK=1 ;;
        *) [ "$AUTH_HAS_TOKEN" = 1 ] && AUTH_OK=1 ;;
    esac
    return 0
}
```

- [ ] **Step 6: Doplnit nové klíče do `hunter/config.txt.example`**

```
# --- IMAP (prikazovy kanal) ---
# Prihlasovaci jmeno a heslo se sdili s odesilanim (SMTP_USER,
# smtp.pass) - je to tentyz ucet.
IMAP_HOST=imap.seznam.cz
IMAP_PORT=993

# Autorizovane e-mailove adresy pro prikazy, oddelene carkami.
# Piste malymi pismeny.
MAIL_MASTERS=paja.stindl@seznam.cz

# TOKEN  = predmet musi nest platny token A odesilatel musi byt
#          v MAIL_MASTERS  (vychozi, doporucene)
# SENDER = staci odesilatel v MAIL_MASTERS
# POZOR: hlavicku From lze trivialne podvrhnout, takze v rezimu SENDER
# je i WIPE dosazitelny pro kohokoli, kdo zna dve adresy. Prikazy menici
# opravneni (AUTH TYPE, ADD, REMOVE, ADD TOKEN, REMOVE TOKEN) vyzaduji
# token VZDY, i v rezimu SENDER.
AUTH_TYPE=TOKEN

# Strop poctu fotek na jedno VYZADANI (LAST/DATE/GET). Oddeleny od
# MAX_SEND_PER_WAKE, protoze o vyzadane fotky si uzivatel rekl vyslovne.
REQUEST_MAX=5
```

A do sekce o heslech přidej:

```
# Tokeny jsou v hunter/mail.token, jeden na radek (viceradkovy soubor -
# kazdy clovek muze mit vlastni). Vytvor takto na zarizeni:
#   echo 'nejakytajnytoken' > /tmp/mnt/sdcard/hunter/mail.token
```

- [ ] **Step 7: Spustit testy — musí projít**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && sh tests/run_tests.sh
```

Expected: `prosly: 2   selhaly: 0`

- [ ] **Step 8: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add tests/test_auth.sh hunter/lib/command.sh hunter/lib/common.sh hunter/config.txt.example
git commit -m "feat: vicenasobne tokeny a autorizace e-mailovych prikazu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Nové příkazy

**Files:**
- Create: `tests/test_privileged.sh`
- Modify: `hunter/lib/command.sh`

**Interfaces:**
- Consumes: `authorize_mail()`, `add_token()`, `remove_token()`, `is_valid_token()` z Tasku 8.
- Produces: rozšířený `execute_command()`, který bere druhý argument `<has_token>`.

- [ ] **Step 1: Napsat padající testy `tests/test_privileged.sh`**

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# execute_command <prikaz> <ma_platny_token>

# --- WIPE vyzaduje CONFIRM ---
CMD_REPLY=""; execute_command "WIPE" 1
assert_eq "WIPE bez CONFIRM se nevykona" "$CMD_REPLY" "WIPE NEEDS CONFIRM"

printf '%s\n' "$SDCARD/snaps/260828/210948_000_65535_P.jpg" > "$STATE_DIR/sent_list.txt"
fixture_snap 260828 210948
CMD_REPLY=""; execute_command "WIPE CONFIRM" 1
assert_contains "WIPE CONFIRM vykona" "$CMD_REPLY" "WIPE DONE"

# --- privilegovane prikazy vyzaduji token VZDY ---
CMD_REPLY=""; execute_command "AUTH TYPE SENDER" 0
assert_eq "AUTH TYPE bez tokenu" "$CMD_REPLY" "TOKEN REQUIRED"
assert_eq "rezim nezmenen" "$AUTH_TYPE" "TOKEN"

CMD_REPLY=""; execute_command "AUTH TYPE SENDER" 1
assert_eq "AUTH TYPE s tokenem" "$CMD_REPLY" "AUTH TYPE SET TO SENDER"
assert_eq "rezim zmenen" "$AUTH_TYPE" "SENDER"

CMD_REPLY=""; execute_command "AUTH TYPE TOKEN" 1
assert_eq "navrat do TOKEN" "$AUTH_TYPE" "TOKEN"

CMD_REPLY=""; execute_command "ADD TOKEN novytoken99" 0
assert_eq "ADD TOKEN bez tokenu" "$CMD_REPLY" "TOKEN REQUIRED"

CMD_REPLY=""; execute_command "ADD TOKEN novytoken99" 1
assert_contains "ADD TOKEN s tokenem" "$CMD_REPLY" "TOKEN ADDED"
assert_not_contains "odpoved neobsahuje hodnotu tokenu" "$CMD_REPLY" "novytoken99"

CMD_REPLY=""; execute_command "REMOVE TOKEN novytoken99" 1
assert_contains "REMOVE TOKEN" "$CMD_REPLY" "TOKEN REMOVED"

CMD_REPLY=""; execute_command "REMOVE TOKEN tajnytoken1" 1
assert_eq "posledni token" "$CMD_REPLY" "CANNOT REMOVE LAST TOKEN"

# --- ADD / REMOVE adres a cisel ---
CMD_REPLY=""; execute_command "ADD novy@example.com" 1
assert_contains "ADD e-mailu" "$CMD_REPLY" "ADDED"
assert_contains "adresa v configu" "$(cat "$CONFIG_FILE")" "novy@example.com"

CMD_REPLY=""; execute_command "REMOVE novy@example.com" 1
assert_contains "REMOVE e-mailu" "$CMD_REPLY" "REMOVED"
assert_not_contains "adresa pryc z configu" "$(cat "$CONFIG_FILE")" "novy@example.com"

CMD_REPLY=""; execute_command "ADD +420111222333" 1
assert_contains "ADD telefonu" "$CMD_REPLY" "ADDED"
assert_contains "cislo v MASTERS" "$MASTERS" "+420111222333"

CMD_REPLY=""; execute_command "ADD nesmysl" 1
assert_eq "neplatny argument" "$CMD_REPLY" "ADD: INVALID TARGET"

# --- STATUS obsahuje pocet tokenu ---
CMD_REPLY=""; execute_command "STATUS" 1
assert_contains "STATUS ma TOKENS" "$CMD_REPLY" "TOKENS:"

fixture_teardown
finish
```

- [ ] **Step 2: Spustit — musí selhat**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && dash tests/test_privileged.sh
```

- [ ] **Step 3: Přidat `remove_master` do `hunter/lib/common.sh`**

Za stávající `add_master()`:

```sh
# add_mail_master <adresa> / remove_mail_master <adresa>
# MAIL_MASTERS je seznam oddeleny carkami, stejne jako MASTERS.
add_mail_master() {
    a=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    if is_mail_master "$a"; then
        return 0
    fi
    if [ -z "$MAIL_MASTERS" ]; then
        newval="$a"
    else
        newval="$MAIL_MASTERS,$a"
    fi
    set_config_value MAIL_MASTERS "$newval"
    MAIL_MASTERS="$newval"
}

remove_mail_master() {
    a=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    newval=""
    old_ifs="$IFS"
    IFS=','
    for m in $MAIL_MASTERS; do
        [ "$m" = "$a" ] && continue
        [ -z "$m" ] && continue
        if [ -z "$newval" ]; then newval="$m"; else newval="$newval,$m"; fi
    done
    IFS="$old_ifs"
    set_config_value MAIL_MASTERS "$newval"
    MAIL_MASTERS="$newval"
}

# remove_master <cislo> - totez pro telefonni cisla
remove_master() {
    newval=""
    old_ifs="$IFS"
    IFS=','
    for m in $MASTERS; do
        [ "$m" = "$1" ] && continue
        [ -z "$m" ] && continue
        if [ -z "$newval" ]; then newval="$m"; else newval="$newval,$m"; fi
    done
    IFS="$old_ifs"
    set_config_value MASTERS "$newval"
    MASTERS="$newval"
}
```

- [ ] **Step 4: Rozšířit `execute_command` v `hunter/lib/command.sh`**

Změň hlavičku funkce na dva argumenty a doplň větve. Celá `case` konstrukce:

```sh
# execute_command <text_prikazu> [ma_platny_token]
#
# Druhy argument rika, jestli zprava nesla platny token. Prikazy menici
# OPRAVNENI (AUTH TYPE, ADD, REMOVE, ADD TOKEN, REMOVE TOKEN) ho vyzaduji
# VZDY - i v rezimu SENDER. Tim je zaruceno, ze se z oslabeneho rezimu
# jde vzdycky vratit a ze si podvrzeny mail nemuze sam pridat trvaly
# pristup. Viz spec sekce 3.3.
execute_command() {
    cmd=$(trim "$1")
    has_token="${2:-0}"

    case "$cmd" in
        [Ss][Tt][Aa][Tt][Uu][Ss])
            load_tokens
            CMD_REPLY="$(build_status_reply) TOKENS:$TOKEN_COUNT"
            ;;

        [Ff][Oo][Tt][Oo])
            CMD_REPLY='FOTO NOT SUPPORTED'
            ;;

        [Qq][Uu][Aa][Ll][Ii][Tt][Yy]" "[Hh][Dd])
            set_config_value QUALITY HD
            QUALITY=HD
            CMD_REPLY='QUALITY SET TO HD'
            ;;

        [Qq][Uu][Aa][Ll][Ii][Tt][Yy]" "[Ll][Oo][Ww])
            set_config_value QUALITY LOW
            QUALITY=LOW
            CMD_REPLY='QUALITY SET TO LOW'
            ;;

        [Cc][Oo][Nn][Ff][Ii][Rr][Mm]" "[Oo][Nn])
            set_config_value CONFIRM ON
            CONFIRM=ON
            CMD_REPLY='CONFIRM ON'
            ;;

        [Cc][Oo][Nn][Ff][Ii][Rr][Mm]" "[Oo][Ff][Ff])
            set_config_value CONFIRM OFF
            CONFIRM=OFF
            CMD_REPLY='CONFIRM OFF'
            ;;

        [Ww][Ii][Pp][Ee]" "[Cc][Oo][Nn][Ff][Ii][Rr][Mm])
            wipe_sent_snaps
            CMD_REPLY="WIPE DONE ($WIPE_COUNT photos, $(get_space_gb) free)"
            ;;

        [Ww][Ii][Pp][Ee])
            CMD_REPLY='WIPE NEEDS CONFIRM'
            ;;

        [Aa][Uu][Tt][Hh]" "[Tt][Yy][Pp][Ee]" "[Tt][Oo][Kk][Ee][Nn])
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            set_config_value AUTH_TYPE TOKEN
            AUTH_TYPE=TOKEN
            CMD_REPLY='AUTH TYPE SET TO TOKEN'
            ;;

        [Aa][Uu][Tt][Hh]" "[Tt][Yy][Pp][Ee]" "[Ss][Ee][Nn][Dd][Ee][Rr])
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            set_config_value AUTH_TYPE SENDER
            AUTH_TYPE=SENDER
            CMD_REPLY='AUTH TYPE SET TO SENDER'
            ;;

        [Aa][Dd][Dd]" "[Tt][Oo][Kk][Ee][Nn]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            newtok=$(trim "${cmd##* }")
            add_token "$newtok"
            case "$ADD_TOKEN_RESULT" in
                OK)        load_tokens; CMD_REPLY="TOKEN ADDED ($TOKEN_COUNT total)" ;;
                EXISTS)    CMD_REPLY='TOKEN ALREADY PRESENT' ;;
                TOO_SHORT) CMD_REPLY='TOKEN TOO SHORT (min 8)' ;;
                BAD_CHARS) CMD_REPLY='TOKEN MUST NOT CONTAIN SPACES' ;;
            esac
            ;;

        [Rr][Ee][Mm][Oo][Vv][Ee]" "[Tt][Oo][Kk][Ee][Nn]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            oldtok=$(trim "${cmd##* }")
            remove_token "$oldtok"
            case "$REMOVE_TOKEN_RESULT" in
                OK)        load_tokens; CMD_REPLY="TOKEN REMOVED ($TOKEN_COUNT left)" ;;
                NOT_FOUND) CMD_REPLY='TOKEN NOT FOUND' ;;
                LAST)      CMD_REPLY='CANNOT REMOVE LAST TOKEN' ;;
            esac
            ;;

        [Aa][Dd][Dd]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            tgt=$(trim "${cmd#* }")
            case "$tgt" in
                +[0-9]*) add_master "$(normalize_phone "$tgt")"
                         CMD_REPLY="ADDED $tgt" ;;
                *@*.*)   add_mail_master "$tgt"
                         CMD_REPLY="ADDED $tgt" ;;
                *)       CMD_REPLY='ADD: INVALID TARGET' ;;
            esac
            ;;

        [Rr][Ee][Mm][Oo][Vv][Ee]" "*)
            if [ "$has_token" != 1 ]; then CMD_REPLY='TOKEN REQUIRED'; return 0; fi
            tgt=$(trim "${cmd#* }")
            case "$tgt" in
                +[0-9]*) remove_master "$(normalize_phone "$tgt")"
                         CMD_REPLY="REMOVED $tgt" ;;
                *@*.*)   remove_mail_master "$tgt"
                         CMD_REPLY="REMOVED $tgt" ;;
                *)       CMD_REPLY='REMOVE: INVALID TARGET' ;;
            esac
            ;;

        *)
            CMD_REPLY='UNKNOWN CMD'
            ;;
    esac
}
```

**Pozor na pořadí větví:** `ADD TOKEN *` musí být **před** `ADD *`, jinak by ji obecnější vzor pohltil. Totéž `REMOVE TOKEN *` před `REMOVE *` a `WIPE CONFIRM` před `WIPE`.

- [ ] **Step 5: Upravit volání v `hunter/lib/sms.sh`**

SMS nemá token, takže předává `0`:

```sh
        CMD_REPLY=""
        execute_command "$body" 0
        reply="$CMD_REPLY"
```

Přidej k tomu komentář, že SMS transport tokeny nezná, takže privilegované příkazy přes SMS nejdou.

- [ ] **Step 6: Spustit testy**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && sh tests/run_tests.sh
```

Expected: `prosly: 3   selhaly: 0`

- [ ] **Step 7: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add tests/test_privileged.sh hunter/lib/command.sh hunter/lib/common.sh hunter/lib/sms.sh
git commit -m "feat: privilegovane prikazy - AUTH TYPE, ADD/REMOVE, sprava tokenu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: `LIST CMD`

**Files:**
- Create: `tests/test_listcmd.sh`
- Modify: `hunter/lib/command.sh`

- [ ] **Step 1: Napsat padající test `tests/test_listcmd.sh`**

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

CMD_REPLY=""; execute_command "LIST CMD" 1
assert_contains "hlavicka s rezimem"   "$CMD_REPLY" "auth mode: TOKEN"
assert_contains "STATUS s tokenem"     "$CMD_REPLY" "HUNTER <token> STATUS"
assert_contains "obsahuje LAST"        "$CMD_REPLY" "LAST <N>"
assert_contains "obsahuje ADD TOKEN"   "$CMD_REPLY" "ADD TOKEN <novy>"
assert_contains "obsahuje AUTH TYPE"   "$CMD_REPLY" "AUTH TYPE TOKEN|SENDER"
assert_contains "znacka vzdy token"    "$CMD_REPLY" "[vzdy token]"
assert_not_contains "NEobsahuje hodnotu tokenu" "$CMD_REPLY" "tajnytoken1"

set_config_value AUTH_TYPE SENDER
AUTH_TYPE=SENDER
CMD_REPLY=""; execute_command "LIST CMD" 1
assert_contains "hlavicka SENDER"          "$CMD_REPLY" "auth mode: SENDER"
assert_contains "STATUS bez tokenu"        "$CMD_REPLY" "HUNTER STATUS"
assert_contains "AUTH TYPE porad s tokenem" "$CMD_REPLY" "HUNTER <token> AUTH TYPE"

fixture_teardown
finish
```

- [ ] **Step 2: Spustit — musí selhat**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && dash tests/test_listcmd.sh
```

- [ ] **Step 3: Implementovat v `hunter/lib/command.sh`**

Přidej funkci před `execute_command`:

```sh
# build_cmd_listing
# Vypis prikazu, ktery ODRAZI AKTUALNI REZIM - ukazuje presne to, co je
# ted potreba napsat. Hodnota tokenu se nikdy nevypisuje, jen "<token>".
# Bez diakritiky, stejne jako zbytek zarizeni.
build_cmd_listing() {
    case "$AUTH_TYPE" in
        [Ss][Ee][Nn][Dd][Ee][Rr]) mode="SENDER"; p="HUNTER" ;;
        *)                        mode="TOKEN";  p="HUNTER <token>" ;;
    esac
    # privilegovane prikazy maji token vzdy, bez ohledu na rezim
    pp="HUNTER <token>"

    printf 'HUNTER commands (auth mode: %s)\n\n' "$mode"
    printf '%s STATUS                  stav: baterie/signal/misto\n' "$p"
    printf '%s LAST <N>                N nejnovejsich fotek\n' "$p"
    printf '%s DATE <YYMMDD>           fotky z daneho dne\n' "$p"
    printf '%s GET <jmeno>             konkretni soubor\n' "$p"
    printf '%s QUALITY HD|LOW          kvalita odesilanych fotek\n' "$p"
    printf '%s CONFIRM ON|OFF          potvrzovaci odpovedi\n' "$p"
    printf '%s WIPE CONFIRM            smaze jiz odeslane fotky\n' "$p"
    printf '%s LIST CMD                tento vypis\n' "$p"
    printf '%s ADD <tel|mail>          pridat opravneneho   [vzdy token]\n' "$pp"
    printf '%s REMOVE <tel|mail>       odebrat opravneneho  [vzdy token]\n' "$pp"
    printf '%s ADD TOKEN <novy>        pridat token         [vzdy token]\n' "$pp"
    printf '%s REMOVE TOKEN <token>    odebrat token        [vzdy token]\n' "$pp"
    printf '%s AUTH TYPE TOKEN|SENDER  zmena rezimu         [vzdy token]\n' "$pp"
    printf '%s FOTO                    nepodporovano\n' "$p"
    printf '\n<token> = kterykoli z tokenu v hunter/mail.token'
    printf ' (nikdy se nevypisuje)\n'
}
```

A větev do `case` v `execute_command` (kamkoli před `*)`):

```sh
        [Ll][Ii][Ss][Tt]" "[Cc][Mm][Dd])
            CMD_REPLY=$(build_cmd_listing)
            ;;
```

- [ ] **Step 4: Spustit testy**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && sh tests/run_tests.sh
```

Expected: `prosly: 4   selhaly: 0`

- [ ] **Step 5: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add tests/test_listcmd.sh hunter/lib/command.sh
git commit -m "feat: prikaz LIST CMD - vypis prikazu podle aktivniho rezimu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: Vyžádání fotek — `LAST` / `DATE` / `GET`

**Files:**
- Create: `tests/test_request.sh`
- Modify: `hunter/lib/command.sh`
- Modify: `hunter/lib/mail.sh`

**Interfaces:**
- Produces: globální `REQUESTED_SNAPS` (cesty oddělené `\n`) — čte ji `hunter.sh` v Tasku 13.

- [ ] **Step 1: Napsat padající test `tests/test_request.sh`**

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

fixture_snap 260828 210948
fixture_snap 260828 220000
fixture_snap 260829 080000

count_lines() { printf '%s' "$1" | grep -c . ; }

# --- LAST ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 2" 1
assert_eq "LAST 2 vrati 2 cesty" "$(count_lines "$REQUESTED_SNAPS")" "2"
assert_contains "LAST odpoved" "$CMD_REPLY" "SENDING 2"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST 99" 1
assert_eq "LAST nad strop orizne na REQUEST_MAX" \
          "$(count_lines "$REQUESTED_SNAPS")" "3"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "LAST abc" 1
assert_eq "LAST s necislem" "$CMD_REPLY" "LAST: INVALID COUNT"

# --- DATE ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "DATE 260828" 1
assert_eq "DATE vrati fotky z daneho dne" \
          "$(count_lines "$REQUESTED_SNAPS")" "2"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "DATE 999999" 1
assert_eq "DATE bez fotek" "$CMD_REPLY" "DATE: NOT FOUND"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "DATE 26-08-28" 1
assert_eq "DATE spatny format" "$CMD_REPLY" "DATE: INVALID FORMAT"

# --- GET ---
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET 210948_000_65535_P.jpg" 1
assert_eq "GET vrati 1 cestu" "$(count_lines "$REQUESTED_SNAPS")" "1"
assert_contains "GET odpoved" "$CMD_REPLY" "SENDING 1"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET neexistuje.jpg" 1
assert_eq "GET neexistujici" "$CMD_REPLY" "GET: NOT FOUND"

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET ../../etc/passwd" 1
assert_eq "GET s ../ odmitnut" "$CMD_REPLY" "GET: INVALID NAME"
assert_eq "nic se nepridalo" "$REQUESTED_SNAPS" ""

REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET /etc/passwd" 1
assert_eq "GET s lomitkem odmitnut" "$CMD_REPLY" "GET: INVALID NAME"

# --- vyzadane fotky obchazeji sent_list ---
printf '%s\n' "$SDCARD/snaps/260828/210948_000_65535_P.jpg" > "$STATE_DIR/sent_list.txt"
REQUESTED_SNAPS=""; CMD_REPLY=""
execute_command "GET 210948_000_65535_P.jpg" 1
assert_eq "jiz odeslana fotka se preposle" \
          "$(count_lines "$REQUESTED_SNAPS")" "1"

fixture_teardown
finish
```

- [ ] **Step 2: Spustit — musí selhat**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && dash tests/test_request.sh
```

- [ ] **Step 3: Implementovat v `hunter/lib/command.sh`**

Přidej před `execute_command`:

```sh
# --- vyzadani fotek -------------------------------------------------
#
# Vyzadane fotky OBCHAZEJI sent_list.txt - preposlat uz odeslanou fotku
# je cely smysl veci. Sbiraji se do REQUESTED_SNAPS (cesty oddelene
# novym radkem), ktere hunter.sh sloucí s automatickymi kandidaty.
#
# Strop je REQUEST_MAX, oddeleny od MAX_SEND_PER_WAKE - o vyzadane fotky
# si uzivatel rekl vyslovne.

# request_add <cesta> - prida cestu, hlida strop. Vraci 1 pri dosazeni
# stropu (volajici ma prestat pridavat).
request_add() {
    n=$(printf '%s' "$REQUESTED_SNAPS" | grep -c . )
    [ "$n" -ge "$REQUEST_MAX" ] && return 1
    if [ -z "$REQUESTED_SNAPS" ]; then
        REQUESTED_SNAPS="$1"
    else
        REQUESTED_SNAPS="$REQUESTED_SNAPS
$1"
    fi
    return 0
}

# request_count
request_count() {
    printf '%s' "$REQUESTED_SNAPS" | grep -c .
}

# Porovnavani stari snimku.
#
# Cesta ma tvar snaps/<YYMMDD>/<HHMMSS>_... Porovnava se CISELNE a ve
# DVOU krocich (nejdriv datum, pak cas), ne jako jedno dvanactimistne
# cislo ani jako retezec:
#   - operator \> uvnitr [ ] neni v POSIXu definovany a busybox ho
#     nemusi mit,
#   - dvanactimistne cislo by preteklo v 32bitove aritmetice.
# Sestimistne casti (max 999999) se do 32 bitu vejdou bez problemu.
#
# ZNAME OMEZENI: rok se bere jako YY, takze porovnani se rozbije na
# prelomu stoleti (99 -> 00). Pri nespolehlivych hodinach zarizeni
# (viz spec 2.1) je to prijatelne.
snap_date_of() { sp=${1%/*}; printf '%s' "${sp##*/}"; }
snap_time_of() { sb=${1##*/}; printf '%s' "${sb%%_*}"; }

snap_num6() {
    case "$1" in [0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;; esac
    return 1
}

# snap_newer <a> <b> -> 0 kdyz a je novejsi nez b
snap_newer() {
    ad=$(snap_date_of "$1"); at=$(snap_time_of "$1")
    bd=$(snap_date_of "$2"); bt=$(snap_time_of "$2")
    snap_num6 "$ad" && snap_num6 "$at" || return 1
    snap_num6 "$bd" && snap_num6 "$bt" || return 0
    [ "$ad" -gt "$bd" ] && return 0
    [ "$ad" -lt "$bd" ] && return 1
    [ "$at" -gt "$bt" ] && return 0
    return 1
}

# request_last <N> - N nejnovejsich fotek.
# Busybox nema sort, takze se N-krat hleda maximum - pri REQUEST_MAX <= 5
# a stovkach souboru je to zanedbatelne.
request_last() {
    want="$1"
    [ "$want" -gt "$REQUEST_MAX" ] && want="$REQUEST_MAX"

    taken=""
    i=0
    while [ "$i" -lt "$want" ]; do
        best=""
        for f in $(find "$SDCARD/snaps" -type f -name '*.jpg' 2>/dev/null); do
            case "
$taken" in
                *"
$f"*) continue ;;
            esac
            if [ -z "$best" ] || snap_newer "$f" "$best"; then
                best="$f"
            fi
        done
        [ -z "$best" ] && break
        taken="$taken
$best"
        request_add "$best" || break
        i=$((i + 1))
    done
}

# request_date <YYMMDD>
request_date() {
    d="$1"
    for f in $(find "$SDCARD/snaps/$d" -type f -name '*.jpg' 2>/dev/null); do
        request_add "$f" || break
    done
}

# request_get <jmeno> - jen holy nazev souboru; cokoli s "/" nebo ".."
# se odmita, aby se pres nej nedalo sahnout mimo snaps/.
request_get() {
    name="$1"
    case "$name" in
        */*|*..*|"") return 2 ;;
    esac
    for f in $(find "$SDCARD/snaps" -type f -name "$name" 2>/dev/null); do
        request_add "$f"
        return 0
    done
    return 1
}
```

Pak větve do `case` v `execute_command` (před `*)`):

```sh
        [Ll][Aa][Ss][Tt]" "*)
            n=$(trim "${cmd#* }")
            case "$n" in
                ''|*[!0-9]*) CMD_REPLY='LAST: INVALID COUNT'; return 0 ;;
            esac
            [ "$n" -lt 1 ] && { CMD_REPLY='LAST: INVALID COUNT'; return 0; }
            request_last "$n"
            got=$(request_count)
            if [ "$got" = 0 ]; then
                CMD_REPLY='LAST: NOT FOUND'
            elif [ "$n" -gt "$REQUEST_MAX" ]; then
                CMD_REPLY="SENDING $got (capped at REQUEST_MAX=$REQUEST_MAX)"
            else
                CMD_REPLY="SENDING $got"
            fi
            ;;

        [Dd][Aa][Tt][Ee]" "*)
            d=$(trim "${cmd#* }")
            case "$d" in
                [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
                *) CMD_REPLY='DATE: INVALID FORMAT'; return 0 ;;
            esac
            request_date "$d"
            got=$(request_count)
            if [ "$got" = 0 ]; then
                CMD_REPLY='DATE: NOT FOUND'
            else
                CMD_REPLY="SENDING $got"
            fi
            ;;

        [Gg][Ee][Tt]" "*)
            name=$(trim "${cmd#* }")
            request_get "$name"
            case "$?" in
                0) CMD_REPLY="SENDING $(request_count)" ;;
                1) CMD_REPLY='GET: NOT FOUND' ;;
                2) CMD_REPLY='GET: INVALID NAME' ;;
            esac
            ;;
```

- [ ] **Step 4: Inicializovat `REQUESTED_SNAPS` v `hunter.sh`**

Za `MAIN_PID=$$` přidej:

```sh
REQUESTED_SNAPS=""
```

- [ ] **Step 5: Spustit testy**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && sh tests/run_tests.sh
```

Expected: `prosly: 5   selhaly: 0`

- [ ] **Step 6: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add tests/test_request.sh hunter/lib/command.sh hunter/hunter.sh
git commit -m "feat: vyzadani fotek prikazy LAST/DATE/GET

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 12: Transport `process_mail`

**Files:**
- Create: `hunter/lib/mailcmd.sh`
- Create: `tests/test_mailcmd.sh`
- Modify: `hunter/lib/mail.sh`

**Interfaces:**
- Consumes: `mailrecv` (Task 5, 6), `authorize_mail()` (Task 8), `execute_command()` (Task 9).
- Produces: `process_mail()`; `send_reply_mail(<komu>, <text>)`.

- [ ] **Step 1: Napsat padající test `tests/test_mailcmd.sh`**

```sh
#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

# fake mailrecv: "list unseen" vrati pripravene radky ze souboru,
# "seen" jen zapise UID do seen.log
cat > "$HUNTER_DIR/bin/mailrecv" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    list) cat "$FIX/listing.txt" 2>/dev/null; exit 0 ;;
    seen) shift; echo "\$@" >> "$FIX/seen.log"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$HUNTER_DIR/bin/mailrecv"

# fake mailsend: zapisuje argumenty do sent.log
cat > "$HUNTER_DIR/bin/mailsend" <<EOF
#!/bin/sh
echo "\$@" >> "$FIX/sent.log"
exit 0
EOF
chmod +x "$HUNTER_DIR/bin/mailsend"

ensure_app_frozen() { FROZEN=1; }
FROZEN=0

# --- autorizovany prikaz se vykona a odpovi ---
printf 'UIDVALIDITY|999\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_contains "klic vc. UIDVALIDITY v mail_seen" "$(cat "$STATE_DIR/mail_seen.txt")" "999|101"
assert_contains "oznaceno jako seen"      "$(cat "$FIX/seen.log")" "101"
assert_contains "odpoved odeslana"        "$(cat "$FIX/sent.log")" "HUNTER reply"
assert_eq       "aplikace zmrazena"       "$FROZEN" "1"

# --- odpoved nesmi citovat prichozi predmet (token!) ---
assert_not_contains "odpoved neobsahuje token" "$(cat "$FIX/sent.log")" "tajnytoken1"

# --- zprava bez prefixu se NEDOTKNE ---
printf 'UIDVALIDITY|999\nMSG|202|kdokoli@example.com|Newsletter: sleva 50%%\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_eq "cizi posta se neoznaci prectenou" "$(cat "$FIX/seen.log")" ""
assert_eq "na cizi postu se neodpovida"      "$(cat "$FIX/sent.log")" ""

# --- neautorizovany odesilatel: oznaci se, ale neodpovida ---
printf 'UIDVALIDITY|999\nMSG|303|cizi@example.com|HUNTER tajnytoken1 STATUS\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
process_mail
assert_contains "neautorizovany se oznaci prectenym" "$(cat "$FIX/seen.log")" "303"
assert_eq       "neautorizovanemu se neodpovida"     "$(cat "$FIX/sent.log")" ""

# --- deduplikace: stejne UID podruhe se nevykona ---
printf 'UIDVALIDITY|999\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 QUALITY LOW\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
QUALITY=HD
process_mail
assert_eq "duplicitni UID se nevykona" "$QUALITY" "HD"
assert_contains "ale oznaci se prectenym" "$(cat "$FIX/seen.log")" "101"

# --- jina UIDVALIDITY = jina schranka, stejne UID se vykona znovu ---
printf 'UIDVALIDITY|1000\nMSG|101|paja.stindl@seznam.cz|HUNTER tajnytoken1 QUALITY LOW\n' > "$FIX/listing.txt"
: > "$FIX/seen.log"; : > "$FIX/sent.log"
QUALITY=HD
process_mail
assert_eq "po zmene UIDVALIDITY se vykona" "$QUALITY" "LOW"

fixture_teardown
finish
```

- [ ] **Step 2: Spustit — musí selhat**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && dash tests/test_mailcmd.sh
```

- [ ] **Step 3: Přidat `send_reply_mail` do `hunter/lib/mail.sh`**

```sh
# send_reply_mail <komu> <text>
# Odpoved na prikaz. Predmet je VZDY "HUNTER reply" - prichozi predmet
# se NIKDY necituje, protoze je v nem token.
send_reply_mail() {
    to="$1"
    text="$2"
    "$HUNTER_DIR/bin/mailsend" \
        --host "$SMTP_HOST" --port "$SMTP_PORT" \
        --user "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
        --to "$to" --subject "HUNTER reply" \
        --body "$text" \
        --tls "$SMTP_TLS" \
        >> "$LOG_FILE" 2>&1
}
```

- [ ] **Step 4: Vytvořit `hunter/lib/mailcmd.sh`**

```sh
# mailcmd.sh - transport prikazu pres e-mail (IMAP).
#
# Zrcadlo lib/sms.sh: nacte neprectene zpravy, autorizuje, vykona pres
# spolecny execute_command() z lib/command.sh, odpovi a uklidi.
#
# Poradi kroku je zamerne stejne jako u SMS: dedup-zapis PRED vykonanim,
# oznaceni \Seen AZ PO vykonani a odpovedi. Kdyby zarizeni zhaslo mezi
# vykonanim a oznacenim, priste je zprava porad neprectena - ale
# mail_seen.txt uz UID ma, takze se jen tise oznaci bez druheho vykonani.
#
# TVRDE PRAVIDLO: zpravy bez prefixu "HUNTER " se NEDOTYKAME vubec -
# ani ji neoznacime prectenou. Ctem stejnou schranku, ze ktere Hunter
# odesila, a nesmime prebirat cizi postu.

process_mail() {
    [ -n "$IMAP_HOST" ] || { log "IMAP_HOST nenastaven, prikazy preskoceny"; return 0; }
    [ -f "$HUNTER_DIR/smtp.pass" ] || { log "chybi smtp.pass, prikazy preskoceny"; return 0; }

    listing=$("$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
                "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
                list unseen 2>>"$LOG_FILE")
    [ -z "$listing" ] && return 0

    # UIDVALIDITY je soucasti dedup klice: po (vzacnem) znovuvytvoreni
    # schranky zacnou UID od zacatku a bez tohoto cisla by se novy prikaz
    # mohl tise preskocit jako "uz zpracovany".
    mail_uidvalidity="0"

    old_ifs="$IFS"
    IFS='
'
    for line in $listing; do
        IFS="$old_ifs"
        case "$line" in
            UIDVALIDITY\|*)
                mail_uidvalidity="${line#*|}"
                IFS='
'; continue ;;
            MSG\|*) ;;
            *) IFS='
'; continue ;;
        esac

        # MSG|uid|odesilatel|predmet - predmet je POSLEDNI pole a muze
        # obsahovat "|", takze se zbytek po tretim poli spoji zpet.
        field_ifs="$IFS"
        IFS='|'
        set -- $line
        IFS="$field_ifs"

        uid="$2"
        from="$3"
        shift 3
        subject="$*"

        # Zprava, ktera neni nase - NESAHAT na ni.
        case "$subject" in
            [Hh][Uu][Nn][Tt][Ee][Rr]" "*) ;;
            *) IFS='
'; continue ;;
        esac

        key="$mail_uidvalidity|$uid"
        if [ -f "$STATE_DIR/mail_seen.txt" ] && \
           fgrep -qxF "$key" "$STATE_DIR/mail_seen.txt" 2>/dev/null; then
            log "mail UID $uid jiz zpracovan drive (vypadek napajeni?), jen oznacuji"
            "$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
                "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
                seen "$uid" >>"$LOG_FILE" 2>&1
            IFS='
'; continue
        fi

        # Az ted je jiste, ze je co delat - zmrazit aplikaci, aby
        # zarizeni nezhaslo uprostred zpracovani.
        ensure_app_frozen

        printf '%s\n' "$key" >> "$STATE_DIR/mail_seen.txt"
        sync

        authorize_mail "$from" "$subject"
        if [ "$AUTH_OK" != 1 ]; then
            # Token se NIKDY neloguje - logujeme jen odesilatele.
            log "mail od '$from' neautorizovan (rezim $AUTH_TYPE), odmitnuto bez odpovedi"
            "$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
                "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
                seen "$uid" >>"$LOG_FILE" 2>&1
            IFS='
'; continue
        fi

        log "mail prikaz od $from: $AUTH_CMD"
        CMD_REPLY=""
        execute_command "$AUTH_CMD" "$AUTH_HAS_TOKEN"

        if [ "$CONFIRM" = "ON" ] && [ -n "$CMD_REPLY" ]; then
            send_reply_mail "$from" "$CMD_REPLY"
        fi

        "$HUNTER_DIR/bin/mailrecv" "$IMAP_HOST" "$IMAP_PORT" \
            "$SMTP_USER" --pass-file "$HUNTER_DIR/smtp.pass" \
            seen "$uid" >>"$LOG_FILE" 2>&1

        IFS='
'
    done
    IFS="$old_ifs"
}
```

- [ ] **Step 5: Zdrojovat v `hunter.sh` i v testovací fixture**

V `hunter/hunter.sh` za `. "$HUNTER_DIR/lib/mail.sh"` přidej:

```sh
. "$HUNTER_DIR/lib/mailcmd.sh"
```

V `tests/fixture.sh` přidej stejný řádek za `. "$ROOT/hunter/lib/command.sh"`:

```sh
    . "$ROOT/hunter/lib/mailcmd.sh"
```

(Do Tasku 12 tam být nemohl — soubor do teď neexistoval a rozbil by
testy Tasků 7–11.)

- [ ] **Step 6: Spustit testy**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && sh tests/run_tests.sh
```

Expected: `prosly: 6   selhaly: 0`

- [ ] **Step 7: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add tests/test_mailcmd.sh hunter/lib/mailcmd.sh hunter/lib/mail.sh hunter/hunter.sh
git commit -m "feat: process_mail - transport prikazu pres IMAP

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 13: Integrace do `hunter.sh` a `ensure_app_frozen`

Opravuje i **stávající** díru: dnes se `ubia_first` mrazí jen ve fotkové větvi, takže `process_sms` (a nově `process_mail`) běží nechráněné, přestože taky trvají desítky sekund.

**Files:**
- Modify: `hunter/hunter.sh`
- Create: `tests/test_frozen.sh`

**Interfaces:**
- Produces: `ensure_app_frozen()` — volají ji `process_sms`, `process_mail` a fotková větev.

- [ ] **Step 1: Napsat test `tests/test_frozen.sh`**

```sh
#!/bin/sh
# Overuje idempotenci ensure_app_frozen - tri volaci mista smi zmrazit
# aplikaci dohromady nejvys jednou.
. "$(dirname "$0")/assert.sh"

STOPPED_APP=0
APP_PID=""
FREEZE_CALLS=0
LOG_FILE=/dev/null

log() { :; }
pidof() { echo 4242; }
kill() { FREEZE_CALLS=$((FREEZE_CALLS + 1)); return 0; }

ensure_app_frozen() {
    [ "$STOPPED_APP" = 1 ] && return 0
    APP_PID=$(pidof ubia_first)
    if [ -z "$APP_PID" ]; then
        log "VAROVANI: ubia_first neni v ps, pokracuji bez SIGSTOP"
        return 0
    fi
    kill -STOP "$APP_PID"
    STOPPED_APP=1
    log "ubia_first (pid $APP_PID) zmrazen"
    return 0
}

ensure_app_frozen
ensure_app_frozen
ensure_app_frozen
assert_eq "tri volani = jedno zmrazeni" "$FREEZE_CALLS" "1"
assert_eq "priznak nastaven"            "$STOPPED_APP"  "1"
assert_eq "PID zapamatovan"             "$APP_PID"      "4242"

# kdyz aplikace nebezi, nezmrazi se nic a nespadne to
STOPPED_APP=0; APP_PID=""; FREEZE_CALLS=0
pidof() { echo ""; }
ensure_app_frozen
assert_eq "bez ubia_first se nemrazi" "$FREEZE_CALLS" "0"
assert_eq "priznak zustava 0"         "$STOPPED_APP"  "0"

finish
```

- [ ] **Step 2: Spustit — projde (test je samostatný), pak upravit `hunter.sh`**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast" && dash tests/test_frozen.sh
```

- [ ] **Step 3: Přidat `ensure_app_frozen` do `hunter/hunter.sh`**

Za definici `cleanup()` a `trap`:

```sh
# ensure_app_frozen
# Idempotentni: zmrazi ubia_first nejvys jednou za beh. Volaji ji VSECHNA
# mista, ktera potrebuji zarizeni drzet naziv - process_sms, process_mail
# i fotkova vetev. Diky idempotenci se muze volat kolikrat chce.
#
# Volat az ve chvili, kdy je JISTE, ze je co delat - pri probuzeni, kdy
# neni zadny prikaz ani fotka, se nemrazi vubec a zarizeni usne normalne.
#
# Signal se vola JMENEM (-STOP), nikdy cislem - MIPS ma jina cisla.
ensure_app_frozen() {
    [ "$STOPPED_APP" = 1 ] && return 0
    APP_PID=$(pidof ubia_first)
    if [ -z "$APP_PID" ]; then
        log "VAROVANI: ubia_first neni v ps, pokracuji bez SIGSTOP"
        return 0
    fi
    kill -STOP "$APP_PID"
    STOPPED_APP=1
    log "ubia_first (pid $APP_PID) zmrazen"
    return 0
}
```

- [ ] **Step 4: Zavolat `process_mail` a sloučit vyžádané fotky**

Nahraď blok od `process_sms` po konec fotkové větve:

```sh
process_sms
process_mail

snap_list=$(wait_for_candidates)

# Vyzadane fotky (LAST/DATE/GET) se pripoji k automatickym kandidatum,
# aby se mrazilo jen jednou a poslalo v jedne davce.
if [ -n "$REQUESTED_SNAPS" ]; then
    if [ -n "$snap_list" ]; then
        snap_list="$REQUESTED_SNAPS
$snap_list"
    else
        snap_list="$REQUESTED_SNAPS"
    fi
fi

if [ -n "$snap_list" ]; then
    ensure_app_frozen

    sent=0
    old_ifs="$IFS"
    IFS='
'
    for snap in $snap_list; do
        IFS="$old_ifs"
        [ "$sent" -ge "$MAX_SEND_PER_WAKE" ] && break
        [ -f "$snap" ] || { IFS='
'; continue; }

        if send_snap "$snap"; then
            # Do sent_list.txt patri jen automaticky odeslane snimky.
            # Vyzadane se tam nezapisuji - jinak by se pri prvnim
            # vyzadani oznacily za odeslane a uz by nikdy neodesly
            # automaticky.
            case "
$REQUESTED_SNAPS" in
                *"
$snap"*) ;;
                *) printf '%s\n' "$snap" >> "$STATE_DIR/sent_list.txt"; sync ;;
            esac
            sent=$((sent + 1))
            log "odeslano: $snap"
        else
            log "CHYBA pri odesilani (zkusi se priste): $snap"
        fi
        IFS='
'
    done
    IFS="$old_ifs"

    if [ "$STOPPED_APP" = 1 ]; then
        kill -CONT "$APP_PID" 2>/dev/null
        STOPPED_APP=0
        log "ubia_first pokracuje"
    fi

    sleep 5
else
    log "nic k odeslani"
fi
```

**Pozor na strop:** vyžádané fotky jsou v seznamu první, takže se pošlou přednostně. `MAX_SEND_PER_WAKE` musí být aspoň tak velké jako `REQUEST_MAX`, jinak by vyžádané fotky vytlačily automatické. Zvyš výchozí `MAX_SEND_PER_WAKE` v `config.txt.example` na `8`.

- [ ] **Step 5: Přidat `ensure_app_frozen` do `process_sms`**

V `hunter/lib/sms.sh` za kontrolu deduplikace, těsně před `printf '%s\n' "$key" >> ...`:

```sh
        ensure_app_frozen
```

- [ ] **Step 6: Ověřit syntaxi a spustit celou sadu**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
for f in hunter/hunter.sh hunter/lib/*.sh; do dash -n "$f" && echo "OK $f"; done
sh tests/run_tests.sh
```

Expected: všechny soubory OK, `prosly: 7   selhaly: 0`

- [ ] **Step 7: Ověřit, že v souborech pro zařízení nejsou tabulátory**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
grep -Pn '\t' hunter/hunter.sh hunter/lib/*.sh && echo "NASEL TABULATOR - opravit!" || echo "OK, zadne tabulatory"
```

Expected: `OK, zadne tabulatory`. Kdyby nějaký byl, nahraď ho `"$(printf '\t')"`.

- [ ] **Step 8: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add hunter/hunter.sh hunter/lib/sms.sh hunter/config.txt.example tests/test_frozen.sh
git commit -m "feat: ensure_app_frozen + integrace e-mailovych prikazu do hunter.sh

Opravuje i stavajici diru: process_sms dosud bezel nezmrazeny.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 14: Build, nasazení a ostrý test

**Files:**
- Modify: `CHECKLIST.md`
- Modify: `hunter/README.md`
- Modify: `docs/superpowers/specs/2026-08-27-hunter-design.md`

- [ ] **Step 1: Přeložit všechny nástroje pro mipsel**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  "cd ~/fotopast/test_files && make clean && make 2>&1 | tail -20 && make strip && ls -la mailrecv mailsend"
```

Expected: `mailrecv` i `mailsend` existují.

- [ ] **Step 2: Ověřit ABI proti `ubia_first`**

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  "cd ~/fotopast/test_files && readelf -h mailrecv | grep -E 'Class|Data|Machine' && readelf -A mailrecv | grep -i 'fp abi'"
```

Expected: `ELF32`, `little endian`, `MIPS`, FP ABI `Hard float (32-bit CPU, 32-bit FPU)` — musí sedět s `ubia_first`.

- [ ] **Step 3: Zkopírovat na kartu (fyzicky přes čtečku)**

Vytáhni SD kartu a zkopíruj:

| Z Pi (`~/fotopast/`) | Na kartu |
|---|---|
| `test_files/mailrecv` | `hunter/bin/mailrecv` |
| `test_files/mailsend` | `hunter/bin/mailsend` (přeložený nanovo po refaktoru) |
| `hunter/lib/command.sh` | `hunter/lib/command.sh` |
| `hunter/lib/mailcmd.sh` | `hunter/lib/mailcmd.sh` |
| `hunter/lib/sms.sh` | `hunter/lib/sms.sh` |
| `hunter/lib/mail.sh` | `hunter/lib/mail.sh` |
| `hunter/lib/common.sh` | `hunter/lib/common.sh` |
| `hunter/hunter.sh` | `hunter/hunter.sh` |

**Přes UART to neposílej** — binárky jsou příliš velké a přenos požírá tabulátory (viz `pi-tools/README.md`).

Na kartě rovnou vytvoř `hunter/mail.token` (jeden token na řádek, aspoň 8 znaků) a doplň do `hunter/config.txt` nové klíče z `config.txt.example`.

- [ ] **Step 4: Ověřit integritu po zkopírování**

Vrať kartu, připoj se přes UART a porovnej kontrolní součty s Pi:

```bash
ssh -F "C:/Users/Public/fotopast/.ssh/config" fotopast-build \
  "cd ~/fotopast && md5sum test_files/mailrecv hunter/lib/*.sh hunter/hunter.sh"
```

Na zařízení: `md5sum /tmp/mnt/sdcard/hunter/bin/mailrecv /tmp/mnt/sdcard/hunter/lib/*.sh /tmp/mnt/sdcard/hunter/hunter.sh`

Expected: součty sedí. `sh -n` na to nestačí — poškozený soubor může být pořád syntakticky platný.

- [ ] **Step 5: Ověřit `mailrecv` přímo na zařízení**

```
/tmp/mnt/sdcard/hunter/bin/mailrecv imap.seznam.cz 993 \
  fotopast.pajsti@seznam.cz --pass-file /tmp/mnt/sdcard/hunter/smtp.pass list unseen
```

Expected: buď prázdno, nebo `MSG|...` řádky. Když `Exec format error`, ABI nesedí — zpět na Step 2.

- [ ] **Step 6: Ostrý test celého kanálu**

Pošli z autorizované adresy mail s předmětem:
```
HUNTER <tvuj-token> LIST CMD
```

Pak na zařízení ručně spusť `sh /tmp/mnt/sdcard/hunter/hunter.sh` a zkontroluj:

- [ ] `log.txt` obsahuje `mail prikaz od <adresa>: LIST CMD`
- [ ] `log.txt` **neobsahuje** hodnotu tokenu (`grep '<tvuj-token>' log.txt` musí být prázdný)
- [ ] přišla odpověď s předmětem `HUNTER reply` a výpisem příkazů
- [ ] odpověď **neobsahuje** hodnotu tokenu

Pak zkus `HUNTER <token> LAST 2` a ověř, že dorazí dvě fotky.

- [ ] **Step 7: Ověřit, že cizí pošta zůstala nedotčená**

Pošli do schránky běžný mail (bez prefixu `HUNTER`), spusť `hunter.sh` a zkontroluj ve schránce, že **zůstal nepřečtený**.

- [ ] **Step 8: Aktualizovat dokumentaci**

V `CHECKLIST.md` přidej za fázi 5 novou fázi pro e-mailové příkazy (vytvoření `mail.token`, doplnění `MAIL_MASTERS`/`IMAP_HOST`, test `LIST CMD`).

V `hunter/README.md` popiš příkazový kanál a tvar předmětu.

V `docs/superpowers/specs/2026-08-27-hunter-design.md` uprav sekci 7 — SMS příkazy nahrazuje e-mail, s odkazem na nový spec.

- [ ] **Step 9: Commit**

```bash
cd "/c/Users/Pája Štindl/Downloads/Fotopast"
git add CHECKLIST.md hunter/README.md docs/
git commit -m "docs: e-mailovy prikazovy kanal - checklist a README

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
