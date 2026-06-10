# Rut — iOS App for A109 PCMCIA Route Conversion

Convert flight routes and vector map data to AgustaWestland A109 PCMCIA
card format.

## Documentation

- **[CLAUDE.md](CLAUDE.md)** — project guidelines, A109 PCMCIA route format
  (the six files), test infrastructure
- **[Docs/Euronav5/](Docs/Euronav5/)** — Euronav5 vector database format
  (USER*.tbl + index files, appMatrix, .sym), verified byte-for-byte
  against the reference sets in `Euronav5 avkodning/`
- **[PCMCIA avkodning/](PCMCIA%20avkodning/)** — route-format
  reverse-engineering notes and physically tested reference cards

## Implementation status

| Component | Status |
|-----------|--------|
| A109 PCMCIA route export/import (6 files) | ✓ Complete, formats helicopter-tested (T47/T50/T65) |
| Euronav5 format specification | ✓ Complete — see [Docs/Euronav5/VERIFICATION.md](Docs/Euronav5/VERIFICATION.md) |
| Euronav5 export (`Euronav5Encoder.swift` + `Euronav5ExportService.swift`) | ✓ Rewritten against the verified spec; encoder byte-exact vs all 60 reference files (`verify_swift.py`) |
| LFV airspace overlay | ✓ Complete |

## Key implementation files

- [Services/Export/A109ExportService.swift](Services/Export/A109ExportService.swift) — PCMCIA 6-file export
- [Services/Export/Euronav5Encoder.swift](Services/Export/Euronav5Encoder.swift) — Euronav5 binary encoder (byte-exact)
- [Services/Export/Euronav5ExportService.swift](Services/Export/Euronav5ExportService.swift) — vector map export adapter
- [Models/NavigationModel.swift](Models/NavigationModel.swift) — data models
- [Views/MapView.swift](Views/MapView.swift) — map display

## Verifying the Euronav5 spec

```
cd "Euronav5 avkodning/analysis"
python3 verify_all.py
```

Re-derives every documented claim from the reference binaries
(byte-exact round-trips of all 22 USER tables and 48 index files).
