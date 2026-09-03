/* mimemsg_test.c - nativni test generatoru zpravy.
 *
 * Preklada se pro hostitele (make hosttest), ne pro MIPS - overuje
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
