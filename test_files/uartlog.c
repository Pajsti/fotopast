/* uartlog.c - sériový logger + jednoduchý terminál pro ladění fotopasti
 * pres UART na Raspberry Pi. Bezi NA PI (nativne, ne cross-compiled pro
 * mipsel), nahrazuje minicom pro tuhle monitorovaci session - dva
 * procesy nemuzou spolehlive cist ze stejneho seriveho portu soucasne,
 * takze bud tenhle nastroj, nebo minicom, ne oboje najednou.
 *
 * Co dela:
 *   - cte ze serioveho portu, kazdy radek oznaci dvema casovymi razitky
 *     (T+elapsed od startu a HH:MM:SS wall clock) a zapise soucasne na
 *     obrazovku i do logsouboru
 *   - kdyz stdin je terminal (interaktivni beh), preposila zmacknute
 *     klavesy rovnou na seriovou linku - funguje jako minicom
 *   - kdyz stdin NENI terminal (spusteno na pozadi/nohup), jen loguje -
 *     zadne mistni echo, zadne mackani terminalu
 *   - radek bez ukoncujiciho znaku (napr. shell prompt cekajici na
 *     vstup) se po kratke necinnosti (300 ms) vypise i tak, aby nezustal
 *     schovany v bufferu
 *
 * Pouziti:
 *   uartlog [zarizeni] [baud] [logsoubor]
 *   vychozi: /dev/serial0 115200 ~/uart-<datum>-<cas>.log
 *
 * Ukonceni: Ctrl-C (SIGINT) - korektne obnovi puvodni nastaveni
 * terminalu pred ukoncenim.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <sys/select.h>

static int serial_fd = -1;
static struct termios orig_stdin_tio;
static int stdin_is_tty = 0;
static int stdin_tio_saved = 0;
static FILE *logf = NULL;

static speed_t baud_to_speed(int baud)
{
    switch (baud) {
        case 9600:   return B9600;
        case 19200:  return B19200;
        case 38400:  return B38400;
        case 57600:  return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        default:     return B115200;
    }
}

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void restore_stdin(void)
{
    if (stdin_tio_saved) {
        tcsetattr(STDIN_FILENO, TCSANOW, &orig_stdin_tio);
    }
}

static void on_sigint(int sig)
{
    (void)sig;
    restore_stdin();
    if (logf) fflush(logf);
    fprintf(stderr, "\nuartlog: konec\n");
    _exit(0);
}

static int open_serial(const char *dev, int baud)
{
    struct termios tio;
    int fd = open(dev, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        fprintf(stderr, "uartlog: nelze otevrit %s: %s\n", dev, strerror(errno));
        return -1;
    }

    memset(&tio, 0, sizeof(tio));
    if (tcgetattr(fd, &tio) != 0) {
        fprintf(stderr, "uartlog: tcgetattr selhal: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    speed_t spd = baud_to_speed(baud);
    cfsetispeed(&tio, spd);
    cfsetospeed(&tio, spd);

    tio.c_cflag |= (CLOCAL | CREAD);
    tio.c_cflag &= ~(PARENB | CSTOPB | CSIZE | CRTSCTS);
    tio.c_cflag |= CS8;
    tio.c_lflag &= ~(ICANON | ECHO | ECHOE | ECHONL | ISIG);
    tio.c_iflag &= ~(IXON | IXOFF | IXANY | ICRNL | INLCR | IGNCR | ISTRIP | BRKINT);
    tio.c_oflag &= ~OPOST;
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 0;

    tcflush(fd, TCIOFLUSH);
    if (tcsetattr(fd, TCSANOW, &tio) != 0) {
        fprintf(stderr, "uartlog: tcsetattr selhal: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static void set_stdin_raw(void)
{
    struct termios tio;

    stdin_is_tty = isatty(STDIN_FILENO);
    if (!stdin_is_tty) return;

    if (tcgetattr(STDIN_FILENO, &orig_stdin_tio) != 0) return;
    stdin_tio_saved = 1;

    tio = orig_stdin_tio;
    tio.c_lflag &= ~(ICANON | ECHO | ISIG);
    tio.c_iflag &= ~(IXON | IXOFF | ICRNL);
    tio.c_cc[VMIN] = 1;
    tio.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &tio);
}

/* Vypise (na stdout i do logu) jeden "radek" s casovym razitkem.
 * start_ms = cas spusteni programu, pro T+elapsed sloupec. */
