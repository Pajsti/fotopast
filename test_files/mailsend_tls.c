/* mailsend.c - SMTP client with STARTTLS + AUTH LOGIN + base64 attachment.
 * Sends camera snaps via a real email account (Gmail/Seznam/etc "app password").
 *
 * Usage:
 *   mailsend <smtp_host> <smtp_port> <username> <password> <to> <subject> <file>
 *
 * Example (Gmail, use an App Password, not your normal password):
 *   mailsend smtp.gmail.com 587 myaccount@gmail.com xxxxxxxxxxxxxxxx myaccount@gmail.com "Snap" /path/img.jpg
 *
 * Build (static, MIPS little-endian, musl toolchain):
 *   mipsel-linux-musl-gcc -static -O2 -I<mbedtls>/include -o mailsend mailsend.c \
 *       <mbedtls>/library/*.o   (see build instructions provided separately)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>

#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/error.h"

static mbedtls_net_context net_ctx;
static mbedtls_ssl_context ssl_ctx;
static mbedtls_ssl_config ssl_conf;
static mbedtls_entropy_context entropy;
static mbedtls_ctr_drbg_context ctr_drbg;
static int use_tls = 0;

static const char b64tab[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64_encode_buf(const unsigned char *in, size_t n, char *out) {
    size_t i, o = 0;
    for (i = 0; i < n; i += 3) {
        unsigned int v = in[i] << 16;
        if (i + 1 < n) v |= in[i + 1] << 8;
        if (i + 2 < n) v |= in[i + 2];
        out[o++] = b64tab[(v >> 18) & 0x3F];
        out[o++] = b64tab[(v >> 12) & 0x3F];
        out[o++] = (i + 1 < n) ? b64tab[(v >> 6) & 0x3F] : '=';
        out[o++] = (i + 2 < n) ? b64tab[v & 0x3F] : '=';
    }
    out[o] = 0;
}

/* --- I/O helpers that work before/after STARTTLS --- */
static void io_write(const char *buf, size_t len) {
    if (use_tls) {
        int ret;
        size_t off = 0;
        while (off < len) {
            ret = mbedtls_ssl_write(&ssl_ctx, (const unsigned char *)buf + off, len - off);
            if (ret < 0) { fprintf(stderr, "tls write fail %d\n", ret); exit(1); }
            off += ret;
        }
    } else {
        write(net_ctx.fd, buf, len);
    }
}

static int io_read(char *buf, size_t buflen) {
    int n;
    if (use_tls) {
        n = mbedtls_ssl_read(&ssl_ctx, (unsigned char *)buf, buflen - 1);
    } else {
        n = read(net_ctx.fd, buf, buflen - 1);
    }
    if (n > 0) buf[n] = 0;
    return n;
}

static void send_line(const char *s) { io_write(s, strlen(s)); }

static void read_reply(char *buf, size_t buflen) {
    io_read(buf, buflen);
    fprintf(stderr, "S: %s", buf);
}

static void send_base64_file(FILE *f) {
    unsigned char in[750];
    char out[1024];
    size_t n;
    while ((n = fread(in, 1, sizeof(in), f)) > 0) {
        b64_encode_buf(in, n, out);
        io_write(out, strlen(out));
        io_write("\r\n", 2);
    }
}

