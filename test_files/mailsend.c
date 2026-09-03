/* mailsend.c - SMTP klient s STARTTLS / implicitnim TLS, AUTH LOGIN|PLAIN
 * a prilohou. Staveno pro mbedTLS 2.28 (LTS) a staticky slinkovane pro mipsel.
 *
 * Pouziti:
 *   mailsend --host <h> --port <p> --user <u> --pass <p>|--pass-file <f>
 *            --to <adr> [--from <adr>] --subject <s>
 *            [--body <text>] [--attach <soubor>]
 *            [--tls starttls|implicit|none] [--ca <soubor>] [-v]
 *
 * Priklad (Gmail, app password - ne bezne heslo do uctu):
 *   mailsend --host smtp.gmail.com --port 587 \
 *            --user fotopast@gmail.com --pass-file /tmp/mnt/sdcard/hunter/smtp.pass \
 *            --to me@example.com --subject "26/08/27 15:30:12" \
 *            --body "Battery: 87%\nSignal: 62%\nSpace: 12.480GB" \
 *            --attach /tmp/mnt/sdcard/snaps/260827/153012_000_65535_P.jpg
 *
 * Navratovy kod: 0 = odeslano, 1 = SMTP chyba, 2 = sit/TLS, 3 = spatne argumenty.
 *
 * POZOR na --pass: heslo je videt v `ps`. Na zarizeni pouzivej --pass-file.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <ctype.h>
#include <errno.h>

#include "tlsnet.h"
#include "mimemsg.h"

#define RBUF_SZ 4096

enum { TLS_STARTTLS, TLS_IMPLICIT, TLS_NONE };

/* Vlastni kopie, nezavisla na "verbose" v tlsnet.c - tahle ridi
 * SMTP-urovnove logovani "C: "/"S: " tady v mailsend.c, zatimco tlsnet.c
 * ma svou vlastni pro transportni-urovnove hlasky ("*: host -> ip",
 * "*: TLS verze/sifra"). Synchronizuje se explicitne pres
 * tlsnet_set_verbose() v main() pri zpracovani "-v". */
static int verbose  = 0;

static const char b64tab[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* ---------------------------------------------------------------- base64 */

/* Zakoduje n bajtu do out (out musi mit aspon 4*ceil(n/3)+1). */
static void b64_encode(const unsigned char *in, size_t n, char *out)
{
    size_t i, o = 0;

    for (i = 0; i < n; i += 3) {
        unsigned int v = (unsigned int)in[i] << 16;
        if (i + 1 < n) v |= (unsigned int)in[i + 1] << 8;
        if (i + 2 < n) v |= (unsigned int)in[i + 2];
        out[o++] = b64tab[(v >> 18) & 0x3F];
        out[o++] = b64tab[(v >> 12) & 0x3F];
        out[o++] = (i + 1 < n) ? b64tab[(v >> 6) & 0x3F] : '=';
        out[o++] = (i + 2 < n) ? b64tab[v & 0x3F] : '=';
    }
    out[o] = '\0';
}

/* ------------------------------------------------------------------- I/O */

static void send_str(const char *s)
{
    if (verbose) fprintf(stderr, "C: %s", s);
    tlsnet_write(s, strlen(s));
}

/* Vrati true, kdyz uz je v bufferu kompletni SMTP odpoved, tj. radek
 * tvaru "NNN<mezera>...\r\n". Viceradkove odpovedi maji "NNN-..." az do
 * posledniho radku - a prave na tohle stara verze dojela: EHLO vraci
 * vzdycky vic radku a TCP je klidne rozdeli. */
static int reply_complete(const char *buf, int *code)
{
    const char *line = buf;

    while (*line) {
        const char *nl = strstr(line, "\r\n");
        if (!nl) return 0;                 /* nedokonceny radek */
        if (isdigit((unsigned char)line[0]) &&
            isdigit((unsigned char)line[1]) &&
            isdigit((unsigned char)line[2]) &&
            line[3] == ' ') {
            if (code) *code = atoi(line);
            return 1;
        }
        line = nl + 2;
    }
    return 0;
}

/* Precte celou SMTP odpoved. Vraci 3mistny kod, nebo -1. */
static int smtp_read_reply(char *buf, size_t buflen)
{
    size_t total = 0;
    int code = -1;

    buf[0] = '\0';
    for (;;) {
        char chunk[1024];
        int n = tlsnet_read(chunk, sizeof(chunk));
        if (n <= 0) {
            if (verbose) fprintf(stderr, "S: <spojeni ukonceno / timeout>\n");
            return -1;
        }
        if (total + (size_t)n < buflen - 1) {
            memcpy(buf + total, chunk, (size_t)n);
            total += (size_t)n;
            buf[total] = '\0';
        }
        if (reply_complete(buf, &code)) break;
    }
    if (verbose) fprintf(stderr, "S: %s", buf);
    return code;
}

/* Posle prikaz a vrati kod odpovedi. */
static int smtp_cmd(char *rbuf, size_t rlen, const char *fmt, ...)
{
    char line[1024];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);

    send_str(line);
    return smtp_read_reply(rbuf, rlen);
}

