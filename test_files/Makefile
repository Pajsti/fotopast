# Makefile - krizovy preklad testovacich nastroju pro fotopast.
#
# Cil: ELF32 MIPS little-endian, o32 ABI, staticky.
# Staticky zamerne - zarizeni ma uClibc 0.9.33.2 a nema zadnou TLS
# knihovnu, takze si vsechno neseme s sebou a nic na nem neresime.
#
# Pouziti (ve WSL):
#   make            vsechno vcetne mailsend (potrebuje mbedTLS, viz build.sh)
#   make at         jen atcmd/smssend/smsrecv (zadne zavislosti)
#   make clean

CROSS   ?= mipsel-linux-gnu-
CC       = $(CROSS)gcc
STRIP    = $(CROSS)strip

# Kam build.sh slozi mbedTLS pro mipsel.
MBEDTLS ?= $(CURDIR)/build/mbedtls

# -mfp32: sladi FP ABI presne s ubia_first ("Hard float, double precision").
# Vychozi FPXX by na kernelu 3.10 nemusel byt spravne pochopen.
CFLAGS  = -O2 -Wall -Wextra -std=gnu99 -static -mfp32
LDFLAGS = -static

AT_TOOLS   = atcmd smssend smsrecv
MAIL_TOOLS = mailsend mailrecv
UTIL_TOOLS = snapready logscan
ALL_TOOLS  = $(AT_TOOLS) $(MAIL_TOOLS) $(UTIL_TOOLS)

HOSTCC  ?= cc

.PHONY: all at mail util clean strip hosttest

all: $(ALL_TOOLS)

at: $(AT_TOOLS)

mail: $(MAIL_TOOLS)

util: $(UTIL_TOOLS)

atport.o: atport.c atport.h
	$(CC) $(CFLAGS) -c -o $@ $<

atcmd.o: atcmd.c atport.h
	$(CC) $(CFLAGS) -c -o $@ $<

smssend.o: smssend.c atport.h
	$(CC) $(CFLAGS) -c -o $@ $<

smsrecv.o: smsrecv.c atport.h
	$(CC) $(CFLAGS) -c -o $@ $<

atcmd: atcmd.o atport.o
	$(CC) $(LDFLAGS) -o $@ $^

smssend: smssend.o atport.o
	$(CC) $(LDFLAGS) -o $@ $^

smsrecv: smsrecv.o atport.o
	$(CC) $(LDFLAGS) -o $@ $^

tlsnet.o: tlsnet.c tlsnet.h
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -c -o $@ $<

mimemsg.o: mimemsg.c mimemsg.h
	$(CC) $(CFLAGS) -c -o $@ $<

mailsend: mailsend.c tlsnet.o mimemsg.o
	@test -d "$(MBEDTLS)/include" || \
	  { echo "chybi mbedTLS v $(MBEDTLS) - spust nejdriv ./build.sh"; exit 1; }
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -o $@ mailsend.c tlsnet.o mimemsg.o \
	  -L"$(MBEDTLS)/lib" -lmbedtls -lmbedx509 -lmbedcrypto $(LDFLAGS)

mailrecv: mailrecv.c tlsnet.o mimemsg.o
	@test -d "$(MBEDTLS)/include" || \
	  { echo "chybi mbedTLS v $(MBEDTLS) - spust nejdriv ./build.sh"; exit 1; }
	$(CC) $(CFLAGS) -I"$(MBEDTLS)/include" -o $@ mailrecv.c tlsnet.o mimemsg.o \
	  -L"$(MBEDTLS)/lib" -lmbedtls -lmbedx509 -lmbedcrypto $(LDFLAGS)

snapready: snapready.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

logscan: logscan.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

strip: $(ALL_TOOLS)
	$(STRIP) $(ALL_TOOLS)

# Nativni test generatoru zpravy. mimemsg.c zamerne nezavisi na tlsnet
# ani na mbedTLS, takze se da prelozit pro hostitele a otestovat.
hosttest: mimemsg.c mimemsg.h mimemsg_test.c
	$(HOSTCC) -O2 -Wall -Wextra -std=gnu99 -o mimemsg_test \
	  mimemsg_test.c mimemsg.c
	./mimemsg_test

clean:
	rm -f *.o $(ALL_TOOLS) mimemsg_test
