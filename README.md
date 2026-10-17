# TLazSerial

TLazSerial is a serial-port component for Free Pascal and Lazarus, with a port
settings dialog, device selector and structured device enumeration for Linux,
Windows and macOS. The current package requires LCL, including in console apps.

- Standard and custom baud rates, parity, stop bits and flow control.
- Buffered reads with CRLF or custom delimiters.
- Asynchronous writes with cancellation and an optional bounded queue.
- Device filtering by stable identifiers, hotplug events and automatic reconnection.
- Connection statistics and initial DTR/RTS settings.

See the [API guide](docs/API.md), [migration guide](docs/MIGRATION.md) and
[changelog](CHANGELOG.md) for details and upgrade instructions.

## Installation

Open `LazSerialPort.lpk` in Lazarus, compile it and install it to use the
design-time components. Applications using only runtime units still depend
on the same package and LCL.

## Quick start

Place `TLazSerial` named `Serial` and `TMemo` named `Memo` on a form. Add
`LazSerial` and `LazSerialCommon` to its `uses` clause. Assign the form's
`OnCreate` and `OnDestroy` to the handlers below:

```pascal
procedure TMainForm.FormCreate(Sender: TObject);
begin
  Serial.Device := '/dev/ttyACM0'; // e.g. COM3 on Windows
  Serial.BaudRate := br115200;
  Serial.DataBits := db8bits;
  Serial.Parity := pNone;
  Serial.StopBits := sbOne;
  Serial.FlowControl := fcNone;
  Serial.RcvLineCRLF := True;
  Serial.OnRxData := @Receive;
  Serial.Open;
  Serial.WriteData('hello' + #13#10);
end;

procedure TMainForm.Receive(Sender: TObject);
var
  Data: string;
begin
  Data := Serial.ReadData;
  if Serial.SynSer.LastError = 0 then
    Memo.Lines.Add(Data);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Serial.Close;
end;
```

Declare `Receive(Sender: TObject)` in the form class. With `RcvLineCRLF = True`,
`ReadData` returns one line without its terminator; partial lines remain buffered.
`WriteData` is synchronous and returns the number of bytes sent. Use
`ShowSetupDialog` to edit port settings interactively.

## Settings snapshots

Use `TSerialSettings` to save or apply the port's data format as one operation.
Existing individual properties remain available:

```pascal
Settings := Serial.GetSettings;
Settings.BaudRate := br115200;
Settings.CustomBaudRate := -1;
Settings.Parity := pEven;
Serial.ApplySettings(Settings);
```

