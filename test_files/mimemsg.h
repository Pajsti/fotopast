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
