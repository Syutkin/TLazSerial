# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.8.0] - 2026-08-23

### Added

- Structured serial-device enumeration and display formatting.
- Linux, Windows and macOS metadata collectors with device-only fallback.
- Deterministic device and selector test suites.
- Manual GitHub Actions test workflow with cached Lazarus toolchains for Linux,
  Windows and macOS.
- Optional manual device entry in `TSerialSelector` through
  `AllowCustomDevice`.
- Internal serial transport abstraction for deterministic testing.

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
- Windows serial-device watching now filters COM-port notifications, uses a
  short debounce with bounded settling retries, and falls back to polling.
- macOS serial-device watching now uses IOKit notifications for
  `IOSerialBSDClient`, with automatic polling fallback.
- Serial-port setup now separates form state from applying settings.

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
- Failed open or configuration no longer leaves a partially active port.
- Live `FlowControl` changes now apply the newly selected value.
- Cancelling a device refresh before its worker starts no longer hangs.
- Enumeration failures preserve the current device list and selection.
- Exhausted watcher fallbacks now report failure without leaking an exception
  into the LCL event loop.

### Removed

- Legacy string enumeration, friendly-name helpers and selector option lists.

[0.8.0]: https://github.com/Syutkin/TLazSerial/releases/tag/0.8.0