static void emit_line(const char *buf, size_t len, long start_ms)
{
    struct timespec ts;
    struct tm tmv;
    time_t sec;
    long elapsed;
    char stamp[64];

    clock_gettime(CLOCK_REALTIME, &ts);
    sec = ts.tv_sec;
    localtime_r(&sec, &tmv);
    elapsed = now_ms() - start_ms;

    snprintf(stamp, sizeof(stamp), "[T+%6ld.%03lds %02d:%02d:%02d]",
             elapsed / 1000, elapsed % 1000,
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

    printf("%s ", stamp);
    fwrite(buf, 1, len, stdout);
    if (len == 0 || buf[len - 1] != '\n') putchar('\n');
    fflush(stdout);

    if (logf) {
        fprintf(logf, "%s ", stamp);
        fwrite(buf, 1, len, logf);
        if (len == 0 || buf[len - 1] != '\n') fputc('\n', logf);
        fflush(logf);
    }
}

int main(int argc, char **argv)
{
    const char *dev = (argc > 1) ? argv[1] : "/dev/serial0";
    int baud = (argc > 2) ? atoi(argv[2]) : 115200;
    char default_logname[128];
    const char *logname;
    long start_ms;
    char linebuf[4096];
    size_t linelen = 0;
    long last_byte_ms = 0;
    int have_partial = 0;

    if (argc > 3) {
        logname = argv[3];
    } else {
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        snprintf(default_logname, sizeof(default_logname),
                 "%s/uart-%04d%02d%02d-%02d%02d%02d.log",
                 getenv("HOME") ? getenv("HOME") : ".",
                 tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                 tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
        logname = default_logname;
    }

    serial_fd = open_serial(dev, baud);
    if (serial_fd < 0) return 1;

    logf = fopen(logname, "w");
    if (!logf) {
        fprintf(stderr, "uartlog: nelze zapisovat do %s: %s\n",
                logname, strerror(errno));
        close(serial_fd);
        return 1;
    }

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);
    set_stdin_raw();

    fprintf(stderr,
        "uartlog: %s @ %d, log -> %s\n"
        "uartlog: %s\n"
        "uartlog: Ctrl-C ukonci\n\n",
        dev, baud, logname,
        stdin_is_tty ? "interaktivni rezim (klavesy se posilaji na UART)"
                     : "jen logovani (stdin neni terminal)");

    start_ms = now_ms();

    for (;;) {
        fd_set rfds;
        struct timeval tv;
        int maxfd = serial_fd;

        FD_ZERO(&rfds);
        FD_SET(serial_fd, &rfds);
        if (stdin_is_tty) {
            FD_SET(STDIN_FILENO, &rfds);
            if (STDIN_FILENO > maxfd) maxfd = STDIN_FILENO;
        }

        tv.tv_sec = 0;
        tv.tv_usec = 300000;   /* 300 ms - flush castecneho radku po tichu */

        int r = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (r == 0) {
            /* timeout - kdyz mame rozdelany radek a dlouho nic
             * neprislo (typicky shell prompt bez \n), vypis ho tak,
             * jak je */
            if (have_partial) {
                emit_line(linebuf, linelen, start_ms);
                linelen = 0;
                have_partial = 0;
            }
            continue;
        }

        if (FD_ISSET(serial_fd, &rfds)) {
            unsigned char chunk[512];
            ssize_t n = read(serial_fd, chunk, sizeof(chunk));
            if (n > 0) {
                ssize_t i;
                for (i = 0; i < n; i++) {
                    if (chunk[i] == '\n') {
                        emit_line(linebuf, linelen, start_ms);
                        linelen = 0;
                        have_partial = 0;
                    } else if (chunk[i] == '\r') {
                        /* ignorovat - \n uzavre radek za chvíli */
                        continue;
                    } else {
                        if (linelen < sizeof(linebuf) - 1) {
                            linebuf[linelen++] = (char)chunk[i];
                        }
                        have_partial = 1;
                    }
                }
                last_byte_ms = now_ms();
                (void)last_byte_ms;
            } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                fprintf(stderr, "uartlog: chyba cteni z UART: %s\n",
                        strerror(errno));
                break;
            }
        }

        if (stdin_is_tty && FD_ISSET(STDIN_FILENO, &rfds)) {
            unsigned char kb[64];
            ssize_t n = read(STDIN_FILENO, kb, sizeof(kb));
            if (n > 0) {
                write(serial_fd, kb, (size_t)n);
            } else if (n == 0) {
                /* stdin zavreny (napr. presmerovani skoncilo) */
                stdin_is_tty = 0;
            }
        }
    }

    if (have_partial) emit_line(linebuf, linelen, start_ms);
    restore_stdin();
    if (logf) fclose(logf);
    close(serial_fd);
    return 0;
}
