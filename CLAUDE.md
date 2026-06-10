# Rut – iOS App (A109 PCMCIA)

iOS-app som konverterar rutt-format för helikoptrar.
Kritisk funktion: export/import av 6 filer till PCMCIA-kort för AgustaWestland A109.

## Projektstruktur (Xcode-targets)

- **`Services/`** – `PBXFileSystemSynchronizedRootGroup` → nya filer auto-kompileras för båda targets
- **`Models/`, `Views/`** – INTE auto-länkade → nya filer kräver manuell registrering i `.xcodeproj`
- Lösning: lägg alltid nya filer i `Services/` om möjligt

## Viktiga filer

- `Services/Export/A109ExportService.swift` – huvud-export, bygger alla 6 filer
- `Services/Import/A109ImportService.swift` – import + 6-bit decode
- `Models/NavigationModel.swift` – datamodeller
- `Views/MapView.swift` – karta + gesture-arkitektur
- `Services/AirspaceService.swift` – LFV luftrumszoner via WFS API
- `PCMCIA avkodning/` – all reverse-engineering dokumentation
- `PCMCIA avkodning/verify_card.py` – verifiera kort mot kända referenskort

## Euronav5 Format Documentation

**Verifierad, bit-för-bit specifikation i [Docs/Euronav5/](Docs/Euronav5/):**

- **[Docs/Euronav5/README.md](Docs/Euronav5/README.md)** – Överblick + verifieringsstatus
- **[Docs/Euronav5/TBL_FORMAT.md](Docs/Euronav5/TBL_FORMAT.md)** – USER*.tbl: 3480-byte header + 4104-byte pages (16×256-byte records), recordlayout
- **[Docs/Euronav5/INDEX_FORMAT.md](Docs/Euronav5/INDEX_FORMAT.md)** – ID/LN/OI-index: B-träd, exakt byggalgoritm
- **[Docs/Euronav5/EXPORT_GUIDE.md](Docs/Euronav5/EXPORT_GUIDE.md)** – iOS-exportrecept + vilka värden appen måste tillhandahålla
- **[Docs/Euronav5/APPMATRIX_SYM.md](Docs/Euronav5/APPMATRIX_SYM.md)** – appMatrix.json + .sym
- **[Docs/Euronav5/VERIFICATION.md](Docs/Euronav5/VERIFICATION.md)** – Bevismetod + öppna frågor

Referensimplementation (byte-exakt mot alla referensfiler):
`Euronav5 avkodning/analysis/euronav5.py`. Kör `python3 verify_all.py` där
för att ompröva alla påståenden mot referensdatan.

**Känd implementation-status (June 10, 2026):**
- Formatspec: ✓ Komplett — 22/22 .tbl och 48/48 .idx återskapas byte-exakt;
  alla 10 set regenereras byte-exakt från enbart figur-input
- iOS-export: ✓ Omskriven — `Euronav5Encoder.swift` (byte-exakt Swift-port,
  verifierad mot alla 60 referensfiler via `verify_swift.py`) +
  `Euronav5ExportService.swift` (tunn adapter VectorShape → figurer)
- OBS: alla tidigare "byte_08/byte_12/byte_68/zone block"-formler och
  "DMG"-analyser var feltolkningar av page-strukturen — använd dem inte

## Testinfrastruktur

- `PCMCIA avkodning/dap/Testkort/` – kort skapade av **äldre DAP-planeringsdator**, **fysiskt testade i helikopter**
  - Innehåller `PilotLog.txt`, `PilotReadLog.txt`
  - T47/T50/T65: bekräftad inläsning av WPT-WPT-rutter (inga logistiska airports)
  - T65: bekräftar att år 2026 fungerar; Route 6 har 40 fix-punkter (max)
- `PCMCIA avkodning/skyflight-testkort/` – kort skapade av **ny skyflight-planeringsstation** (ej fysiskt testade i helikopter)
- `PCMCIA avkodning/rut-kort/` – kort skapade av **iOS-appen** (ej fysiskt testade)
- `PCMCIA avkodning/*-encoding.txt` – detaljerad format-dokumentation per fil
- `PCMCIA avkodning/*-testinstruktioner.txt` – testinstruktioner

**OBS:** `PilotReadLog.txt` och `TacticalReadLog.txt` skrivs av **planeringsdatorn** när den läser kortet — INTE av helikoptern. De finns på kortet innan helikoptertestning.

## A109 PCMCIA – Filformat (6 filer)

### 6-bit teckenkodning
Tecken mappas: `-`=11, `0-9`=14-23, `A-Z`=30-55, padding=0.
Packas 5 tecken per 4 bytes (30 bitar), med 2 padding-bitar i slutet av varje 4-byte block.
Waypoint-ID: dessutom shift right 1, MSB satt till 1.

### PILOTE.HD (44 bytes)
- 12 bytes ASCII datum (DTDdDDMMMYYYY + padding)
- 8× 32-bit big-endian: år, månad, dag, storlek airport, navaid, waypoint, route, carac

### AIRPORT.P01 / NAVAID.P01 (4020 bytes, max 100 poster, 40 bytes/post)
Header (16 bytes): 13 bytes presence-bits, byte13=(129+count, eller 128 vid 100), byte14=count×2, byte15=0

