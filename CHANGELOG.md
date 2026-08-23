# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.8.0] - 2026-08-23

### Added

- Structured serial-device enumeration and display formatting.
- Linux, Windows and macOS metadata collectors with device-only fallback.
- Deterministic device and selector test suites.

### Changed

- `TSerialSelector` now uses one structured device snapshot.
- Serial watcher, setup dialog and examples now use the structured API.

### Removed

- Legacy string enumeration, friendly-name helpers and selector option lists.

[0.8.0]: https://github.com/Syutkin/TLazSerial/releases/tag/0.8.0
