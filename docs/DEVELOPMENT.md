# Development guide

See the [README](../README.md) for getting started and the [API guide](API.md)
for public behavior. Run the commands below from the repository root.
Always use `lazbuild --ws=qt6` for Lazarus builds.

## Package and GUI examples

```sh
lazbuild --ws=qt6 LazSerialPort.lpk
lazbuild --ws=qt6 examples/serial-selector/serialselectorexample.lpi
lazbuild --ws=qt6 examples/serial-gps/serialgpsexample.lpi
lazbuild --ws=qt6 examples/serial-terminal/serialterminal.lpi
```

## Examples

- [Diagnostic terminal](../examples/serial-terminal/README.md) shows HEX/ASCII,
  text and binary sending, the write queue, initial DTR/RTS states, background
  file logging and connection statistics. It accepts an optional device
  argument; connection settings can be hidden while monitoring the exchange.
- `examples/console/legacy.lpr` shows console I/O with `ReadData` and
  synchronous `WriteData`; `buffered.lpr` uses `BufferedRead`, `TryReadData`
  and `WriteDataAsync`. Both list ports for selection, accept a manually
  entered device or an optional port argument, and use 115200 8N1 without
  flow control. Enter sends the typed line with CRLF; `/quit` exits;
- `examples/serial-gps/` contains a serial-port receiver, the setup-dialog
  example and a GPS simulator. The simulator sends NMEA GGA, GLL and RMC
  frames; speed and heading can be changed while it is running. Received data
  is shown in the memo and serial status events are shown in the status bar;
- `examples/serial-selector/` demonstrates `TSerialSelector`, friendly-name
  options, connect/disconnect, hotplug handling and serial data exchange. The
  accompanying `serialselectorexample.ino` sketch can be flashed to an Arduino
  or compatible board for a hardware test.

A screenshot of the original GPS example is available
[here](https://user-images.githubusercontent.com/9909302/160068324-3467fac2-90e4-4625-9bfb-9cc0ef058bad.PNG).

Build and run the console examples from a terminal:

```sh
lazbuild --ws=qt6 examples/console/legacy.lpi
lazbuild --ws=qt6 examples/console/buffered.lpi
examples/console/.example_build/legacy
examples/console/.example_build/buffered
```

Append a port such as `/dev/ttyUSB0` or `COM3` to skip selection. The examples
create no windows but depend on LCL; on a headless Linux host, set
`QT_QPA_PLATFORM=offscreen`. If the Qt6 linker requires it, add
`--opt=-k-lQt6DBus` to the build commands. Incoming bytes may arrive in several
chunks or combine several writes. The main loop pumps `CheckSynchronize`
while polling the keyboard so callbacks also run while a line is being typed.
The buffered example also pumps it until `OnCloseCompleted` confirms cleanup.

## Tests

- `tests/serial/` covers serial I/O, configuration, lifecycle and setup;
- `tests/selector/` covers selector behavior;
- `tests/watcher/` covers device watching and platform change sources;
- `tests/infrastructure/` covers refresh delivery, scheduling, command execution
  and timing utilities;
- `tests/deviceinfo/` covers formatters, parsers and platform collectors,
  with parser fixtures in `tests/deviceinfo/fixtures/`.

All tests use one LCL test runner, including the serial, selector, watcher,
infrastructure and device-info tests. Build it with Lazarus:

```sh
lazbuild --ws=qt6 --opt=-k-lQt6DBus tests/lazserialtests.lpi
QT_QPA_PLATFORM=offscreen tests/.test_build/lazserialtests --all
```

The Qt6DBus linker option is needed in the current Linux environment. On
Windows, run `tests/.test_build/lazserialtests.exe --all`. For memory checks,
use `heaptrc`; `HEAPTRC=keepreleased` helps diagnose access to freed objects.
Distinguish tests using fake drivers, PTYs, Wine and physical hardware when
reporting results.

## Virtual ports

If no physical serial ports are available, a virtual pair can be used for
manual testing:

- Windows: install `com0com` and create a paired set of virtual COM ports;
- Linux: create a PTY pair with `socat`:

  ```sh
  socat -d -d PTY: PTY:
  ```

A classic Bluetooth serial/GPS device can be exposed as `/dev/rfcomm0` on
Linux with:

```sh
sudo rfcomm bind 0 xx:xx:xx:xx:xx:xx 1
```

## Custom transports

To support initial DTR/RTS states in a custom transport, override
`ConfigureOpenLines(ADtr, ARts, AFlowControl)` and apply them
during opening. Its base implementation accepts defaults and rejects explicit
states before connecting. Direct Synaser users can call the same method on
`TBlockSerial` before `Connect`.

A custom buffered reader should use its supplied `AOnChanged` callback to
report completion of closing, after `GetClosePending` becomes false. Keep that
callback attached until `Detach`; `TLazSerial` suppresses receive delivery while
inactive and uses the final notification for `OnCloseCompleted`. The built-in
shared port implements optional `ISerialPortCloseNotification` so the reader
also observes handle cleanup that outlasts its own worker. Custom shared port
owners used with `TSerialReadOperation` can implement the same capability.

Buffered input requires `CreateReadOperation` support; enabling it on a
transport without that support fails and rolls back opening.

Asynchronous writes require `CreateWriteOperation` support; its base
implementation rejects the request. Override `CompleteWrite` when the
transport needs to apply the completed result to its own error state.

## Platform device discovery

Platform metadata sources are:

- Linux: `udevadm`, with device-only fallback;
- Windows: SetupAPI, with registry fallback;
- macOS: one `system_profiler SPUSBDataType` snapshot, preferring `/dev/cu.*`
  over a matching `/dev/tty.*` alias;
- other Unix targets: device names without guaranteed metadata.

On Linux, serial-device changes are detected through a dynamically loaded
`libudev.so.1` monitor. If it is unavailable or stops working, TLazSerial
automatically falls back to `inotify(/dev)` and then to periodic polling;
`libudev` is not a required link-time dependency.

On Windows, TLazSerial listens for the COM-port device-interface class through
`RegisterDeviceNotification`. Notifications use a short debounce and bounded
settling retries while SetupAPI finishes publishing a new port. If native
notification registration fails, the watcher falls back to periodic polling.

On macOS, TLazSerial listens for matched and terminated `IOSerialBSDClient`
services through IOKit. The initial notification iterators are drained before
normal event delivery, and all IOKit handles are released synchronously when
the watcher stops. If IOKit initialization fails or its run-loop source becomes
invalid, the watcher falls back to periodic polling.