/* Kod musi zacinat na 'want' (2 = 2xx, 3 = 3xx), jinak konec. */
static void expect(int code, int want, const char *step, const char *rbuf)
{
    if (code / 100 == want) return;
    fprintf(stderr, "mailsend: %s selhalo, server vratil %d\n", step, code);
    fprintf(stderr, "          %s", rbuf);
    exit(1);
}

/* ------------------------------------------------------------------ MIME */

/* Sink pro mimemsg: zapisuje rovnou do TLS spojeni. */
static int smtp_sink(const char *buf, size_t len, void *ctx)
{
    (void)ctx;
    tlsnet_write(buf, len);
    return 0;
}

static void rfc_date(char *buf, size_t len)
{
    static const char *days[] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    static const char *mons[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    time_t t = time(NULL);
    struct tm tmv;

    gmtime_r(&t, &tmv);
    snprintf(buf, len, "%s, %02d %s %04d %02d:%02d:%02d +0000",
             days[tmv.tm_wday], tmv.tm_mday, mons[tmv.tm_mon],
             tmv.tm_year + 1900, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
}

/* ------------------------------------------------------------------ main */

static char *read_pass_file(const char *path)
{
    static char buf[256];
    static char errmsg[300];
    FILE *f = fopen(path, "r");
    size_t n;

    if (!f) {
        snprintf(errmsg, sizeof(errmsg), "nelze otevrit --pass-file (%s): %s",
                 path, strerror(errno));
        tlsnet_die(3, errmsg);
    }
    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' '))
        buf[--n] = '\0';
    if (n == 0) tlsnet_die(3, "--pass-file je prazdny");
    return buf;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "pouziti: %s --host H --port P --user U (--pass P | --pass-file F)\n"
        "         --to ADR [--from ADR] --subject S [--body TEXT]\n"
        "         [--attach SOUBOR] [--tls starttls|implicit|none] [--ca F] [-v]\n",
        prog);
}

