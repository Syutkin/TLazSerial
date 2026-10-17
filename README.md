# TLazSerial

TLazSerial is a serial-port component for Free Pascal and Lazarus. It provides
the visual `TLazSerial` transport component, a serial-port setup dialog and a
structured API for enumerating serial devices.

The current public API version is 0.8.1. Version 0.8.0 removed the legacy
string-based device enumeration API; see [MIGRATION.md](MIGRATION.md).
The asynchronous-write API described below is currently unreleased.

## Features

- visual `TLazSerial` component for opening, configuring, reading from and
  writing to serial ports;
- standard and custom baud rates, configurable data bits, parity, flow control
  and one, one-and-a-half or two stop bits;
- `OnRxData`, `OnStatus`, `OnError` and `OnRemoved` events;
- asynchronous writes with an operation deadline, cancellation and
  `OnWriteCompleted` results delivered on the main thread;
- `RcvLineCRLF`, which makes `ReadData` use line-oriented `RecvString` instead
  of `RecvPacket`;
- a bundled setup dialog opened with `ShowSetupDialog`;
- structured cross-platform device enumeration and the visual
  `TSerialSelector` component;
- automatic serial-device change detection used by `TSerialSelector` and
  `TLazSerial`, with enumeration performed outside the GUI thread.

## Installation

Open `LazSerialPort.lpk` in Lazarus, compile the package and install it if the
design-time components are required. Applications that only use the runtime
units still depend on the same package.

## Opening a serial port

Place `TLazSerial` on a form or create it in code, configure `Device` and the
serial parameters, then call `Open`:

```pascal
Serial.Device := '/dev/ttyACM0';
Serial.BaudRate := br115200;
Serial.Open;
```

Use `OnRxData` with `ReadData` for incoming data and `WriteData` for outgoing
data. `ShowSetupDialog` opens the bundled port-settings dialog.

With `RcvLineCRLF = True`, `ReadData` returns one line without its CRLF.
An incomplete line stays buffered and `ReadData` returns an empty string with
`SynSer.LastError = ErrTimeout`. `DataAvailable` and the reader wait for new
bytes or a complete buffered line, so an incomplete line alone does not cause
repeated `OnRxData` callbacks. A complete empty line also returns an empty
string, with `SynSer.LastError = 0`.

Reader-originated `OnRxData` and `OnStatus` callbacks are delivered on the LCL
main thread. A handler may close or destroy its `TLazSerial` component; an
exception raised by a handler remains a main-thread exception and does not stop
the serial reader.

A terminal reader error closes the port, sets `Active = False` and calls
`OnError(Sender, ErrorCode, ErrorMessage)` on the main thread, regardless of
`SynSer.RaiseExcept`. The event preserves the original error even if closing
the port changes `SynSer.LastError`. `ErrorCode = 0` identifies an exception
without a native serial error code. Readiness timeouts keep the reader running
and do not trigger `OnError`. The handler may reopen or destroy the component;
closing or destroying it before delivery cancels the old notification.
If a pending asynchronous write is being cancelled, reopening must wait for
`WritePending = False`.

## Asynchronous writes

Use `WriteDataAsync` to send data without waiting for serial transmission in
the LCL thread. Set `OnWriteCompleted` before starting the operation:

```pascal
Serial.OnWriteCompleted := @WriteCompleted;
OperationId := Serial.WriteDataAsync('hello' + #0, 1000);
```

The returned nonzero `QWord` identifies the accepted operation. The component
copies the string's bytes, including embedded zeroes; the caller may change or
release its original string immediately. `ATimeoutMs` must be greater than
zero and covers the whole operation, including retries after partial writes.
Passing zero raises `EArgumentException`.

The completion handler receives `TSerialWriteResult`, available from
`LazSerial`:

```pascal
procedure TMainForm.WriteCompleted(Sender: TObject;
  const AResult: TSerialWriteResult);
begin
  Memo.Lines.Add(Format('Write %d: %d/%d bytes, error %d: %s',
    [AResult.OperationId, AResult.BytesWritten, AResult.BytesRequested,
     AResult.ErrorCode, AResult.ErrorMessage]));
end;
```

`Outcome` is `swoCompleted`, `swoFailed`, `swoCancelled` or `swoTimedOut`.
`BytesWritten` preserves actual progress on failure or cancellation. A timeout
reports `ErrTimeout`; a requested cancellation reports error code zero.
Other failures preserve their original code and message; an exception without
a native code reports zero with its exception message. Results are independent
of `SynSer.LastError` and `RaiseExcept`. `OnError` continues to report reader
failures. Write completion does not acknowledge receipt by the remote device.

Only one asynchronous write may be pending. `WritePending` stays true through
native completion and cancellation cleanup. The completion event is always
queued, even for an empty string or immediate success. Before calling the
handler, the component clears `WritePending`, allowing the handler to start
the next write, close the port or destroy the component. Handler exceptions
remain main-thread exceptions.

While `WritePending` is true, another write, synchronous `WriteData` or
`WriteBuffer`, changing the device or serial settings, setting modem control
lines and accessing `SynSer` raise `EInvalidOperation`. Previously saved
`SynSer` references must also remain unused until completion. Reading and
reader events continue while the port is active.

Call `CancelWrite` to request cancellation without waiting for the driver.
It does nothing when no write is pending. If the write has already finished,
its actual result is retained. The operation keeps its buffer and native I/O
storage alive until cancellation actually completes. A slow or faulty Windows
driver may extend cancellation beyond the operation deadline; the worker
performs that wait outside the LCL thread.

`Close` during an asynchronous write sets `Active = False`, suppresses that
operation's public completion event and starts cancellation and port cleanup.
`WritePending` remains true until cleanup completes; `Open` raises
`EInvalidOperation` during that interval. Once pending becomes false, the port
can be reopened. Old-session notifications are discarded. Destroying the
component detaches its callbacks while cleanup retains the resources it needs.
When reopening after cancellation, let the LCL event loop continue and check
`WritePending` from a later UI event or timer callback.

Existing synchronous write signatures and behavior remain available when no
asynchronous write is pending. Normal close waits for queued output up to
`SynSer.DeadlockTimeout`. After a failed write, close purges pending output
immediately and preserves the original write error.

## Threading contract

Create, configure, use and destroy each `TLazSerial` instance on the main
thread. This includes opening and closing the port, reading and writing data,
changing serial settings and accessing the low-level `SynSer` object. Calls to
the transport API from another thread raise `ELazSerialThreadError`.

The reader thread only waits for data. Asynchronous writes use a separate
internal worker with operation-local state. Their callbacks are delivered on
the main thread. Application worker threads that need to use `TLazSerial`
must queue their work to the main thread.

`SynSer` is read-only as a `TLazSerial` property: its settings remain available,
but the owned `TBlockSerial` instance cannot be replaced. Access is unavailable
while an asynchronous write or its cleanup is pending.

## Structured device enumeration

`LazSerialDevices` returns the connectable device name separately from optional
metadata:

```pascal
uses
  LazSerialDevices;

var
  Device: TSerialDeviceInfo;
  Devices: TSerialDeviceInfoArray;
begin
  Devices := GetSerialDevices;
  for Device in Devices do
    WriteLn(FormatSerialDeviceDisplayName(Device));

  if Length(Devices) > 0 then
    Serial.Device := Devices[0].Device;
end;
```

`TSerialDeviceInfo.Device` is the value used to open the port. `Vendor`,
`Model`, `SerialShort`, `VendorId`, `ProductId`, `PersistentId` and `ErrorCode`
are optional. A failure to obtain metadata does not remove the device from the
result.

