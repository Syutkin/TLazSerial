# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Add `TSerialWatcher.OnDevicesRefreshed` to deliver successful device snapshots
  on the main thread, including the initial baseline and metadata-only updates.

## [0.9.0] - 2026-10-17

### Added

- Expose the TLazSerial package version through `LazSerialGetVersion`.
- Add `OnError` to report terminal reader failures after closing the port.
- Add cancellable asynchronous serial writes with completion results on the
  main thread and nonblocking cleanup when closing during a write.
- Add opt-in buffered reads with bounded storage, memory-only result access
  and background cancellation and cleanup shared with asynchronous writes.
- Add console examples for synchronous I/O and buffered reads with
  asynchronous writes.

### Changed

- Synaser receive storage now uses a separate ring buffer, avoiding shifts of
  unread bytes when consuming a prefix and preserving the string `LineBuffer` API.

### Fixed

- Failed device refreshes preserve device lists and no longer cause false
  disconnections.
- Callbacks can safely close or destroy components; pending notifications are
  released on shutdown.
- macOS device metadata is only assigned when the match is unambiguous.
- Serial configuration errors are reported even with `SynSer.RaiseExcept`
  disabled; failed live changes restore settings or close the port.
- Closing a port respects `SynSer.DeadlockTimeout`, releases resources and
  clears `Active`; after a failed write it aborts queued output immediately
  and preserves the original write error.
- Windows reads and writes handle cancellation without accessing freed memory.
- Serial timeouts and bandwidth limits no longer cause unexpectedly long waits.
- `WriteData` reports partial writes and failures; packet reads return only
  received bytes.
- CRLF reads preserve partial lines and enforce `MaxLineLength` without losing
  following lines or repeatedly firing `OnRxData`.

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

[0.9.0]: https://github.com/Syutkin/TLazSerial/releases/tag/0.9.0
[0.8.1]: https://github.com/Syutkin/TLazSerial/releases/tag/0.8.1
[0.8.0]: https://github.com/Syutkin/TLazSerial/releases/tag/0.8.0
