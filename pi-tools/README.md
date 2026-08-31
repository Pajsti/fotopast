# pi-tools

Nástroje, které běží **na Raspberry Pi**, ne na fotopasti. Nepatří sem
nic pro mipsel/SD kartu — to je v [../hunter/](../hunter/) a
[../test_files/](../test_files/).

## uartlog

Sériový logger + jednoduchý terminál, náhrada za minicom pro monitorovací
session. Zdroj: [../test_files/uartlog.c](../test_files/uartlog.c) —
kompiluje se **nativně** na Pi (`gcc -O2 -o uartlog uartlog.c`), žádný
cross-compiler ani závislosti navíc.

**Proč ne minicom souběžně:** dva procesy nemůžou spolehlivě číst ze
stejného sériového portu zároveň — čtení by se mezi nimi náhodně dělilo.
`uartlog` proto minicom pro dobu monitorování **nahrazuje**, nejede vedle
něj.

### Použití

```sh
./uartlog                                  # /dev/serial0, 115200, log do ~/uart-<datum>.log
./uartlog /dev/serial0 115200 muj-log.log  # explicitní cesty
```

- **Interaktivní běh** (spuštěno v terminálu): funguje jako minicom —
  co napíšeš, jde na UART. Navíc každý řádek dostane dvojité razítko:
  `[T+12.345s 22:42:07]` — vteřiny od startu logu (dobré pro měření
  intervalů) a čas na hodinách (dobré pro porovnání s `hunter/log.txt`
  na kartě, který používá stejný formát).
- **Běh na pozadí** (`nohup ./uartlog > /dev/null 2>&1 &`, nebo přes
  `ssh ... 'command' &` bez terminálu): detekuje, že stdin není
  terminál, jen loguje — neposílá nic na UART, nešahá na nastavení
  terminálu.
- Řádek bez ukončení (typicky shell prompt `#` čekající na vstup) se
  vypíše i tak, po 300 ms ticha — nezůstane skrytý v bufferu.
- `Ctrl-C` korektně ukončí a obnoví terminál.

Ověřeno end-to-end přes skutečný pseudo-terminálový pár (celé řádky,
víc řádků za sebou, nedokončený řádek s prodlevou, obnovení po prodlevě) —
viz historie session.

## Nahrávání textových souborů přes UART (heredoc)

Malé textové soubory (shellové skripty) jde nahrát na kartu i bez
fyzického vytažení — poslat `cat > cesta << 'TOKEN' ... TOKEN` přímo do
přihlášeného shellu na `/dev/ttyAMA0` (viz `uart_drive.py`, funkce
`send`/`cmd`). Dvě věci, které to umí rozbít:

1. **Doslovný TAB znak (0x09) v obsahu se ztrácí.** BusyBox ash bere TAB
   i uprostřed heredoc těla jako doplňování příkazu (tab-completion) a
   znak spolkne, aniž by cokoli vypsal nebo vrátil chybu — soubor pak
   projde `sh -n` (je to porád syntakticky platné), ale chová se jinak,
   než má. Objeveno 2026-08-31 na `IFS=' <TAB>'` v `status.sh` (1 B
   rozdíl) a dvou tabech v `common.sh` (2 B rozdíl) — vždy **stejný**
   výsledek bez ohledu na to, jak se přenos dávkuje (zkoušeno: jeden
   velký `write()`, 200B bloky, 16B bloky s 20ms pauzou — identický
   špatný MD5 pokaždé, takže to není šum na lince, je to deterministické
   chování shellu). **Řešení:** v souboru, který se takhle nahrává,
   nepoužívat doslovný tab - napsat `"$(printf '\t')"` a nechat shell
   tab vytvořit až za běhu.
2. **Živé probuzení zařízení uprostřed přenosu.** `ubia_first` může
   nastartovat kdykoli (PIR) a jeho boot log zaplaví konzoli přesně v
   okamžiku přenosu - výsledek bývá buď úplně ztracený příkaz (parsuje
   se jako login prompt), nebo binární smetí. Po každém nahrání vždy
   ověřit `md5sum` nahraného souboru proti lokálnímu - `sh -n` na to
   nestačí (poškozený soubor může být pořád syntakticky platný).
