/* mailrecv.c - minimalni IMAP klient pro prikazovy kanal Hunteru.
 *
 * Cte JEN hlavicky (From, Subject) neprectenych zprav - cely prikaz se
 * nese v predmetu, takze tela ani prilohy nikdy nestahujeme. Tim odpada
 * parsovani MIME a dekodovani prenosovych kodovani.
 *
 * Pouziti:
 *   mailrecv <host> <port> <user> --pass-file <f> [--ca <f>] list unseen
 *   mailrecv <host> <port> <user> --pass-file <f> [--ca <f>] seen <uid>
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
        "[--ca <f>] [-v] list unseen | seen <uid>\n");
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
    } else if (!strcmp(cmd, "seen") && arg) {
        next_tag(tag, sizeof(tag));
        imap_send(tag, "UID STORE %s +FLAGS (\\Seen)", arg);
        rc = (imap_wait_tag(tag) == 0) ? 0 : 1;
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
