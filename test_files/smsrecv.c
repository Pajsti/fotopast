/* smsrecv.c - cte prichozi SMS pres AT+CMGL (textovy rezim).
 *
 * Pouziti:
 *   smsrecv <device> <baud> storage            vypise AT+CPMS? a AT+CSCA?
 *   smsrecv <device> <baud> list [all|unread]  jednorazovy vypis
 *   smsrecv <device> <baud> poll <sec> [-d]    smycka; -d = po vypsani smazat
 *   smsrecv <device> <baud> del <index>        smaze jednu zpravu
 *   smsrecv <device> <baud> delall             smaze vsechny
 *
 * Vystup zprav je strojove citelny, jeden radek na zpravu:
 *   MSG|<index>|<status>|<odesilatel>|<cas>|<telo>
 * Novy radek v tele je nahrazen mezerou, aby zprava zustala na jednom radku.
 *
 * Navratovy kod: 0 = OK, 1 = modem odmitl, 2 = timeout, 3 = chyba portu.
 */
#include "atport.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RESP_SZ 32768
#define MAX_FOUND 64

/* Rozdeli hlavicku +CMGL na pole. Carky uvnitr uvozovek se ignoruji -
 * casove razitko "25/08/27,15:30:12+08" jednu takovou obsahuje. */
static int split_csv(char *s, char *out[], int maxf)
{
    int n = 0;
    int inq = 0;

    if (maxf <= 0) return 0;
    out[n++] = s;

    for (; *s; s++) {
        if (*s == '"') {
            inq = !inq;
        } else if (*s == ',' && !inq) {
            *s = '\0';
            if (n >= maxf) return n;
            out[n++] = s + 1;
        }
    }
    return n;
}

/* Odstrani obalujici uvozovky (in-place). */
static char *unquote(char *s)
{
    size_t len;

    s = at_trim(s);
    len = strlen(s);
    if (len >= 2 && s[0] == '"' && s[len - 1] == '"') {
        s[len - 1] = '\0';
        s++;
    }
    return s;
}

/* Projde odpoved na AT+CMGL a vypise MSG| radky.
 * Do found[] ulozi indexy nalezenych zprav. Vraci jejich pocet. */
static int print_messages(char *resp, int *found, int maxfound)
{
    char *line = resp;
    int count = 0;
    int have_hdr = 0;
    int idx = 0;
    char body[1024];
    char from[64];
    char stat[32];
    char when[64];

    body[0] = '\0';
    from[0] = '\0';
    stat[0] = '\0';
    when[0] = '\0';

    while (line && *line) {
        char *nl = strstr(line, "\r\n");
        if (nl) *nl = '\0';

        if (strncmp(line, "+CMGL:", 6) == 0) {
            /* predchozi zprava je hotova - vypsat ji */
            if (have_hdr) {
                printf("MSG|%d|%s|%s|%s|%s\n", idx, stat, from, when, body);
                if (count < maxfound) found[count] = idx;
                count++;
            }

            char hdr[512];
            char *f[8];
            int nf;

            snprintf(hdr, sizeof(hdr), "%s", line + 6);
            nf = split_csv(hdr, f, 8);
            idx = (nf > 0) ? atoi(at_trim(f[0])) : -1;
            snprintf(stat, sizeof(stat), "%s", (nf > 1) ? unquote(f[1]) : "");
            snprintf(from, sizeof(from), "%s", (nf > 2) ? unquote(f[2]) : "");
            snprintf(when, sizeof(when), "%s", (nf > 4) ? unquote(f[4]) : "");
            body[0] = '\0';
            have_hdr = 1;
        } else if (have_hdr) {
            char *t = at_trim(line);
            int is_term = (strcmp(t, "OK") == 0 || strcmp(t, "ERROR") == 0 ||
                           strncmp(t, "+CME ERROR", 10) == 0 ||
                           strncmp(t, "+CMS ERROR", 10) == 0);
            if (!is_term && *t) {
                if (body[0])
                    strncat(body, " ", sizeof(body) - strlen(body) - 1);
                strncat(body, t, sizeof(body) - strlen(body) - 1);
            }
        }

        if (!nl) break;
        line = nl + 2;
    }

    if (have_hdr) {
        printf("MSG|%d|%s|%s|%s|%s\n", idx, stat, from, when, body);
        if (count < maxfound) found[count] = idx;
        count++;
    }
    return count;
}

static int prepare(int fd)
{
    char resp[1024];
    int rc;

    rc = at_sync(fd);
    if (rc != AT_OK) {
        fprintf(stderr, "modem neodpovida na AT (%s)\n", at_strerror(rc));
        return rc;
    }

    rc = at_cmd(fd, "AT+CMGF=1", resp, sizeof(resp), 3000);
    if (rc != AT_OK) {
        fprintf(stderr, "AT+CMGF=1 selhalo (%s) - modem neumi textovy rezim\n",
                at_strerror(rc));
        return rc;
    }

    /* Zasadni: bez tohohle muze modem prichozi SMS poslat rovnou na
     * seriovou linku a vubec ji neulozit - AT+CMGL pak nenajde nic. */
    at_cmd(fd, "AT+CNMI=2,1,0,0,0", resp, sizeof(resp), 3000);
    at_cmd(fd, "AT+CSCS=\"GSM\"", resp, sizeof(resp), 3000);
    return AT_OK;
}

