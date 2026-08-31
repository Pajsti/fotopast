/* smssend.c - odesle SMS pres AT+CMGS (textovy rezim).
 *
 * Pouziti:
 *   smssend <device> <baud> <cislo> <text>
 * Priklad:
 *   smssend /dev/ttyUSB2 115200 "+420603284430" "Hunter alive"
 *
 * Navratovy kod: 0 = odeslano, 1 = modem odmitl, 2 = timeout, 3 = chyba portu.
 *
 * Pozn.: textovy rezim + CSCS="GSM" znamena ASCII. Ceska diakritika se
 * po ceste rozsype - pro STATUS/potvrzovaci SMS to nevadi, jina cesta
 * by znamenala UCS2 nebo PDU rezim.
 */
#include "atport.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void report(const char *what, int rc, const char *resp) {
    printf("  %-14s %s\n", what, at_strerror(rc));
    if (resp && resp[0]) {
        char tmp[2048];
        snprintf(tmp, sizeof(tmp), "%s", resp);
        printf("                 %s\n", at_trim(tmp));
    }
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "pouziti: %s <device> <baud> <cislo> <text>\n", argv[0]);
        return 3;
    }

    const char *dev   = argv[1];
    int         baud  = atoi(argv[2]);
    const char *phone = argv[3];
    const char *msg   = argv[4];

    /* 0x1A ukoncuje zpravu a 0x1B ji rusi - v tele nemaji co delat. */
    char body[512];
    size_t bi = 0;
    const char *p;
    for (p = msg; *p && bi < sizeof(body) - 1; p++) {
        if (*p != 0x1A && *p != 0x1B) body[bi++] = *p;
    }
    body[bi] = '\0';
    if (bi == 0) {
        fprintf(stderr, "prazdny text\n");
        return 3;
    }
    if (bi > 160) {
        fprintf(stderr, "POZOR: %u znaku, modem to posle jako vic SMS\n",
                (unsigned)bi);
    }

    int fd = at_open(dev, baud);
    if (fd < 0) return 3;

    char resp[2048];
    int rc;

    printf("port %s @ %d\n", dev, baud);

    rc = at_sync(fd);
    if (rc != AT_OK) {
        fprintf(stderr, "modem neodpovida na AT (%s)\n", at_strerror(rc));
        at_close(fd);
        return rc;
    }
    printf("  modem          odpovida, echo vypnuto\n");

    /* Diagnostika - kdyz odeslani selze, tohle rekne proc. */
    rc = at_cmd(fd, "AT+CPIN?", resp, sizeof(resp), 3000);
    report("AT+CPIN?", rc, resp);
    rc = at_cmd(fd, "AT+CSQ", resp, sizeof(resp), 3000);
    report("AT+CSQ", rc, resp);
    rc = at_cmd(fd, "AT+CREG?", resp, sizeof(resp), 3000);
    report("AT+CREG?", rc, resp);

    rc = at_cmd(fd, "AT+CMGF=1", resp, sizeof(resp), 3000);
    report("AT+CMGF=1", rc, resp);
    if (rc != AT_OK) {
        fprintf(stderr, "modem neumi textovy rezim SMS\n");
        at_close(fd);
        return rc;
    }

    /* Nepovinne - kdyz to modem neumi, jedeme dal s jeho vychozi sadou. */
    at_cmd(fd, "AT+CSCS=\"GSM\"", resp, sizeof(resp), 3000);

    /* AT+CMGS a cekani na prompt '>' */
    char cmgs[128];
    snprintf(cmgs, sizeof(cmgs), "AT+CMGS=\"%s\"", phone);
    at_drain(fd);
    at_send_line(fd, cmgs);

    static const char *const prompt_needles[] = {
        ">", "\r\nERROR\r\n", "\r\n+CME ERROR:", "\r\n+CMS ERROR:"
    };
    int which = -1;
    int hit = at_read_until(fd, resp, sizeof(resp), 10000,
                            prompt_needles, 4, &which);

    if (!hit || which != 0) {
        char tmp[2048];
        snprintf(tmp, sizeof(tmp), "%s", resp);
        fprintf(stderr, "  AT+CMGS        %s\n", hit ? "odmitnuto" : "timeout");
        fprintf(stderr, "                 %s\n", at_trim(tmp));
        /* ESC, at modem nezustane viset v promptu a nesezere dalsi prikaz. */
        at_write(fd, "\x1B", 1);
        at_close(fd);
        return hit ? AT_ERROR : AT_TIMEOUT;
    }
    printf("  AT+CMGS        prompt '>' prisel\n");

    at_write(fd, body, (int)bi);
    at_write(fd, "\x1A", 1);   /* Ctrl-Z = odeslat */

    /* Odeslani pres sit muze trvat; 60 s je realny strop pri slabem signalu. */
    static const char *const final_needles[] = {
        "\r\nOK\r\n", "\r\nERROR\r\n", "\r\n+CME ERROR:", "\r\n+CMS ERROR:"
    };
    which = -1;
    hit = at_read_until(fd, resp, sizeof(resp), 60000, final_needles, 4, &which);

    char tmp[2048];
    snprintf(tmp, sizeof(tmp), "%s", resp);
    printf("  odpoved        %s\n", at_trim(tmp));

    at_close(fd);

    if (hit && which == 0) {
        printf("SMS ODESLANA\n");
        return AT_OK;
    }
    if (hit) {
        printf("SMS SELHALA (modem vratil chybu)\n");
        return AT_ERROR;
    }
    printf("SMS SELHALA (timeout)\n");
    return AT_TIMEOUT;
}
