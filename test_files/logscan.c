/* logscan.c - najde POSLEDNI vyskyt "klic=" v souboru a vypise nasledujici
 * cislo. Bez awk/sed/grep -o (busybox na zarizeni je nema) se pole z
 * logu jinak spolehlive nevytahne.
 *
 * Pouziti: logscan <soubor> <klic> [max_bajtu_od_konce=262144]
 * Priklad:  logscan /tmp/mnt/sdcard/logfile.txt "_battery="
 *
 * Cte jen posledních max_bajtu_od_konce bajtu souboru (vychozi 256 kB) -
 * zajima nas nejnovejsi hodnota, ne cela historie, a logfile.txt muze byt
 * i nekolik MB.
 *
 * Navratovy kod: 0 = nalezeno (cislo na stdout, bez odradkovani),
 *                1 = klic v prectene casti souboru neni,
 *                2 = chyba (soubor nejde otevrit).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

#define DEFAULT_CHUNK (256 * 1024)

int main(int argc, char **argv)
{
    const char *path, *key;
    long chunk;
    struct stat st;
    off_t start;
    size_t buflen;
    unsigned char *buf;
    int fd;
    ssize_t n;
    char *p, *last, *hit;
    size_t keylen;

    if (argc < 3) {
        fprintf(stderr, "pouziti: %s <soubor> <klic> [max_bajtu_od_konce]\n",
                argv[0]);
        return 2;
    }
    path = argv[1];
    key = argv[2];
    chunk = (argc > 3) ? atol(argv[3]) : DEFAULT_CHUNK;
    if (chunk <= 0) chunk = DEFAULT_CHUNK;
    keylen = strlen(key);
    if (keylen == 0) return 2;

    if (stat(path, &st) != 0) return 2;

    start = (st.st_size > chunk) ? st.st_size - chunk : 0;
    buflen = (size_t)(st.st_size - start);
    if (buflen == 0) return 1;

    buf = malloc(buflen + 1);
    if (!buf) return 2;

    fd = open(path, O_RDONLY);
    if (fd < 0) { free(buf); return 2; }
    if (lseek(fd, start, SEEK_SET) < 0) { close(fd); free(buf); return 2; }

    n = 0;
    while ((size_t)n < buflen) {
        ssize_t r = read(fd, buf + n, buflen - (size_t)n);
        if (r <= 0) break;
        n += r;
    }
    close(fd);
    buf[n] = '\0';

    /* posledni vyskyt klice v precteni casti - hledame odzadu rucne,
     * strstr jde jen dopredu, tak si najdeme vsechny a pamatujeme si
     * posledni. */
    last = NULL;
    p = (char *)buf;
    while ((hit = strstr(p, key)) != NULL) {
        last = hit;
        p = hit + 1;
    }

    if (!last) { free(buf); return 1; }

    p = last + keylen;
    if (!(*p >= '0' && *p <= '9')) { free(buf); return 1; }

    while (*p >= '0' && *p <= '9') {
        putchar(*p);
        p++;
    }
    free(buf);
    return 0;
}
