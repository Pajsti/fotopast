/* tlsnet.h - sdilena sitova vrstva pro mailsend a mailrecv.
 *
 * Vytazeno z mailsend.c, aby se DNS resolver, TCP connect a obsluha TLS
 * nemusely duplikovat. Stejny duvod, proc vznikl atport.c/h pro AT
 * nastroje.
 *
 * Drzi JEDNO spojeni v globalnim stavu - oba nastroje jsou jednorazove
 * a vic spojeni najednou nepotrebuji.
 */
#ifndef TLSNET_H
#define TLSNET_H

#include <stddef.h>

/* Jmeno programu do chybovych hlasek ("mailsend: ..."). */
void tlsnet_set_progname(const char *name);

/* Vypise hlasku na stderr a ukonci program s danym kodem. */
void tlsnet_die(int code, const char *msg);

/* Zapne vypis komunikace na stderr (prefixy "C: " a "S: "). */
void tlsnet_set_verbose(int on);

/* Prelozi hostname na IPv4 vlastnim DNS dotazem (obchazi glibc
 * getaddrinfo, ktery ve staticky linkovane binarce potrebuje NSS
 * moduly pres dlopen). Vraci 0 pri uspechu. */
int tlsnet_resolve(const char *host, char *ipbuf, size_t iplen);

/* Naveze TCP spojeni. Pri chybe vola tlsnet_die(). */
void tlsnet_connect(const char *host, const char *port);

/* Povysi existujici TCP spojeni na TLS. cafile smi byt NULL (pak se
 * certifikat serveru neoveruje - varuje se na stderr). */
void tlsnet_handshake(const char *host, const char *cafile);

/* Zapis/cteni. Automaticky posilaji pres TLS, pokud uz probehl
 * handshake, jinak pres holy socket. */
void tlsnet_write(const char *buf, size_t len);
int  tlsnet_read(char *buf, size_t len);

/* 1 kdyz uz bezi TLS. */
int tlsnet_is_tls(void);

void tlsnet_close(void);

#endif
