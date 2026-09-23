# Fotopast — Hunter

Vlastní služba pro 4G fotopast (Ingenic T31, MIPS/uClibc/busybox),
běžící z SD karty vedle nezměněné vendor aplikace `ubia_first`. Řeší
tři věci, které vendor firmware neumí:

- **posílá nové fotky e-mailem** (SMTP nebo přímo IMAP APPEND)
- **přijímá vzdálené příkazy** přes e-mail (stav, vyžádání fotek,
  správa oprávněných uživatelů, mazání starých fotek...)
- **spravuje místo na kartě**, aby fronta neposlaných fotek ani
  historie odeslaných nerostly bez konce

Zařízení nemá zálohovanou reálnou hodinu ani stálý provoz — probouzí
se jen při pohybu a Hunter se spouští jako jedna úloha při každém
takovém probuzení.

## Kam dál

| Chci... | Dokument |
|---|---|
| naučit se to běžně používat (příkazy, co dělají) | [guide.md](guide.md) |
| architekturu, kompletní referenci configu/příkazů/souborů | [docs/REFERENCE.md](docs/REFERENCE.md) |
| nasadit to na kartu od nuly | [hunter/README.md](hunter/README.md) |
| projít nasazení/test krok za krokem | [CHECKLIST.md](CHECKLIST.md) |

## Struktura repozitáře

```
hunter/          zdrojáky služby (shell) + zkompilované binárky
test_files/       zdrojáky C nástrojů (mailsend, mailrecv, atcmd, ...)
                 a jejich testy - kompilují se pro MIPS na Raspberry Pi,
                 nikdy primo na zarizeni
tests/            shellové testy Huntera (dash)
sdcard-root/      ubia_test - spouštěcí hák, patří do KOŘENE SD karty
pi-tools/         pomocné nástroje pro Raspberry Pi (cross-compile, UART)
docs/superpowers/ historický záznam návrhových rozhodnutí (spec/plan páry)
```

Hunter se nikdy nedotýká vendor souborů (`ubia_record.db`, `logfile.txt`,
`HDPIC/`, `video/`) ani binárky `ubia_first` samotné — jen ji na chvíli
zmrazí, přečte `snaps/` a jinak žije vedle ní.
