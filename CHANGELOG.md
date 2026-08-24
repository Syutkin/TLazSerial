# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.8.0] - 2026-08-23

### Added

- Structured serial-device enumeration and display formatting.
- Linux, Windows and macOS metadata collectors with device-only fallback.
- Deterministic device and selector test suites.
- Optional manual device entry in `TSerialSelector` through
  `AllowCustomDevice`.

### Changed

- `TSerialSelector` now uses one structured device snapshot.
- Serial-device refresh now runs outside the GUI thread on every platform.
- `TSerialSelector` shares its snapshot with its watcher instead of enumerating
  devices twice.
- Serial watcher, setup dialog and examples now use the structured API.
- `TLazSerial` transport operations now have an explicit main-thread-only
  contract, and its owned `SynSer` object can no longer be replaced.
- Linux serial-device watching now prefers dynamically loaded `libudev`, with
  automatic `inotify` and polling fallbacks.

### Fixed

- Closing an active `TLazSerial` now stops its reader without processing
  unrelated GUI messages or delivering late receive callbacks.
- Serial status callbacks raised by the reader are now delivered on the main
  thread, making them safe for LCL event handlers.
- Repeated refresh requests no longer start overlapping device enumerations.
- Reader callbacks can now close or destroy `TLazSerial` without deadlocking,
  and callback exceptions no longer stop the reader thread.
- Destruction now stops the reader before detaching the Synapse status hook.
- Linux and macOS metadata commands now have bounded execution time and are
  cancelled when their selector or watcher is destroyed.
- Windows device enumeration now uses SetupAPI instead of WMI.

### Removed

- Legacy string enumeration, friendly-name helpers and selector option lists.

[0.8.0]: https://github.com/Syutkin/TLazSerial/releases/tag/0.8.0
