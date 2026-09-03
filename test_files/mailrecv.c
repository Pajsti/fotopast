/* mailrecv.c - minimalni IMAP klient pro prikazovy kanal Hunteru.
 *
 * Cte JEN hlavicky (From, Subject) neprectenych zprav - cely prikaz se
 * nese v predmetu, takze tela ani prilohy nikdy nestahujeme. Tim odpada
 * parsovani MIME a dekodovani prenosovych kodovani.
 *
 * Pouziti:
 *   mailrecv <host> <port> <user> --pass-file <f> [--ca <f>] list unseen
 *   mailrecv <host> <port> <user> --pass-file <f> [--ca <f>] seen <uid>
 *   mailrecv <host> <port> <user> --pass-file <f> [--ca <f>] append <slozka>
 *            --from A --to B --subject S [--body T] [--attach F]
 *
 * Bez --ca je spojeni sifrovane, ale identita serveru se NEOVERUJE (viz
 * tlsnet_handshake) - v ostrem provozu dodej CA svazek, jinak muze
 * protistranu odposlouchavat kdokoli v pozici man-in-the-middle a precist
 * si i token, ktery se veze v predmetu prikazoveho mailu.
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
#include "mimemsg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <ctype.h>

#define LINE_SZ 4096
#define INBUF_SZ 8192

static char inbuf[INBUF_SZ];
static size_t inlen = 0, inpos = 0;
static int tagseq = 0;

/* ----------------------------------------------------- cteci vrstva */

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
        "[--ca <f>] [-v] list unseen | seen <uid> |\n"
        "         append <slozka> --from A --to B --subject S [--body T] [--attach F]\n");
}

/* ----------------------------------------------------- hlavicky */

static void lowercase(char *s)
{
    for (; *s; s++) *s = (char)tolower((unsigned char)*s);
}