See [settings and rollback rules](docs/API.md#settings-snapshots).

## Buffered reads

Enable buffered input before opening to keep native reads out of the GUI thread:

```pascal
Serial.BufferedRead := True;
Serial.RcvLineCRLF := True;
Serial.ReadBufferLimit := 65536; // default, bytes
Serial.SynSer.MaxLineLength := 4096;
```

Read all ready results in `OnRxData`:

```pascal
while Serial.TryReadData(Data) do
  ProcessMessage(Data);
```

`TryReadData` returns `True` even for a completed empty line. Without CRLF mode,
it returns byte chunks rather than protocol messages. For another delimiter,
set `BufferedRead := True` and `RcvLineCRLF := False`, then use a
`RawByteString` variable:

```pascal
while Serial.TryReadUntil(';', Data) do
  ProcessMessage(Data);
```

`TryReadUntil` excludes the delimiter and retains incomplete messages. Its
length limit defaults to 4096 bytes, including the delimiter. Exceeding that
limit raises `ErrMaxBuffer` without consuming data. Receive-buffer overflow
reports `ErrReadBufferOverflow` through `OnError` and closes the connection.
See [read contracts and recovery](docs/API.md#buffered-reads).

## Asynchronous writes

Set `OnWriteCompleted` before sending. Each accepted call returns an operation
ID; the handler receives a `TSerialWriteResult` with the outcome, byte counts
and error details:

```pascal
Serial.OnWriteCompleted := @WriteCompleted;
OperationId := Serial.WriteDataAsync(Command, 1000); // timeout, ms
```

Only one write may be pending by default. Enable the FIFO before sending
to accept consecutive calls:

```pascal
Serial.WriteQueueEnabled := True;
Id1 := Serial.WriteDataAsync(Command1, 1000);
Id2 := Serial.WriteDataAsync(Command2, 1000);
```

The queue defaults to 65536 bytes and 64 operations, configured through
`WriteQueueByteLimit` and `WriteQueueItemLimit`. Limits include active,
waiting and undelivered results; overflow rejects the new call. Each timeout
starts when its write is launched. Failure, timeout or `CancelWrite` cancels
the remaining sequence. `Close` clears it. No response from the device is
awaited automatically. See [results, limits and cancellation](docs/API.md#asynchronous-writes).

## Finding and watching devices

Use `GetSerialDevices` from `LazSerialDevices` to obtain device names and
optional metadata. Filter an existing snapshot without relying on COM numbers
or `/dev/ttyUSB*` names:

```pascal
Devices := GetSerialDevices;
Filter := Default(TSerialDeviceFilter);
Filter.VendorId := '0403';
Filter.ProductId := '6001';
Filter.SerialShort := SavedSerialNumber;
Matches := FilterSerialDevices(Devices, Filter);
if Length(Matches) = 1 then
  Serial.Device := Matches[0].Device;
```

`PersistentId` is also supported. All specified fields must match; multiple
matches require an explicit choice. See [enumeration and filtering](docs/API.md#structured-device-enumeration).

`TSerialSelector.Device` provides the connectable name; `ShowFriendlyName`
and `DisplayOptions` control its display. Enable `AllowCustomDevice` for
manual entry. `TSerialWatcher` provides full snapshots and per-device
added/removed/changed events. These report device-list changes, independently
of opening or closing a connection. See [selector](docs/API.md#serial-selector)
and the [event table](docs/API.md#watcher-events).

## Automatic reconnection

Enable recovery before opening:

```pascal
Serial.AutoReconnect := True;
Serial.Open;
```

Defaults are `ReconnectIntervalMs = 1000` and `ReconnectMaxAttempts = 5`.
Recovery requires a saved stable identity and exactly one matching device.
`ReconnectPending` reports waiting/retries; `OnReconnected` reports success
and `OnReconnectFailed` reports exhausted attempts. Manual closing cancels
recovery. Old data and writes are never replayed.
See [recovery rules](docs/API.md#automatic-reconnection).

## Statistics and control lines

`Serial.Statistics` provides RX/TX byte counts, receive-buffer usage and peak,
error diagnostics and the close reason. Counters survive closing and reset
after a successful opening. See [statistics](docs/API.md#connection-statistics).

Set `DtrOnOpen` and `RtsOnOpen` while closed and idle to `olsDefault` (default),
`olsInactive` or `olsActive`. Explicit states can reduce unwanted microcontroller
resets; drivers may still toggle the signals during opening. Conflicts with
flow control are rejected. See [initial line states](docs/API.md#initial-dtrrts-states).

## Threading, errors and closing

- Create, use and destroy `TLazSerial` on the main thread; callbacks run there too.
- Configure low-level settings before starting buffered input. `SynSer` is owned
  by the component and unavailable during buffered reads, asynchronous writes
  and their cleanup. Pending writes also restrict settings and synchronous writes.
- `OnError` reports terminal reader failures after logical closing. Write errors
  arrive through `OnWriteCompleted`.
- With buffered input or a pending asynchronous write, closing normally cancels
  I/O in the background. Before reopening, let the event loop run and wait for
  both `ClosePending = False` and `WritePending = False`.

See [threading and ownership](docs/API.md#threading-and-ownership) and
[closing and reopening](docs/API.md#closing-and-reopening) for the full contracts.

## Examples and development

| Example | Demonstrates |
| --- | --- |
| [Console: legacy](examples/console/legacy.lpr) | Synchronous reads and writes |
| [Console: buffered](examples/console/buffered.lpr) | Buffered reads and asynchronous writes |
| [Serial selector](examples/serial-selector/) | Device selection, hotplug and data exchange; Arduino sketch included |
| [Diagnostic terminal](examples/serial-terminal/) | HEX/ASCII, queued writes, file logging and statistics |
| [GPS](examples/serial-gps/) | Serial receiver, setup dialog and NMEA simulator |

See [development instructions](docs/DEVELOPMENT.md) for building examples,
running tests, virtual ports and custom transports. Console examples currently
require LCL; on headless Linux use `QT_QPA_PLATFORM=offscreen`.

## Authors and license

Created by [Jurassic Pork](https://github.com/JurassicPork/TLazSerial) in 2013,
based on SdpoSerial 0.1.4 (Paulo Costa), Synaser (Lukas Gebauer) and TComPort.
The 0.7 series was continued by [CM630](https://github.com/CM630/TLazSerial);
the current fork is maintained at <https://github.com/Syutkin/TLazSerial>.

Distributed under the GNU Library General Public License, version 2 or later;
see [LICENSE](LICENSE). Bundled Synapse-derived units retain their BSD notices.
