/* atcmd.c - posle jeden AT prikaz na seriovy port a vypise odpoved.
 *
 * Sonda pro fazi overovani: kterym /dev/ttyUSB* modem odpovida na AT,
 * jestli umi AT+CSQ, co hlasi AT+CPIN atd. Busybox na zarizeni nema
 * stty ani microcom, takze bez tohohle se port nastavit neda.
 *
 * Pouziti:
 *   atcmd <device> <baud> <prikaz> [timeout_sec]
 *   atcmd <device> <baud> -listen  [timeout_sec]   jen poslouchat (URC)
 *
 * Priklady:
 *   atcmd /dev/ttyUSB2 115200 AT
 *   atcmd /dev/ttyUSB2 115200 "AT+CSQ"
 *   atcmd /dev/ttyUSB2 115200 -listen 30
 *
 * Navratovy kod: 0 = OK, 1 = ERROR, 2 = timeout, 3 = chyba portu.
 */
#include "atport.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr,
            "pouziti: %s <device> <baud> <prikaz|-listen> [timeout_sec]\n",
            argv[0]);
        return 3;
    }

    const char *dev = argv[1];
    int baud = atoi(argv[2]);
    const char *cmd = argv[3];
    int timeout_sec = (argc > 4) ? atoi(argv[4]) : 3;
    if (timeout_sec <= 0) timeout_sec = 3;

    int fd = at_open(dev, baud);
    if (fd < 0) return 3;

    char resp[8192];

    if (strcmp(cmd, "-listen") == 0) {
        /* Nic neposilame, jen sbirame, co port sam od sebe vyplivne.
         * Takhle se chyti +CMTI notifikace o prichozi SMS. */
        static const char *const never[] = { "\x01\x02\x03" };
        fprintf(stderr, "poslouchám %s po dobu %d s...\n", dev, timeout_sec);
        at_read_until(fd, resp, sizeof(resp), timeout_sec * 1000, never, 1, NULL);
        fputs(resp, stdout);
        if (resp[0] == '\0') fprintf(stderr, "(nic nedorazilo)\n");
        at_close(fd);
        return 0;
    }

    at_drain(fd);

    int rc = at_cmd(fd, cmd, resp, sizeof(resp), timeout_sec * 1000);
    fputs(resp, stdout);
    if (resp[0] != '\0' && resp[strlen(resp) - 1] != '\n') putchar('\n');
    fflush(stdout);

    if (rc != AT_OK) fprintf(stderr, "atcmd: %s\n", at_strerror(rc));

    at_close(fd);
    return rc;
}
