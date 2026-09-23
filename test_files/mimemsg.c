/* mimemsg.c - viz mimemsg.h */
#include <stdio.h>
#include <string.h>
#include "mimemsg.h"

/* Boundary je konstantni. Nahodny by nic nepridal: zpravy nejsou
 * vnorene a obsah prilohy je base64, takze se s nim boundary nemuze
 * potkat. */
static const char *BOUNDARY = "hunter-XBOUND-8f2a";

static const char b64tab[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* ---------------------------------------------------------------- base64 */

/* Druha kopie teto funkce je v mailsend.c - tam je pro AUTH LOGIN/AUTH
 * PLAIN, tady pro base64 kodovani prilohy. Neni sdilena schvalne, viz
 * komentar u mimemsg.h. */

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

static const char *basename_of(const char *path)
{
    const char *s = strrchr(path, '/');
    return s ? s + 1 : path;
}

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
    /* Kratke cteni (vytazena SD karta, I/O chyba) by jinak tise skoncilo
     * cyklus, jako by priloha byla u konce - mimemsg_size i mimemsg_emit
     * by se pak shodly na kratsi, ale poskozene priloze a nikdo by si
     * toho nevsiml. */
    if (ferror(f)) return -1;
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
            fprintf(stderr, "%s: prilohu %s nelze otevrit, posilam bez ni\n",
                    m->progname ? m->progname : "mimemsg", m->attach);
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
