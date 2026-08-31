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
#include <unistd.h>
#include <time.h>
#include <ctype.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"

#define IO_TIMEOUT_MS 30000
#define RBUF_SZ 4096

enum { TLS_STARTTLS, TLS_IMPLICIT, TLS_NONE };

static mbedtls_net_context      net_ctx;
static mbedtls_ssl_context      ssl_ctx;
static mbedtls_ssl_config       ssl_conf;
static mbedtls_entropy_context  entropy;
static mbedtls_ctr_drbg_context ctr_drbg;
static mbedtls_x509_crt         cacert;

static int use_tls = 0;   /* 1 az po uspesnem handshake */
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

static void die(int code, const char *msg)
{
    fprintf(stderr, "mailsend: %s\n", msg);
    exit(code);
}

static void io_write(const char *buf, size_t len)
{
    size_t off = 0;

    while (off < len) {
        int ret;
        if (use_tls) {
            ret = mbedtls_ssl_write(&ssl_ctx, (const unsigned char *)buf + off,
                                    len - off);
            if (ret == MBEDTLS_ERR_SSL_WANT_READ ||
                ret == MBEDTLS_ERR_SSL_WANT_WRITE)
                continue;
        } else {
            ret = mbedtls_net_send(&net_ctx, (const unsigned char *)buf + off,
                                   len - off);
            if (ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        }
        if (ret <= 0) die(2, "zapis do socketu selhal");
        off += (size_t)ret;
    }
}

static void send_str(const char *s)
{
    if (verbose) fprintf(stderr, "C: %s", s);
    io_write(s, strlen(s));
}

static int io_read_some(char *buf, size_t buflen)
{
    int n;

    if (use_tls) {
        do {
            n = mbedtls_ssl_read(&ssl_ctx, (unsigned char *)buf, buflen - 1);
        } while (n == MBEDTLS_ERR_SSL_WANT_READ ||
                 n == MBEDTLS_ERR_SSL_WANT_WRITE);
    } else {
        n = mbedtls_net_recv_timeout(&net_ctx, (unsigned char *)buf,
                                     buflen - 1, IO_TIMEOUT_MS);
    }
    if (n > 0) buf[n] = '\0';
    return n;
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
        int n = io_read_some(chunk, sizeof(chunk));
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

static const char *basename_of(const char *path)
{
    const char *s = strrchr(path, '/');
    return s ? s + 1 : path;
}

/* Telo mailu po radcich, s dot-stuffingem (radek zacinajici teckou by
 * jinak SMTP ukoncil). */
static void send_text_dotstuffed(const char *text)
{
    const char *p = text;

    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char line[1024];

        if (len > sizeof(line) - 4) len = sizeof(line) - 4;
        if (len > 0 && p[0] == '.') io_write(".", 1);
        memcpy(line, p, len);
        line[len] = '\0';
        /* useknout pripadny \r na konci, doplnime vlastni CRLF */
        if (len > 0 && line[len - 1] == '\r') line[len - 1] = '\0';
        io_write(line, strlen(line));
        io_write("\r\n", 2);

        if (!nl) break;
        p = nl + 1;
    }
}

/* 57 vstupnich bajtu = 76 znaku base64. Drzi radky pod limitem 998
 * znaku z RFC 5322 - stara verze mlela po 750 bajtech, tedy 1000 znaku,
 * a cast serveru to odmita. */
static void send_base64_file(FILE *f)
{
    unsigned char in[57];
    char out[80];
    size_t n;

    while ((n = fread(in, 1, sizeof(in), f)) > 0) {
        b64_encode(in, n, out);
        io_write(out, strlen(out));
        io_write("\r\n", 2);
    }
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

/* ------------------------------------------------------ DNS a TCP spojeni
 *
 * mbedtls_net_connect() by normalne pouzil getaddrinfo(). Jenze tahle
 * binarka je staticky slinkovana proti glibc (mipsel-linux-gnu-gcc) a
 * staticke glibc reseni jmen jde pres NSS moduly, ktere se natahuji
 * dlopen() az za behu ("warning: Using 'getaddrinfo' in statically
 * linked applications requires at runtime the shared libraries..."). Na
 * cilovem zarizeni (uClibc, zadne glibc NSS knihovny) by to spadlo nebo
 * tise vracelo chybu. Proto vlastni, primitivni DNS-A resolver bez
 * getaddrinfo/gethostbyname a rucni connect() - mbedTLS pak dostane uz
 * hotovy socket, jen mu nastavime net_ctx.fd.
 */

#define DNS_TIMEOUT_MS 5000

/* Prvni "nameserver X.X.X.X" z /etc/resolv.conf. Vraci 0 pri uspechu. */
static int first_nameserver(struct in_addr *out)
{
    FILE *f = fopen("/etc/resolv.conf", "r");
    char line[256];
    int found = 0;

    if (!f) return -1;
    while (fgets(line, sizeof(line), f)) {
        char ip[64];
        if (sscanf(line, " nameserver %63s", ip) == 1) {
            if (inet_pton(AF_INET, ip, out) == 1) { found = 1; break; }
        }
    }
    fclose(f);
    return found ? 0 : -1;
}

/* Sestavi DNS dotaz typu A pro 'host' do bufferu 'q'. Vraci delku dotazu. */
static int build_dns_query(const char *host, unsigned char *q, size_t qsz)
{
    unsigned char *p = q;
    const char *label = host;

    if (qsz < 512) return -1;

    /* hlavicka: ID, flags=RD, QDCOUNT=1, ostatni 0 */
    *p++ = 0x13; *p++ = 0x37;      /* transakcni ID - staci konstanta */
    *p++ = 0x01; *p++ = 0x00;      /* RD=1 */
    *p++ = 0x00; *p++ = 0x01;      /* QDCOUNT */
    *p++ = 0x00; *p++ = 0x00;      /* ANCOUNT */
    *p++ = 0x00; *p++ = 0x00;      /* NSCOUNT */
    *p++ = 0x00; *p++ = 0x00;      /* ARCOUNT */

    /* QNAME jako posloupnost delka+label */
    while (*label) {
        const char *dot = strchr(label, '.');
        size_t len = dot ? (size_t)(dot - label) : strlen(label);
        if (len == 0 || len > 63) return -1;
        if ((size_t)(p - q) + len + 1 > qsz - 5) return -1;
        *p++ = (unsigned char)len;
        memcpy(p, label, len);
        p += len;
        label += len + (dot ? 1 : 0);
        if (!dot) break;
    }
    *p++ = 0x00;

    *p++ = 0x00; *p++ = 0x01;      /* QTYPE  = A */
    *p++ = 0x00; *p++ = 0x01;      /* QCLASS = IN */

    return (int)(p - q);
}

/* Preskoci jmeno v DNS odpovedi (label sekvence, nebo kompresni ukazatel
 * 0xC0xx) a vrati offset za nim. */
static int skip_dns_name(const unsigned char *buf, int len, int off)
{
    if (off < 0 || off >= len) return -1;
    while (off < len) {
        int l = buf[off];
        if (l == 0) return off + 1;
        if ((l & 0xC0) == 0xC0) return off + 2;   /* kompresni ukazatel */
        off += 1 + l;
    }
    return -1;
}

/* Posle DNS-A dotaz na resolver z /etc/resolv.conf a vrati prvni IPv4
 * adresu z odpovedi. Vraci 0 pri uspechu. */
static int dns_query_a(const char *host, struct in_addr *out)
{
    struct in_addr ns;
    unsigned char q[512], r[512];
    int qlen, fd, n, off, ancount, i;
    struct sockaddr_in sa;
    fd_set rfds;
    struct timeval tv;

    if (first_nameserver(&ns) != 0) return -1;
    qlen = build_dns_query(host, q, sizeof(q));
    if (qlen < 0) return -1;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(53);
    sa.sin_addr = ns;

    if (sendto(fd, q, (size_t)qlen, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }

    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    tv.tv_sec = DNS_TIMEOUT_MS / 1000;
    tv.tv_usec = (DNS_TIMEOUT_MS % 1000) * 1000;
    if (select(fd + 1, &rfds, NULL, NULL, &tv) <= 0) {
        close(fd);
        return -1;
    }

    n = (int)recvfrom(fd, r, sizeof(r), 0, NULL, NULL);
    close(fd);
    if (n < 12) return -1;

    ancount = (r[6] << 8) | r[7];
    if (ancount < 1) return -1;

    /* preskocit otazku (jmeno + QTYPE(2) + QCLASS(2)) */
    off = skip_dns_name(r, n, 12);
    if (off < 0 || off + 4 > n) return -1;
    off += 4;

    for (i = 0; i < ancount; i++) {
        int rtype, rclass, rdlen;

        off = skip_dns_name(r, n, off);
        if (off < 0 || off + 10 > n) return -1;

        rtype  = (r[off] << 8) | r[off + 1];
        rclass = (r[off + 2] << 8) | r[off + 3];
        rdlen  = (r[off + 8] << 8) | r[off + 9];
        off += 10;

        if (off + rdlen > n) return -1;

        if (rtype == 1 && rclass == 1 && rdlen == 4) {   /* A / IN */
            memcpy(out, r + off, 4);
            return 0;
        }
        off += rdlen;
    }
    return -1;
}

/* IP literal primo, jinak DNS-A dotaz. */
static int resolve_ipv4(const char *host, struct in_addr *out)
{
    if (inet_pton(AF_INET, host, out) == 1) return 0;
    return dns_query_a(host, out);
}

/* Nahrada za mbedtls_net_connect() - viz komentar vyse. */
static void net_connect_manual(mbedtls_net_context *ctx, const char *host,
                               int port)
{
    struct in_addr addr;
    struct sockaddr_in sa;
    int fd;

    if (resolve_ipv4(host, &addr) != 0) {
        fprintf(stderr, "mailsend: nepodarilo se preložit '%s' (DNS)\n", host);
        exit(2);
    }
    if (verbose)
        fprintf(stderr, "*: %s -> %s\n", host, inet_ntoa(addr));

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die(2, "socket() selhal");

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr = addr;

    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(fd);
        fprintf(stderr, "mailsend: connect() na %s:%d selhal: %s\n",
                host, port, strerror(errno));
        exit(2);
    }
    ctx->fd = fd;
}

/* ------------------------------------------------------------------- TLS */

static void tls_handshake(const char *host, const char *cafile)
{
    int ret;

    if (mbedtls_ssl_config_defaults(&ssl_conf, MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM,
                                    MBEDTLS_SSL_PRESET_DEFAULT) != 0)
        die(2, "mbedtls_ssl_config_defaults selhalo");

    if (cafile) {
        mbedtls_x509_crt_init(&cacert);
        if (mbedtls_x509_crt_parse_file(&cacert, cafile) != 0)
            die(2, "nepodarilo se nacist CA soubor");
        mbedtls_ssl_conf_ca_chain(&ssl_conf, &cacert, NULL);
        mbedtls_ssl_conf_authmode(&ssl_conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    } else {
        /* Bez CA svazku je spojeni sifrovane, ale neoveruje se identita
         * serveru - je zranitelne vuci man-in-the-middle. Na testovani ano,
         * do ostreho Hunteru dodej --ca. */
        fprintf(stderr, "mailsend: VAROVANI: bez --ca se neoveruje certifikat serveru\n");
        mbedtls_ssl_conf_authmode(&ssl_conf, MBEDTLS_SSL_VERIFY_NONE);
    }

    mbedtls_ssl_conf_rng(&ssl_conf, mbedtls_ctr_drbg_random, &ctr_drbg);
    mbedtls_ssl_conf_read_timeout(&ssl_conf, IO_TIMEOUT_MS);

    if (mbedtls_ssl_setup(&ssl_ctx, &ssl_conf) != 0)
        die(2, "mbedtls_ssl_setup selhalo");
    if (mbedtls_ssl_set_hostname(&ssl_ctx, host) != 0)
        die(2, "mbedtls_ssl_set_hostname selhalo");

    mbedtls_ssl_set_bio(&ssl_ctx, &net_ctx, mbedtls_net_send, NULL,
                        mbedtls_net_recv_timeout);

    while ((ret = mbedtls_ssl_handshake(&ssl_ctx)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ &&
            ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            char err[128];
            mbedtls_strerror(ret, err, sizeof(err));
            fprintf(stderr, "mailsend: TLS handshake selhal: %s (-0x%04x)\n",
                    err, (unsigned)-ret);
            exit(2);
        }
    }
    use_tls = 1;
    if (verbose)
        fprintf(stderr, "*: TLS %s, sifra %s\n",
                mbedtls_ssl_get_version(&ssl_ctx),
                mbedtls_ssl_get_ciphersuite(&ssl_ctx));
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
        die(3, errmsg);
    }
    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' '))
        buf[--n] = '\0';
    if (n == 0) die(3, "--pass-file je prazdny");
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
    char line[2048];
    char datebuf[64];
    const char *boundary = "hunter-XBOUND-8f2a";

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
        else if (!strcmp(argv[i], "-v"))                          verbose = 1;
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

    mbedtls_net_init(&net_ctx);
    mbedtls_ssl_init(&ssl_ctx);
    mbedtls_ssl_config_init(&ssl_conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    if (mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                              (const unsigned char *)"hunter-mailsend", 15) != 0)
        die(2, "inicializace generatoru nahod selhala");

    net_connect_manual(&net_ctx, host, atoi(port));

    /* Implicitni TLS (465): sifruje se hned, uvitani prijde uz uvnitr TLS. */
    if (tlsmode == TLS_IMPLICIT) tls_handshake(host, cafile);

    code = smtp_read_reply(rbuf, sizeof(rbuf));
    expect(code, 2, "uvitani serveru", rbuf);

    code = smtp_cmd(rbuf, sizeof(rbuf), "EHLO hunter\r\n");
    expect(code, 2, "EHLO", rbuf);

    if (tlsmode == TLS_STARTTLS) {
        code = smtp_cmd(rbuf, sizeof(rbuf), "STARTTLS\r\n");
        expect(code, 2, "STARTTLS", rbuf);
        tls_handshake(host, cafile);
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
            io_write(b64p, strlen(b64p));
            io_write("\r\n", 2);
            code = smtp_read_reply(rbuf, sizeof(rbuf));
            expect(code, 2, "AUTH LOGIN (heslo)", rbuf);
        } else {
            /* AUTH PLAIN: \0user\0pass */
            unsigned char plain[512];
            size_t ul = strlen(user), pl = strlen(pass), tot;
            char b64pl[768];

            if (ul + pl + 2 > sizeof(plain)) die(3, "prilis dlouhe udaje");
            plain[0] = 0;
            memcpy(plain + 1, user, ul);
            plain[1 + ul] = 0;
            memcpy(plain + 2 + ul, pass, pl);
            tot = ul + pl + 2;
            b64_encode(plain, tot, b64pl);

            if (verbose) fprintf(stderr, "C: AUTH PLAIN <skryto>\n");
            io_write("AUTH PLAIN ", 11);
            io_write(b64pl, strlen(b64pl));
            io_write("\r\n", 2);
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
    snprintf(line, sizeof(line),
             "From: <%s>\r\n"
             "To: <%s>\r\n"
             "Subject: %s\r\n"
             "Date: %s\r\n"
             "MIME-Version: 1.0\r\n"
             "Content-Type: multipart/mixed; boundary=\"%s\"\r\n"
             "\r\n"
             "--%s\r\n"
             "Content-Type: text/plain; charset=us-ascii\r\n"
             "Content-Transfer-Encoding: 7bit\r\n"
             "\r\n",
             from, to, subject, datebuf, boundary, boundary);
    io_write(line, strlen(line));

    send_text_dotstuffed(body);

    if (attach) {
        FILE *f = fopen(attach, "rb");
        if (!f) {
            fprintf(stderr, "mailsend: prilohu %s nelze otevrit, posilam bez ni\n",
                    attach);
        } else {
            snprintf(line, sizeof(line),
                     "\r\n--%s\r\n"
                     "Content-Type: image/jpeg; name=\"%s\"\r\n"
                     "Content-Transfer-Encoding: base64\r\n"
                     "Content-Disposition: attachment; filename=\"%s\"\r\n"
                     "\r\n",
                     boundary, basename_of(attach), basename_of(attach));
            io_write(line, strlen(line));
            send_base64_file(f);
            fclose(f);
        }
    }

    snprintf(line, sizeof(line), "\r\n--%s--\r\n.\r\n", boundary);
    io_write(line, strlen(line));

    code = smtp_read_reply(rbuf, sizeof(rbuf));
    expect(code, 2, "konec DATA", rbuf);
    printf("MAIL ODESLAN (%d)\n", code);

    smtp_cmd(rbuf, sizeof(rbuf), "QUIT\r\n");

    if (use_tls) mbedtls_ssl_close_notify(&ssl_ctx);
    mbedtls_net_free(&net_ctx);
    mbedtls_ssl_free(&ssl_ctx);
    mbedtls_ssl_config_free(&ssl_conf);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);
    return 0;
}
