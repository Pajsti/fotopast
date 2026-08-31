#include "atport.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/select.h>
#include <time.h>
#include <errno.h>

/* Ukonceni odpovedi. Zamerne vcetne uvodniho \r\n: holy "OK" se muze
 * trefit doprostred tela SMS pri AT+CMGL. */
static const char *const done_needles[] = {
    "\r\nOK\r\n",
    "\r\nERROR\r\n",
    "\r\n+CME ERROR:",
    "\r\n+CMS ERROR:"
};
#define N_DONE (int)(sizeof(done_needles) / sizeof(done_needles[0]))

static speed_t baud_to_speed(int baud) {
    switch (baud) {
        case 9600:   return B9600;
        case 19200:  return B19200;
        case 38400:  return B38400;
        case 57600:  return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        case 460800: return B460800;
        case 921600: return B921600;
        default:     return B115200;
    }
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int at_open(const char *dev, int baud) {
    int fd = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "atport: open %s: %s\n", dev, strerror(errno));
        return -1;
    }

    struct termios tio;
    if (tcgetattr(fd, &tio) != 0) {
        fprintf(stderr, "atport: tcgetattr %s: %s\n", dev, strerror(errno));
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
        fprintf(stderr, "atport: tcsetattr %s: %s\n", dev, strerror(errno));
        close(fd);
        return -1;
    }

    usleep(100000);
    tcflush(fd, TCIFLUSH);
    return fd;
}

void at_close(int fd) {
    if (fd >= 0) close(fd);
}

void at_drain(int fd) {
    char junk[256];
    for (;;) {
        fd_set rfds;
        struct timeval tv;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = 0;
        tv.tv_usec = 50000;
        if (select(fd + 1, &rfds, NULL, NULL, &tv) <= 0) break;
        if (read(fd, junk, sizeof(junk)) <= 0) break;
    }
}

int at_write(int fd, const char *buf, int len) {
    int off = 0;
    while (off < len) {
        int n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) { usleep(10000); continue; }
            return -1;
        }
        off += n;
    }
    return off;
}

int at_send_line(int fd, const char *line) {
    char tmp[1024];
    int n = snprintf(tmp, sizeof(tmp), "%s\r\n", line);
    if (n < 0 || n >= (int)sizeof(tmp)) return -1;
    return at_write(fd, tmp, n);
}

int at_read_until(int fd, char *out, int outsz, int timeout_ms,
                  const char *const *needles, int nneedles, int *which) {
    int total = 0;
    long deadline = now_ms() + timeout_ms;

    if (outsz < 1) return 0;
    out[0] = '\0';
    if (which) *which = -1;

    for (;;) {
        long remain = deadline - now_ms();
        if (remain <= 0) return 0;

        fd_set rfds;
        struct timeval tv;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = remain / 1000;
        tv.tv_usec = (remain % 1000) * 1000;

        int r = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        if (r == 0) return 0;

        char buf[512];
        int n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            return 0;
        }

        int space = outsz - 1 - total;
        if (space > 0) {
            int copy = (n < space) ? n : space;
            memcpy(out + total, buf, copy);
            total += copy;
            out[total] = '\0';
        }

        int i;
        for (i = 0; i < nneedles; i++) {
            if (strstr(out, needles[i])) {
                if (which) *which = i;
                return 1;
            }
        }
    }
}

int at_cmd(int fd, const char *cmd, char *out, int outsz, int timeout_ms) {
    int which = -1;
    if (at_send_line(fd, cmd) < 0) return AT_TIMEOUT;
    if (!at_read_until(fd, out, outsz, timeout_ms, done_needles, N_DONE, &which))
        return AT_TIMEOUT;
    return (which == 0) ? AT_OK : AT_ERROR;
}

int at_sync(int fd) {
    char resp[256];
    int i;

    at_drain(fd);
    /* Prvni AT po otevreni portu casto propadne - modem si rovna linku. */
    for (i = 0; i < 3; i++) {
        if (at_cmd(fd, "AT", resp, sizeof(resp), 1000) == AT_OK) break;
    }
    if (i == 3) return AT_TIMEOUT;

    if (at_cmd(fd, "ATE0", resp, sizeof(resp), 1000) != AT_OK) return AT_ERROR;
    at_drain(fd);
    return AT_OK;
}

const char *at_strerror(int rc) {
    switch (rc) {
        case AT_OK:      return "OK";
        case AT_ERROR:   return "ERROR (modem prikaz odmitl)";
        case AT_TIMEOUT: return "TIMEOUT (modem neodpovedel)";
        default:         return "?";
    }
}

char *at_trim(char *s) {
    char *end;
    while (*s == '\r' || *s == '\n' || *s == ' ') s++;
    end = s + strlen(s);
    while (end > s && (end[-1] == '\r' || end[-1] == '\n' || end[-1] == ' ')) end--;
    *end = '\0';
    return s;
}