**Airport record:** ID(4B 6bit), namn(8B 6bit), rawUnknown(4B), usage(4B byte17: 6/14/30), lat(4B float BE), lon(4B float BE), runway(4B), magvar(4B float BE), elev(4B float BE)

**Navaid:** byte0=0xE0 alltid, byte2=usage (0x30/0x70/0xF0), ID bytes4-7, namn bytes8-15, freq bytes20-23, lon bytes24-27, lat bytes28-31, magvar bytes32-35, elev bytes36-39

### WAYPOINT.P01 (2820 bytes, max 100 poster, 28 bytes/post)
Header: samma struktur (16 bytes)
Record: lat(4B), lon(4B), namn(12B 6bit 3×4B), byte21=rutt-membership (0=ingen, 8=rutt1, 16=rutt2...), ID(4B special 6bit bytes24-27)

### ROUTE.P01 (50020 bytes, max 100 rutter, 500 bytes/rutt)
Header: 16 bytes
Rutt-header (20 bytes): namn(8B 6bit), start-apt-id(3B)+dbIdx(1B)+dest-apt-id(3B)+dbIdx(1B), statusByte(1B byte16), ptCount(bytes17-18)

**statusByte (byte16):** `(startTypeBits << 5) | (destTypeBits << 2)`

| Bits | Värde | Betydelse |
|------|-------|-----------|
| `010` | 2 | Ingen logistisk airport |
| `100` | 4 | System/Jeppesen airport (dbIdx=0) |
| `101` | 5 | User airport från AIRPORT.P01 (dbIdx>0) |

Vanliga kombinationer:
- `0x48` = ingen logistisk airport på varken start eller dest (också tom ruttslot när pts=0)
- `0x90` = system airport på start OCH dest
- `0x94` = system start, user dest
- `0xb4` = user start, user dest
- `0xb0` = user start, system dest

**OBS:** Äldre DAP-kort har type `101` med dbIdx=0 (avviker från nuvarande standard). Skyflight-stationen och iOS-appen använder `100` för system airports — det är korrekt.

**ptCount:** byte17 = count//8, byte18 = (count%8)*32. Decode: (byte17×8)+(byte18>>5)
**dbIdx:** (index_i_fil + 1) × 2. dbIdx=0 → helikopterns interna Jeppesen-databas.
Max 40 fix-punkter per rutt.

### CARACTER.P01 (116 bytes)
- bytes0-3: 0x55 0xAA 0x55 0xAA (magic)
- bytes4-11: datum i 6-bit "DTDdDDMMMYYYY" (byte7 LSB2 = 0b10 sätts av iOS men ej DAP, båda funkar)
- bytes12-13: binärt datum (dag 5bit | månad-1 4bit | 00 | år-2000 5bit)
- byte14: 0x40, bytes16/28/40/52: 0x80
- 4 checksums (wpt@68, airport@80, navaid@92, route@104): summa signed 16-bit par som signed 32-bit BE

## MapView – Gesture-arkitektur

Enda `LongPressGesture` sitter på `Map`-vyn med `.simultaneousGesture`.
Annotation-vyer har bara `.onTapGesture`.
`findDragTarget(at:proxy:)` gör hit-test (30pt radius) vid long press.

Tidigare försök med `LongPressGesture` per marker blockerade MapKits pan-gesture.
Ingen ren SwiftUI-lösning — enda fungerande är gesture på map-nivå.

## FAT-korruption vid kortborttagning

Om kortet dras ur iPaden innan iOS flushät skrivbuffertarna kan FAT1 bli inkomplett medan FAT2 är intakt. macOS reparerar FAT1 transparent när kortet mountas (via `fsck_msdos`), men helikopterns PCMCIA-läsare läser FAT1 strikt och kan inte följa klusterkedjan för `ROUTE.P01` → visar kortet men inga rutter.

**Fix i appen:** `performA109DirectExport` kallar `Darwin.fsync()` på varje skriven fil + visar en modal dialogruta ("Export Complete / Remove the PCMCIA card.") istället för en toast. Användaren ska INTE ta ur kortet förrän dialogen visas.

## Känd implementation-status

### A109 PCMCIA (helikopterrutting – 6 filer)
- **Export:** Implementerad i `A109ExportService.swift` ✓ Komplett
- **Import:** Implementerad i `A109ImportService.swift` ✓ Komplett. ZIP ej implementerat.

### Euronav5 Vektoröverlag (kartdata)
- **Formatspec:** ✓ Komplett och bevisad byte-exakt — se [Docs/Euronav5/](Docs/Euronav5/)
- **Export:** ✓ `Euronav5Encoder.swift` + `Euronav5ExportService.swift`
  (omskrivna June 10, 2026; encodern verifierad byte-exakt mot alla 60
  referensfiler med `Euronav5 avkodning/analysis/verify_swift.py`)

### Annat
- **LFV luftrum:** Laddas vid app-start, visas som icke-klickbara polygoner

## felsökning
När man försöker hitta ett fel i koden måste hela felkedjan kontrolleras och reproduceras och förklaras innan den åtgärdas. Det räcker inte med att bara hitta felet.