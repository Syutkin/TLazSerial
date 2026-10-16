# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Expose the TLazSerial package version through `LazSerialGetVersion`.
- Add `OnError` to report terminal reader failures after closing the port.

### Fixed

- Watchers retain the last snapshot and retry failed enumeration up to three
  times without false disconnections. Device-refresh callbacks can safely
  destroy their watcher, selector or owner without accessing freed memory
  or delivering further events.
- macOS device metadata prefers exact serial and location matches, rejects
  ambiguous matches and respects identifier boundaries in composite port names.
- Serial configuration errors, including failed reads of port settings and
  unsupported Unix baud rates, are preserved and reported even with
  `SynSer.RaiseExcept` disabled. Failed opens leave the port closed and `Active`
  false; rejected speeds preserve port settings. Reader activity and failed
  open cleanup cannot mask these errors, and status callbacks can safely read
  data or close the port. Failed live updates preserve property values and
  restore driver settings, closing the port if recovery fails and allowing
  the same setting to be retried. Unix port-state reads report the actual
  configured baud rate and preserve the previous DCB if reading settings fails.
- Closing a port bounds output draining by `SynSer.DeadlockTimeout`, releases
  its handle and resets `Active` even after I/O errors, preserving the first
  error. Destruction completes cleanup without propagating serial-close errors.
  Terminal reader failures also deactivate the port; ordinary readiness
  timeouts keep the reader running. Pending reader-error callbacks are safely
  cancelled before Windows thread waits can deliver them.
- Windows reads and writes use separate operation events, preserve completion
  errors and wait for cancelled I/O to finish before releasing buffers.
- Serial timeouts and bandwidth waits handle midnight and 32-bit timer wrap
  without spurious long delays.
- `WriteData` now returns the actual buffer-write result instead of the
  requested string length, preserving short writes and failures.
- Packet reads return only received bytes, returning an empty string on a
  negative read result while preserving the error.
- CRLF reads preserve incomplete lines across timeouts and read exceptions.
  Incomplete buffers do not cause repeated `OnRxData` callbacks or keep
  `DataAvailable` true without new bytes; non-blocking reads also append
  available bytes when `SynSer.InterPacketTimeout` is false. `MaxLineLength`
  includes the terminator and bounds new reads; oversized lines are skipped
  without losing following lines.

## [0.8.1] - 2026-09-29

### Fixed

- Windows serial-device enumeration no longer raises
  `EThreadExternalException` when called from the main thread, avoiding
  debugger interruptions while opening the COM-port menu.

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

[0.8.1]: https://github.com/Syutkin/TLazSerial/releases/tag/0.8.1
[0.8.0]: https://github.com/Syutkin/TLazSerial/releases/tag/0.8.0
