# Testovací nástroje — fáze ověřování

Sada malých programů, kterými se dá odškrtat seznam z `Instructions.txt`:
dostupná modemová rozhraní, `AT+CSQ`, práce s SMS a odeslání e-mailu.

| Soubor | Co dělá |
|---|---|
| `atport.c` / `.h` | společná serial/AT vrstva (termios, čtení do OK/ERROR) |
| `atcmd.c` | pošle jeden AT příkaz, vypíše odpověď; režim `-listen` na URC |
| `smssend.c` | odešle SMS přes `AT+CMGS` |
| `smsrecv.c` | vypíše / poolí / maže přijaté SMS přes `AT+CMGL` |
| `mailsend.c` | SMTP + STARTTLS/implicitní TLS + AUTH + příloha |
| `Makefile` | křížový překlad pro mipsel |
| `build.sh` | jednorázové postavení toolchainu, mbedTLS a všeho ostatního |

Cíl: **ELF32 MIPS little-endian, o32 ABI, staticky**. Zjištěno z hlavičky
`dump/bin/ubia_first` (`EI_DATA=LSB`, `e_machine=8`). Staticky proto, že
zařízení má uClibc 0.9.33.2 a žádnou TLS knihovnu — mbedTLS je sice na
zařízení přítomná, ale zalinkovaná uvnitř `ubia_first`, takže se nedá půjčit.

## Build

Ve WSL, ze složky `test_files`:

```sh
wsl bash build.sh
```

Stáhne toolchain (`gcc-mipsel-linux-gnu`, jednou, přes `sudo`), postaví
mbedTLS 2.28 pro mipsel do `build/mbedtls` a přeloží všechno.

Když nepotřebuješ e-mail, stačí `make at` — `atcmd`, `smssend` a `smsrecv`
nemají žádné závislosti.

mbedTLS je zámerně pinnutá na 2.28 (LTS). Řada 3.6 vyžaduje `psa_crypto_init()`
a jinou konfiguraci, což by sem přidalo jen práci navíc.

## Nasazení

Binárky zkopíruj na SD kartu do `hunter/`. Na VFAT/exFAT nejdou nastavit
práva, ale karta se mountuje s výchozím 0755, takže se spouští přímo.

**Nejdřív pusť `hunter/dev-stop.sh`.** `ubia_first` drží otevřený `ttyUSB0`
i `ttyUSB1` a dokud běží, výsledky měření nebudou znamenat nic.

## Postup testování

### 1. Které rozhraní je AT

`ttyUSB2` je hlavní kandidát — `ubia_first` v sobě má jen `ttyUSB0` a
`ttyUSB1`, takže dvojka je jediná, o kterou se s aplikací nepereš.

```sh
for p in 0 1 2 3; do
    echo "--- /dev/ttyUSB$p ---"
    ./atcmd /dev/ttyUSB$p 115200 AT 2
done
```

Hledáš port, který vrátí `OK`. `/dev/ttyS0` **nezkoušej** — to je linka na
MCU a plácat do ní AT příkazy je špatný nápad.

### 2. Stav modemu

```sh
./atcmd /dev/ttyUSB2 115200 "AT+CPIN?"      # READY = SIM odemčená
./atcmd /dev/ttyUSB2 115200 "AT+CSQ"        # +CSQ: <rssi>,<ber>
./atcmd /dev/ttyUSB2 115200 "AT+CREG?"      # ,1 nebo ,5 = zaregistrováno
./atcmd /dev/ttyUSB2 115200 "AT+COPS?"      # jméno operátora
./atcmd /dev/ttyUSB2 115200 "ATI"           # výrobce a firmware modulu
```

`AT+CSQ` vrací RSSI v rozsahu 0–31 (99 = neznámo), ne procenta. Na
`Signal: xx%` v e-mailu to přepočítej jako `rssi * 100 / 31`; při 99
patří do hlášení `N/A`, přesně jak to chce `Instructions.txt`.

### 3. Odeslání SMS

```sh
./smssend /dev/ttyUSB2 115200 "+420xxxxxxxxx" "Hunter test"
```

Vypíše `CPIN/CSQ/CREG` jako diagnostiku, pak průběh `AT+CMGS`. Když
nedorazí prompt `>`, pošle modemu ESC, aby nezůstal viset a nesežral
další příkaz.

Textový režim + `CSCS="GSM"` znamená ASCII — česká diakritika se rozsype.
Pro `STATUS` a potvrzovací SMS to nevadí; jiná cesta by znamenala UCS2
nebo PDU režim.

### 4. Příjem SMS

```sh
./smsrecv /dev/ttyUSB2 115200 storage        # kde modem SMS ukládá
./smsrecv /dev/ttyUSB2 115200 list all       # co tam je
./smsrecv /dev/ttyUSB2 115200 poll 15        # smyčka, Ctrl-C ukončí
./smsrecv /dev/ttyUSB2 115200 poll 15 -d     # a po vypsání mazat
```

Výstup je strojově čitelný, jeden řádek na zprávu:

```
MSG|<index>|<status>|<odesílatel>|<čas>|<tělo>
```

Tenhle formát jde rovnou parsovat v `hunter.sh`.

`smsrecv` při startu nastaví `AT+CNMI=2,1,0,0,0`. Bez toho může modem
příchozí SMS poslat rovnou na sériovou linku a vůbec ji neuložit — a
`AT+CMGL` pak nenajde nic. Je to nejčastější důvod, proč „SMS nechodí".

Pokud `list` nic nevrací a přitom víš, že zpráva dorazila, zkus:

```sh
./atcmd /dev/ttyUSB2 115200 "AT+CPMS?"                   # aktivní úložiště
./atcmd /dev/ttyUSB2 115200 'AT+CPMS="ME","ME","ME"'     # přepnout na paměť modulu
./atcmd /dev/ttyUSB2 115200 -listen 60                   # chytit +CMTI za běhu
```

### 5. E-mail

Heslo dej do souboru, ne na příkazovou řádku — v `ps` je vidět:

```sh
echo 'app-password-bez-mezer' > /tmp/mnt/sdcard/hunter/smtp.pass
```

```sh
./mailsend -v \
    --host smtp.gmail.com --port 587 \
    --user fotopast@gmail.com --pass-file /tmp/mnt/sdcard/hunter/smtp.pass \
    --to me@example.com \
    --subject "26/08/27 15:30:12" \
    --body "Battery: 87%
Signal: 62%
Space: 12.480GB" \
    --attach /tmp/mnt/sdcard/snaps/260827/153012_000_65535_P.jpg
```

`-v` vypisuje celou SMTP konverzaci (heslo skryté). Port 465 přepne na
implicitní TLS automaticky, `--tls` to umí přebít ručně.

Gmail i Seznam vyžadují **aplikační heslo**, ne heslo do účtu.

### Ověření certifikátu

Bez `--ca` je spojení šifrované, ale neověřuje se identita serveru — je
zranitelné vůči man-in-the-middle. Program to při každém spuštění hlásí.
Pro ostrý provoz stáhni CA svazek na kartu a přidej:

```sh
--ca /tmp/mnt/sdcard/hunter/ca-certificates.crt
```

## Návratové kódy

Všechny nástroje: `0` = OK, `1` = protistrana odmítla, `2` = timeout/síť,
`3` = špatné argumenty nebo port. Díky tomu se dají řetězit v `hunter.sh`
bez parsování výstupu.