Pass `[sdeoAccessibleOnly]` to `GetSerialDevices` when only devices that can be
opened at enumeration time are needed.

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

## Serial selector

`TSerialSelector` displays the structured snapshot without mixing the friendly
text with the connectable name. `Device` always returns the connectable name:

```pascal
SerialSelector.AllowCustomDevice := True;
Serial.Device := SerialSelector.Device;
```

Use `ShowFriendlyName` to switch friendly text on or off. `DisplayOptions`
independently controls Vendor, Model, SerialShort and ErrorCode output. With
`AllowCustomDevice = True`, the user can enter a port or alias that is absent
from the current snapshot. `TryGetSelectedDevice` returns `False` for such a
manual value because no structured metadata record exists for it.

## Platform notes

On macOS, set `Serial.SynSer.NonBlock := True` before opening the device when a
non-blocking open is required. The property is also available on Windows so
the same form resource can be loaded cross-platform, but Windows does not use
it when opening a COM port.

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

## Examples and tests

- `examples/serial-gps/` contains a serial-port receiver, the setup-dialog
  example and a GPS simulator. The simulator sends NMEA GGA, GLL and RMC
  frames; speed and heading can be changed while it is running. Received data
  is shown in the memo and serial status events are shown in the status bar;
- `examples/serial-selector/` demonstrates `TSerialSelector`, friendly-name
  options, connect/disconnect, hotplug handling and serial data exchange. The
  accompanying `serialselectorexample.ino` sketch can be flashed to an Arduino
  or compatible board for a hardware test;
- `tests/serial/` covers serial I/O, configuration, lifecycle and setup;
- `tests/selector/` covers selector behavior;
- `tests/watcher/` covers device watching and platform change sources;
- `tests/infrastructure/` covers refresh delivery, scheduling, command execution
  and timing utilities;
- `tests/deviceinfo/` covers formatters, parsers and platform collectors,
  with parser fixtures in `tests/deviceinfo/fixtures/`.

A screenshot of the original GPS example is available
[here](https://user-images.githubusercontent.com/9909302/160068324-3467fac2-90e4-4625-9bfb-9cc0ef058bad.PNG).

All tests use one LCL test runner, including the serial, selector, watcher,
infrastructure and device-info tests. Build it with Lazarus:

```text
lazbuild --ws=qt6 tests/lazserialtests.lpi
```

Run all tests with `tests/.test_build/lazserialtests --all`
(add `.exe` on Windows).

## History and license

TLazSerial was created by Jurassic Pork in 2013 and is based on:

- SdpoSerial 0.1.4, Copyright (C) 2006-2010 Paulo Costa;
- Synaser by Lukas Gebauer;
- TComPort.

Development of the 0.7 series was continued by CM630; the current fork is
maintained at <https://github.com/Syutkin/TLazSerial>.

Versions through 0.6 are available from
<https://github.com/JurassicPork/TLazSerial>. The 0.7 development history is
available from <https://github.com/CM630/TLazSerial>.

Notable changes from the original releases were:

- 0.3: ARM/Raspberry Pi conditional definitions and removal of `Active` from
  the Object Inspector;
- 0.4 (February 2021): `DeviceClose` fix;
- 0.5 (March 2021): fixed a leak in serial-port enumeration;
- 0.6 (March 2022): macOS fixes, persistent Synaser properties and version 0.3
  of the GPS simulator.

Versions through 0.6 were tested upstream on Windows 10 and Ubuntu 20.04 with
Lazarus 2.0.10. The 0.7 series was tested on Windows 7, 10 and 11 and on Linux
Mint Mate with Lazarus 4.6, including some virtual-machine testing. See
[CHANGELOG.md](CHANGELOG.md) for the current fork's release history.

The library is distributed under the GNU Library General Public License,
version 2 or, at your option, any later version. See [LICENSE](LICENSE) for the
full license text. Bundled Synapse-derived units retain their BSD license
notices in the corresponding source files.