static int do_list(int fd, const char *what, int delete_after)
{
    static char resp[RESP_SZ];
    int found[MAX_FOUND];
    char cmd[64];
    int rc, n, i, lim;

    snprintf(cmd, sizeof(cmd), "AT+CMGL=\"%s\"",
             (what && strcmp(what, "unread") == 0) ? "REC UNREAD" : "ALL");

    rc = at_cmd(fd, cmd, resp, sizeof(resp), 20000);
    if (rc != AT_OK) {
        fprintf(stderr, "%s: %s\n", cmd, at_strerror(rc));
        return rc;
    }

    n = print_messages(resp, found, MAX_FOUND);
    fflush(stdout);

    if (delete_after) {
        lim = (n < MAX_FOUND) ? n : MAX_FOUND;
        for (i = 0; i < lim; i++) {
            char dc[64];
            char dr[256];
            snprintf(dc, sizeof(dc), "AT+CMGD=%d", found[i]);
            if (at_cmd(fd, dc, dr, sizeof(dr), 10000) != AT_OK)
                fprintf(stderr, "smazani indexu %d selhalo\n", found[i]);
        }
    }
    return AT_OK;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "pouziti:\n"
            "  %s <device> <baud> storage\n"
            "  %s <device> <baud> list [all|unread]\n"
            "  %s <device> <baud> poll <sec> [-d]\n"
            "  %s <device> <baud> del <index>\n"
            "  %s <device> <baud> delall\n",
            prog, prog, prog, prog, prog);
}

int main(int argc, char **argv)
{
    static char resp[RESP_SZ];
    const char *dev;
    const char *mode;
    int baud, fd, rc;

    if (argc < 4) {
        usage(argv[0]);
        return 3;
    }

    dev  = argv[1];
    baud = atoi(argv[2]);
    mode = argv[3];

    fd = at_open(dev, baud);
    if (fd < 0) return 3;

    rc = prepare(fd);
    if (rc != AT_OK) {
        at_close(fd);
        return rc;
    }

    if (strcmp(mode, "storage") == 0) {
        rc = at_cmd(fd, "AT+CPMS?", resp, sizeof(resp), 5000);
        printf("AT+CPMS?  %s\n%s\n", at_strerror(rc), resp);
        rc = at_cmd(fd, "AT+CSCA?", resp, sizeof(resp), 5000);
        printf("AT+CSCA?  %s\n%s\n", at_strerror(rc), resp);
        at_close(fd);
        return AT_OK;
    }

    if (strcmp(mode, "list") == 0) {
        rc = do_list(fd, (argc > 4) ? argv[4] : "all", 0);
        at_close(fd);
        return rc;
    }

    if (strcmp(mode, "del") == 0) {
        char cmd[64];
        if (argc < 5) {
            fprintf(stderr, "chybi index\n");
            at_close(fd);
            return 3;
        }
        snprintf(cmd, sizeof(cmd), "AT+CMGD=%d", atoi(argv[4]));
        rc = at_cmd(fd, cmd, resp, sizeof(resp), 10000);
        printf("%s  %s\n", cmd, at_strerror(rc));
        at_close(fd);
        return rc;
    }

    if (strcmp(mode, "delall") == 0) {
        /* 1,4 = smaz vse bez ohledu na stav. Kdyz to modem neumi, po jedne. */
        rc = at_cmd(fd, "AT+CMGD=1,4", resp, sizeof(resp), 25000);
        if (rc != AT_OK) {
            int i;
            fprintf(stderr, "AT+CMGD=1,4 neproslo, mazu po jedne\n");
            for (i = 1; i <= 50; i++) {
                char cmd[64];
                snprintf(cmd, sizeof(cmd), "AT+CMGD=%d", i);
                at_cmd(fd, cmd, resp, sizeof(resp), 5000);
            }
            rc = AT_OK;
        }
        printf("smazano\n");
        at_close(fd);
        return rc;
    }

    if (strcmp(mode, "poll") == 0) {
        int interval = (argc > 4) ? atoi(argv[4]) : 15;
        int del = (argc > 5 && strcmp(argv[5], "-d") == 0);

        if (interval < 1) interval = 15;
        fprintf(stderr, "poll kazdych %d s, mazani %s. Ctrl-C ukonci.\n",
                interval, del ? "zapnuto" : "vypnuto");
        for (;;) {
            do_list(fd, "unread", del);
            fflush(stdout);
            sleep(interval);
        }
    }

    fprintf(stderr, "neznamy rezim: %s\n", mode);
    at_close(fd);
    return 3;
}
