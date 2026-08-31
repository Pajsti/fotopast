#!/usr/bin/env python3
"""uart_drive.py - programove rizeni serioveho konzole fotopasti z Pi.

Funkcne totez jako `minicom -D /dev/ttyAMA0 -b 115200`, jen driven ze
skriptu misto interaktivniho ncurses UI - potreba, kdyz operator sedi na
druhe strane neinteraktivniho SSH spojeni a nemuze minicom ovladat rucne.

Pouziva jen standardni knihovnu (os, termios, select) - zadne pyserial,
zadna instalace navic.
"""
import os
import sys
import time
import select
import termios

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyAMA0"
BAUD = termios.B115200

fd = os.open(DEV, os.O_RDWR | os.O_NOCTTY)

iflag = 0
oflag = 0
cflag = termios.CS8 | termios.CLOCAL | termios.CREAD
lflag = 0
cc = [0] * len(termios.tcgetattr(fd)[6])
cc[termios.VMIN] = 0
cc[termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, BAUD, BAUD, cc])
termios.tcflush(fd, termios.TCIOFLUSH)


def read_for(seconds):
    end = time.time() + seconds
    buf = b""
    while True:
        remain = end - time.time()
        if remain <= 0:
            break
        r, _, _ = select.select([fd], [], [], remain)
        if r:
            chunk = os.read(fd, 4096)
            if chunk:
                buf += chunk
    return buf.decode(errors="replace")


def send(line):
    os.write(fd, (line + "\r\n").encode())


def cmd(line, wait=2.0, settle=0.1):
    send(line)
    time.sleep(settle)
    out = read_for(wait)
    print(f"$ {line}")
    print(out)
    return out


if __name__ == "__main__":
    # probudit prompt
    send("")
    read_for(0.5)

    for c in sys.argv[2:]:
        cmd(c)
