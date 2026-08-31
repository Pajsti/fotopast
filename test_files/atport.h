/* atport.h - spolecna serial/AT vrstva pro atcmd, smssend a smsrecv.
 *
 * Duvod, proc to je zvlast: vsechny tri nastroje potrebuji tentyz
 * termios setup a tentyz "cti, dokud nedorazi OK nebo ERROR" cyklus.
 * Trikrat zkopirovany = trikrat opravovany.
 */
#ifndef ATPORT_H
#define ATPORT_H

#define AT_OK       0   /* dorazilo \r\nOK\r\n                  */
#define AT_ERROR    1   /* ERROR / +CME ERROR / +CMS ERROR      */
#define AT_TIMEOUT  2   /* nedorazilo nic ukoncujiciho          */

/* Otevre a nastavi port do raw rezimu. Vraci fd, nebo -1. */
int at_open(const char *dev, int baud);
void at_close(int fd);

/* Zahodi vse, co je zrovna ve vstupnim bufferu. */
void at_drain(int fd);

int at_write(int fd, const char *buf, int len);
int at_send_line(int fd, const char *line);   /* prida \r\n */

/* Cte do 'out', dokud nenarazi na nektery z 'needles' nebo nevyprsi
 * timeout. Do *which (smi byt NULL) ulozi index nalezeneho needle.
 * Vraci 1 pri nalezu, 0 pri timeoutu. */
int at_read_until(int fd, char *out, int outsz, int timeout_ms,
                  const char *const *needles, int nneedles, int *which);

/* Posle prikaz a ceka na OK/ERROR. Vraci AT_OK / AT_ERROR / AT_TIMEOUT. */
int at_cmd(int fd, const char *cmd, char *out, int outsz, int timeout_ms);

/* ATE0 + AT: vypne echo a overi, ze modem vubec odpovida.
 * Bez tohohle ti modem echuje prikazy zpatky do parsovani. */
int at_sync(int fd);

const char *at_strerror(int rc);

/* Orizne CR/LF z obou konci retezce (in-place). */
char *at_trim(char *s);

#endif