static void trim_ws(char *s)
{
    size_t n;
    char *p = s;
    while (*p == ' ' || *p == '\t') p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    n = strlen(s);
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

/* Sink pro mimemsg: zapisuje rovnou do TLS spojeni. Ohliduje pocet uz
 * poslanych bajtu proti ohlasenemu literalu - viz append_ctx nize. */
struct append_ctx {
    size_t written;   /* kolik bajtu uz doslo do sinku */
    size_t limit;     /* velikost literalu ohlasena v APPEND {n} */
    int overflow;     /* 1 kdyz mimemsg_emit chtel poslat vic nez limit */
};

static int append_sink(const char *buf, size_t len, void *ctx)
{
    struct append_ctx *a = ctx;
    size_t room = a->limit - a->written;

    /* Nikdy neposlat vic, nez kolik jsme serveru ohlasili v {n}. Kdyby
     * se priloha mezi mimemsg_size a mimemsg_emit zvetsila, prebytek se
     * zahodi - jinak by po literalu doslo vic bajtu, nez server cekal,
     * a rozjelo by se cele spojeni (server by zbytek precetl jako
     * dalsi IMAP prikaz). overflow se nastavi, aby volajici poznal, ze
     * se opravdu neco zahodilo - i kdyz "written == limit" vypada
     * navenek stejne jako normalni uspesny konec. */
    if (len > room) {
        a->overflow = 1;
        len = room;
    }
    if (len == 0) return 0;
    tlsnet_write(buf, len);
    a->written += len;
    return 0;
}

/* ----------------------------------------------------- main */

int main(int argc, char **argv)
{
    const char *host, *port, *user, *pass = NULL, *cmd, *arg = NULL;
    const char *cafile = NULL;
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
        else if (!strcmp(argv[i], "--ca") && i + 1 < argc)
            cafile = argv[++i];
        else if (!strcmp(argv[i], "-v"))
            tlsnet_set_verbose(1);
        else break;
    }
    if (!pass) { usage(); return 3; }
    if (i >= argc) { usage(); return 3; }

    cmd = argv[i++];
    if (i < argc) arg = argv[i];

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
            else { usage(); return 3; }
        }
        if (!arg || !ap_from || !ap_to || !ap_subject) { usage(); return 3; }
    }

    tlsnet_connect(host, port);
    tlsnet_handshake(host, cafile);

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

    /* APPEND pracuje s cizi slozkou a zadny SELECT nepotrebuje. Kdyby
     * se delal, selhani SELECTu na INBOXu by shodilo i ukladani, ktere
     * s INBOXem nema nic spolecneho. */
    if (strcmp(cmd, "append") != 0) {
        if (select_inbox() != 0)
            tlsnet_die(1, "SELECT INBOX selhal");
    }

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
    } else if (!strcmp(cmd, "seen") && arg) {
        next_tag(tag, sizeof(tag));
        imap_send(tag, "UID STORE %s +FLAGS (\\Seen)", arg);
        rc = (imap_wait_tag(tag) == 0) ? 0 : 1;
    } else if (!strcmp(cmd, "append")) {
        struct mimemsg m;
        struct append_ctx actx;
        size_t msgsz = 0;
        char qf[512];
        char line[LINE_SZ];

        memset(&m, 0, sizeof(m));
        m.from = ap_from;
        m.to = ap_to;
        m.subject = ap_subject;
        m.body = ap_body;
        m.attach = ap_attach;
        /* Datum nechavame na serveru - hodiny zarizeni nemaji zalohu a
         * INTERNALDATE ze serveru je spolehlivejsi. */
        m.date = NULL;
        m.progname = "mailrecv";

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
         * nemusi umet. Pred continuation smi server poslat libovolny
         * pocet untagged odpovedi (RFC 3501 sekce 7 - napr. "* OK
         * [ALERT] ..." nebo aktualizace EXISTS/EXPUNGE) - ty presko-
         * cime. Tagovana odpoved znamena, ze APPEND odmitl uz tady. */
        for (;;) {
            if (imap_readline(line, sizeof(line)) < 0)
                tlsnet_die(1, "server neodpovedel na APPEND");
            if (line[0] == '+') break;
            if (line[0] != '*') tlsnet_die(1, "server odmitl APPEND");
        }

        /* append_sink nikdy neposle vic nez msgsz bajtu (viz append_ctx) -
         * spojeni tak zustane v synchronu, i kdyby se priloha mezi
         * mimemsg_size a mimemsg_emit zmenila. Kdyz je kratsi, dopl-
         * nime mezerami presne na ohlasenou delku a vysledek stejne
         * ohlasime jako chybu - jinak by se do sent_list.txt zapsala
         * uspesne "odeslana" zprava s uriznutou fotkou. */
        actx.written = 0;
        actx.limit = msgsz;
        actx.overflow = 0;
        if (mimemsg_emit(&m, append_sink, &actx) != 0)
            tlsnet_die(1, "zpravu se nepodarilo odeslat");

        /* actx.written == msgsz je normalni uspesny konec, ale je to
         * TAKY stav po overflow oriznuti (append_sink nikdy neprekroci
         * limit) - proto se overflow hlida samostatnym priznakem, ne
         * odvozuje z poctu poslanych bajtu. */
        rc = 0;
        if (actx.overflow) {
            fprintf(stderr, "mailrecv: priloha behem odesilani narostla, "
                            "APPEND se zahodi\n");
            rc = 1;
        } else if (actx.written < msgsz) {
            char pad[64];
            size_t left = msgsz - actx.written;

            fprintf(stderr, "mailrecv: priloha zmenila velikost behem "
                            "odesilani, APPEND se zahodi\n");
            memset(pad, ' ', sizeof(pad));
            while (left > 0) {
                size_t n = left < sizeof(pad) ? left : sizeof(pad);
                tlsnet_write(pad, n);
                left -= n;
            }
            rc = 1;
        }
        tlsnet_write("\r\n", 2);

        if (imap_wait_tag(tag) != 0) rc = 1;
        if (rc != 0) fprintf(stderr, "mailrecv: APPEND odmitnut\n");
    } else if (!strcmp(cmd, "noop")) {
        rc = 0;
    } else {
        fprintf(stderr, "mailrecv: neznamy prikaz '%s'\n", cmd);
        rc = 3;
    }

    next_tag(tag, sizeof(tag));
    imap_send(tag, "LOGOUT");
    imap_wait_tag(tag);
    tlsnet_close();
    return rc;
}
