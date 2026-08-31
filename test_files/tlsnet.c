/* tlsnet.c - sdilena sitova vrstva pro mailsend a mailrecv. Viz tlsnet.h.
 *
 * Vytazeno z mailsend.c: DNS resolver bez getaddrinfo, rucni TCP connect
 * a obsluha mbedTLS. Duvod pro vlastni resolver a rucni connect() viz
 * komentar u tlsnet_connect() nize.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
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

#include "tlsnet.h"

#define IO_TIMEOUT_MS 30000
#define RBUF_SZ 4096

static mbedtls_net_context      net_ctx;
static mbedtls_ssl_context      ssl_ctx;
static mbedtls_ssl_config       ssl_conf;
static mbedtls_entropy_context  entropy;
static mbedtls_ctr_drbg_context ctr_drbg;
static mbedtls_x509_crt         cacert;

static int use_tls = 0;   /* 1 az po uspesnem handshake */
static int verbose = 0;

static const char *progname = "tlsnet";

void tlsnet_set_progname(const char *name) { progname = name; }
void tlsnet_set_verbose(int on) { verbose = on; }
int  tlsnet_is_tls(void) { return use_tls; }

void tlsnet_die(int code, const char *msg)
{
    fprintf(stderr, "%s: %s\n", progname, msg);
    exit(code);
}

/* ------------------------------------------------------------------- I/O */

void tlsnet_write(const char *buf, size_t len)
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
        if (ret <= 0) tlsnet_die(2, "zapis do socketu selhal");
        off += (size_t)ret;
    }
}

int tlsnet_read(char *buf, size_t buflen)
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

/* ------------------------------------------------------ DNS a TCP spojeni
 *
 * mbedtls_net_connect() by normalne pouzil getaddrinfo(). Jenze nastroje
 * jsou staticky slinkovane proti glibc (mipsel-linux-gnu-gcc) a staticke
 * glibc reseni jmen jde pres NSS moduly, ktere se natahuji dlopen() az za
 * behu ("warning: Using 'getaddrinfo' in statically linked applications
 * requires at runtime the shared libraries..."). Na cilovem zarizeni
 * (uClibc, zadne glibc NSS knihovny) by to spadlo nebo tise vracelo
 * chybu. Proto vlastni, primitivni DNS-A resolver bez
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

/* Verejny wrapper nad resolve_ipv4() - vraci vyslednou adresu jako retezec
 * (pro volajici mimo tento modul, kteri nepotrebuji struct in_addr). */
int tlsnet_resolve(const char *host, char *ipbuf, size_t iplen)
{
    struct in_addr addr;

    if (resolve_ipv4(host, &addr) != 0) return -1;
    return inet_ntop(AF_INET, &addr, ipbuf, iplen) ? 0 : -1;
}

/* Nahrada za mbedtls_net_connect() - viz komentar vyse. Zaroven tu poprve
 * inicializujeme cely mbedTLS stav (net/ssl/config/entropy/ctr_drbg jsou
 * od refaktoru soukrome globaly tohoto souboru). */
void tlsnet_connect(const char *host, const char *port)
{
    struct in_addr addr;
    struct sockaddr_in sa;
    int fd;
    int portnum = atoi(port);

    mbedtls_net_init(&net_ctx);
    mbedtls_ssl_init(&ssl_ctx);
    mbedtls_ssl_config_init(&ssl_conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    if (mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                              (const unsigned char *)"hunter-mailsend", 15) != 0)
        tlsnet_die(2, "inicializace generatoru nahod selhala");

    if (resolve_ipv4(host, &addr) != 0) {
        char errmsg[300];
        snprintf(errmsg, sizeof(errmsg), "nepodarilo se preložit '%s' (DNS)", host);
        tlsnet_die(2, errmsg);
    }
    if (verbose)
        fprintf(stderr, "*: %s -> %s\n", host, inet_ntoa(addr));

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) tlsnet_die(2, "socket() selhal");

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(portnum);
    sa.sin_addr = addr;

    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        char errmsg[300];
        close(fd);
        snprintf(errmsg, sizeof(errmsg), "connect() na %s:%d selhal: %s",
                 host, portnum, strerror(errno));
        tlsnet_die(2, errmsg);
    }
    net_ctx.fd = fd;
}

/* ------------------------------------------------------------------- TLS */

void tlsnet_handshake(const char *host, const char *cafile)
{
    int ret;

    if (mbedtls_ssl_config_defaults(&ssl_conf, MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM,
                                    MBEDTLS_SSL_PRESET_DEFAULT) != 0)
        tlsnet_die(2, "mbedtls_ssl_config_defaults selhalo");

    if (cafile) {
        mbedtls_x509_crt_init(&cacert);
        if (mbedtls_x509_crt_parse_file(&cacert, cafile) != 0)
            tlsnet_die(2, "nepodarilo se nacist CA soubor");
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
        tlsnet_die(2, "mbedtls_ssl_setup selhalo");
    if (mbedtls_ssl_set_hostname(&ssl_ctx, host) != 0)
        tlsnet_die(2, "mbedtls_ssl_set_hostname selhalo");

    mbedtls_ssl_set_bio(&ssl_ctx, &net_ctx, mbedtls_net_send, NULL,
                        mbedtls_net_recv_timeout);

    while ((ret = mbedtls_ssl_handshake(&ssl_ctx)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ &&
            ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            char err[128], errmsg[200];
            mbedtls_strerror(ret, err, sizeof(err));
            snprintf(errmsg, sizeof(errmsg), "TLS handshake selhal: %s (-0x%04x)",
                     err, (unsigned)-ret);
            tlsnet_die(2, errmsg);
        }
    }
    use_tls = 1;
    if (verbose)
        fprintf(stderr, "*: TLS %s, sifra %s\n",
                mbedtls_ssl_get_version(&ssl_ctx),
                mbedtls_ssl_get_ciphersuite(&ssl_ctx));
}

/* ---------------------------------------------------------------- cleanup
 *
 * net_ctx/ssl_ctx/ssl_conf/ctr_drbg/entropy jsou od refaktoru soukrome
 * globaly tohoto souboru, takze volajici (main() v mailsend.c/mailrecv.c)
 * uz je nemuze uvolnit primo - proto jediny spolecny uklidovy bod tady.
 */
void tlsnet_close(void)
{
    if (use_tls) mbedtls_ssl_close_notify(&ssl_ctx);
    mbedtls_net_free(&net_ctx);
    mbedtls_ssl_free(&ssl_ctx);
    mbedtls_ssl_config_free(&ssl_conf);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);
}