int main(int argc, char **argv) {
    if (argc < 8) {
        fprintf(stderr, "usage: %s host port user pass to subject file\n", argv[0]);
        return 1;
    }
    const char *host = argv[1];
    const char *port = argv[2];
    const char *user = argv[3];
    const char *pass = argv[4];
    const char *to = argv[5];
    const char *subject = argv[6];
    const char *filepath = argv[7];

    char buf[1024];
    char line[1024];

    mbedtls_net_init(&net_ctx);
    mbedtls_ssl_init(&ssl_ctx);
    mbedtls_ssl_config_init(&ssl_conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    if (mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                               (const unsigned char *)"mailsend", 8) != 0) {
        fprintf(stderr, "drbg seed fail\n"); return 1;
    }

    if (mbedtls_net_connect(&net_ctx, host, port, MBEDTLS_NET_PROTO_TCP) != 0) {
        fprintf(stderr, "connect fail\n"); return 1;
    }

    /* plaintext phase */
    read_reply(buf, sizeof(buf));
    snprintf(line, sizeof(line), "EHLO camera\r\n"); send_line(line); read_reply(buf, sizeof(buf));
    send_line("STARTTLS\r\n"); read_reply(buf, sizeof(buf));

    /* TLS handshake */
    if (mbedtls_ssl_config_defaults(&ssl_conf, MBEDTLS_SSL_IS_CLIENT,
                                     MBEDTLS_SSL_TRANSPORT_STREAM,
                                     MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
        fprintf(stderr, "ssl config fail\n"); return 1;
    }
    /* NOTE: certificate verification disabled for simplicity (embedded device,
       no CA bundle). This means TLS is encrypted but not verifying server identity. */
    mbedtls_ssl_conf_authmode(&ssl_conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_rng(&ssl_conf, mbedtls_ctr_drbg_random, &ctr_drbg);

    if (mbedtls_ssl_setup(&ssl_ctx, &ssl_conf) != 0) {
        fprintf(stderr, "ssl setup fail\n"); return 1;
    }
    mbedtls_ssl_set_hostname(&ssl_ctx, host);
    mbedtls_ssl_set_bio(&ssl_ctx, &net_ctx, mbedtls_net_send, mbedtls_net_recv, NULL);

    int ret;
    while ((ret = mbedtls_ssl_handshake(&ssl_ctx)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            fprintf(stderr, "tls handshake fail %d\n", ret);
            return 1;
        }
    }
    use_tls = 1;

    /* re-EHLO over TLS (required) */
    snprintf(line, sizeof(line), "EHLO camera\r\n"); send_line(line); read_reply(buf, sizeof(buf));

    /* AUTH LOGIN */
    send_line("AUTH LOGIN\r\n"); read_reply(buf, sizeof(buf));
    char b64user[512], b64pass[512];
    b64_encode_buf((const unsigned char *)user, strlen(user), b64user);
    b64_encode_buf((const unsigned char *)pass, strlen(pass), b64pass);
    snprintf(line, sizeof(line), "%s\r\n", b64user); send_line(line); read_reply(buf, sizeof(buf));
    snprintf(line, sizeof(line), "%s\r\n", b64pass); send_line(line); read_reply(buf, sizeof(buf));

    /* envelope + message */
    snprintf(line, sizeof(line), "MAIL FROM:<%s>\r\n", user); send_line(line); read_reply(buf, sizeof(buf));
    snprintf(line, sizeof(line), "RCPT TO:<%s>\r\n", to); send_line(line); read_reply(buf, sizeof(buf));
    send_line("DATA\r\n"); read_reply(buf, sizeof(buf));

    snprintf(line, sizeof(line),
        "From: %s\r\nTo: %s\r\nSubject: %s\r\n"
        "MIME-Version: 1.0\r\n"
        "Content-Type: multipart/mixed; boundary=\"XBOUND\"\r\n\r\n"
        "--XBOUND\r\nContent-Type: text/plain\r\n\r\nSnap attached.\r\n\r\n"
        "--XBOUND\r\nContent-Type: image/jpeg\r\nContent-Transfer-Encoding: base64\r\n"
        "Content-Disposition: attachment; filename=\"snap.jpg\"\r\n\r\n",
        user, to, subject);
    send_line(line);

    FILE *f = fopen(filepath, "rb");
    if (f) { send_base64_file(f); fclose(f); }
    else { fprintf(stderr, "cannot open %s\n", filepath); }

    send_line("\r\n--XBOUND--\r\n.\r\n");
    read_reply(buf, sizeof(buf));
    send_line("QUIT\r\n");

    mbedtls_ssl_close_notify(&ssl_ctx);
    mbedtls_net_free(&net_ctx);
    mbedtls_ssl_free(&ssl_ctx);
    mbedtls_ssl_config_free(&ssl_conf);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);

    return 0;
}
