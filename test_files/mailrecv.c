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
