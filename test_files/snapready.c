/* snapready.c - overi, ze je JPEG na SD karte kompletni, ne rozepsany.
 *
 * Duvod: puvodni aplikace snimek na kartu KOPIRUJE ("cp /tmp/snap_hd.jpg
 * %s" v ubia_first), ne atomicky prejmenovava. Chvili tedy na karte lezi
 * castecne napsany soubor. Busybox na zarizeni nema od/hexdump/tail, takze
 * kontrolu koncove znacky JPEG (FF D9) nejde spolehlive udelat v shellu -
 * odtud tenhle maly nastroj.
 *
 * Test: velikost musi byt stabilni pres ~700 ms (jeste se nezvetsuje) A
 * posledni dva bajty souboru musi byt FF D9 (JPEG EOI marker).
 *
 * Pouziti: snapready <soubor>
 * Navratovy kod:
 *   0 = pripraveno k odeslani
 *   1 = jeste se pise / neni EOI (zkusit priste)
 *   2 = chyba (soubor neexistuje, prilis maly, nejde precist)
 */
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

int main(int argc, char **argv)
{
    struct stat st1, st2;
    int fd;
    unsigned char tail[2];

    if (argc != 2) {
        fprintf(stderr, "pouziti: %s <soubor>\n", argv[0]);
        return 2;
    }

    if (stat(argv[1], &st1) != 0) return 2;
    if (st1.st_size < 4) return 1;   /* prazdny nebo prave zacaty zapis */

    usleep(700000);

    if (stat(argv[1], &st2) != 0) return 2;
    if (st1.st_size != st2.st_size) return 1;   /* jeste roste */

    fd = open(argv[1], O_RDONLY);
    if (fd < 0) return 2;

    if (lseek(fd, -2, SEEK_END) < 0) { close(fd); return 2; }
    if (read(fd, tail, 2) != 2) { close(fd); return 2; }
    close(fd);

    return (tail[0] == 0xFF && tail[1] == 0xD9) ? 0 : 1;
}