int main(int argc, char **argv)
{
    const char *host = NULL, *port = NULL, *user = NULL, *pass = NULL;
    const char *to = NULL, *from = NULL, *subject = NULL, *attach = NULL;
    const char *cafile = NULL;
    const char *body = "";
    int tlsmode = -1;
    int i, code;
    char rbuf[RBUF_SZ];
    char datebuf[64];

    tlsnet_set_progname("mailsend");

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--host") && i + 1 < argc)          host = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc)      port = argv[++i];
        else if (!strcmp(argv[i], "--user") && i + 1 < argc)      user = argv[++i];
        else if (!strcmp(argv[i], "--pass") && i + 1 < argc)      pass = argv[++i];
        else if (!strcmp(argv[i], "--pass-file") && i + 1 < argc) pass = read_pass_file(argv[++i]);
        else if (!strcmp(argv[i], "--to") && i + 1 < argc)        to = argv[++i];
        else if (!strcmp(argv[i], "--from") && i + 1 < argc)      from = argv[++i];
        else if (!strcmp(argv[i], "--subject") && i + 1 < argc)   subject = argv[++i];
        else if (!strcmp(argv[i], "--body") && i + 1 < argc)      body = argv[++i];
        else if (!strcmp(argv[i], "--attach") && i + 1 < argc)    attach = argv[++i];
        else if (!strcmp(argv[i], "--ca") && i + 1 < argc)        cafile = argv[++i];
        else if (!strcmp(argv[i], "-v")) { verbose = 1; tlsnet_set_verbose(1); }
        else if (!strcmp(argv[i], "--tls") && i + 1 < argc) {
            const char *m = argv[++i];
            if (!strcmp(m, "starttls"))      tlsmode = TLS_STARTTLS;
            else if (!strcmp(m, "implicit")) tlsmode = TLS_IMPLICIT;
            else if (!strcmp(m, "none"))     tlsmode = TLS_NONE;
            else { usage(argv[0]); return 3; }
        } else {
            fprintf(stderr, "neznamy argument: %s\n", argv[i]);
            usage(argv[0]);
            return 3;
        }
    }

    if (!host || !port || !to || !subject) { usage(argv[0]); return 3; }
    if (!from) from = user;
    if (!from) { fprintf(stderr, "chybi --from nebo --user\n"); return 3; }

    /* 465 je historicky implicitni TLS, 587/25 STARTTLS. */
    if (tlsmode < 0) tlsmode = (atoi(port) == 465) ? TLS_IMPLICIT : TLS_STARTTLS;

    tlsnet_connect(host, port);

    /* Implicitni TLS (465): sifruje se hned, uvitani prijde uz uvnitr TLS. */
    if (tlsmode == TLS_IMPLICIT) tlsnet_handshake(host, cafile);

    code = smtp_read_reply(rbuf, sizeof(rbuf));
    expect(code, 2, "uvitani serveru", rbuf);

    code = smtp_cmd(rbuf, sizeof(rbuf), "EHLO hunter\r\n");
    expect(code, 2, "EHLO", rbuf);

    if (tlsmode == TLS_STARTTLS) {
        code = smtp_cmd(rbuf, sizeof(rbuf), "STARTTLS\r\n");
        expect(code, 2, "STARTTLS", rbuf);
        tlsnet_handshake(host, cafile);
        /* Po prechodu na TLS se EHLO musi zopakovat - server az ted
         * ohlasi, ktere AUTH mechanismy povoluje. */
        code = smtp_cmd(rbuf, sizeof(rbuf), "EHLO hunter\r\n");
        expect(code, 2, "EHLO po STARTTLS", rbuf);
    }

    if (user && pass) {
        char b64u[512], b64p[512];

        code = smtp_cmd(rbuf, sizeof(rbuf), "AUTH LOGIN\r\n");
        if (code / 100 == 3) {
            b64_encode((const unsigned char *)user, strlen(user), b64u);
            code = smtp_cmd(rbuf, sizeof(rbuf), "%s\r\n", b64u);
            expect(code, 3, "AUTH LOGIN (uzivatel)", rbuf);

            b64_encode((const unsigned char *)pass, strlen(pass), b64p);
            if (verbose) fprintf(stderr, "C: <heslo skryto>\n");
            tlsnet_write(b64p, strlen(b64p));
            tlsnet_write("\r\n", 2);
            code = smtp_read_reply(rbuf, sizeof(rbuf));
            expect(code, 2, "AUTH LOGIN (heslo)", rbuf);
        } else {
            /* AUTH PLAIN: \0user\0pass */
            unsigned char plain[512];
            size_t ul = strlen(user), pl = strlen(pass), tot;
            char b64pl[768];

            if (ul + pl + 2 > sizeof(plain)) tlsnet_die(3, "prilis dlouhe udaje");
            plain[0] = 0;
            memcpy(plain + 1, user, ul);
            plain[1 + ul] = 0;
            memcpy(plain + 2 + ul, pass, pl);
            tot = ul + pl + 2;
            b64_encode(plain, tot, b64pl);

            if (verbose) fprintf(stderr, "C: AUTH PLAIN <skryto>\n");
            tlsnet_write("AUTH PLAIN ", 11);
            tlsnet_write(b64pl, strlen(b64pl));
            tlsnet_write("\r\n", 2);
            code = smtp_read_reply(rbuf, sizeof(rbuf));
            expect(code, 2, "AUTH PLAIN", rbuf);
        }
    }

    code = smtp_cmd(rbuf, sizeof(rbuf), "MAIL FROM:<%s>\r\n", from);
    expect(code, 2, "MAIL FROM", rbuf);

    code = smtp_cmd(rbuf, sizeof(rbuf), "RCPT TO:<%s>\r\n", to);
    expect(code, 2, "RCPT TO", rbuf);

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
    printf("MAIL ODESLAN (%d)\n", code);

    smtp_cmd(rbuf, sizeof(rbuf), "QUIT\r\n");

    tlsnet_close();
    return 0;
}
