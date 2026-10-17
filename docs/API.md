# API guide

See the [README](../README.md) for installation and a quick start.
This guide describes the runtime contracts of the current LCL-based package.

- [Threading and ownership](#threading-and-ownership)
- [Opening and control lines](#opening-a-serial-port)
- [Settings snapshots](#settings-snapshots)
- [Default reads and reader errors](#default-reads-and-reader-errors)
- [Buffered reads and delimiters](#buffered-reads)
- [Asynchronous writes and queue limits](#asynchronous-writes)
- [Closing and reopening](#closing-and-reopening)
- [Automatic reconnection](#automatic-reconnection)
- [Connection statistics](#connection-statistics)
- [Device enumeration and filtering](#structured-device-enumeration)
- [Selector](#serial-selector) and [watcher events](#watcher-events)
- [Platform notes](#platform-notes)

## Threading and ownership

Create, configure, use and destroy each `TLazSerial` instance on the main
thread. This includes opening and closing, reading and writing, changing
settings and accessing `SynSer`. Calls to the transport API from another
thread raise `ELazSerialThreadError`; application workers must queue their
work to the main thread.

Reader events and asynchronous write results are delivered on the LCL main
thread. Handlers may close, reopen or destroy the component, including through
its owner. Handler exceptions remain main-thread exceptions and do not stop
the reader. The next queued write starts only after its handler returns.

`SynSer` is read-only as a property: configure the owned `TBlockSerial` instance
without replacing or freeing it. Access is unavailable while an asynchronous
write, buffered receiver or their cleanup is pending. Previously saved
references have the same restrictions.

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

With a legacy connection and no pending asynchronous write, changing `Device`
sets the port for the next opening. Hotplug continues to track the port that
is currently open.

### Settings snapshots

`GetSettings: TSerialSettings` returns a copy of the component's configured
`BaudRate`, `CustomBaudRate`, `DataBits`, `Parity`, `StopBits` and `FlowControl`.
It is a main-thread memory snapshot, available while closed, receiving,
writing or cleaning up, and does not query the driver.

`ApplySettings(const ASettings: TSerialSettings)` applies the complete record.
Start with `GetSettings` when editing a subset:

```pascal
Saved := Serial.GetSettings;
Settings := Saved;
Settings.BaudRate := br115200;
Settings.CustomBaudRate := -1; // any negative value selects BaudRate
Settings.Parity := pEven;
Serial.ApplySettings(Settings);
// Restore later, when configuration is permitted:
Serial.ApplySettings(Saved);
```

A nonnegative `CustomBaudRate` overrides `BaudRate`. Initialize every field;
`Default(TSerialSettings)` sets that override to zero, not to -1. Enum values
and conflicts with opening-line settings are checked before any changes;
invalid candidates raise `EArgumentException`. Driver support is checked when
configuring an open port or on the next opening.

While closed, the validated record is saved for the next `Open`. While open,
the entire format is passed to one transport configuration call. Component
properties are committed together before status callbacks. On configuration
failure, previous properties are retained and the built-in transport restores
the driver state; if restoration fails, the connection closes. The original
configuration error is raised regardless of `SynSer.RaiseExcept`.

`ApplySettings` requires the main thread and rejects an active buffered reader,
pending writes (including queued entries/results), or cleanup with
`EInvalidOperation`. These restrictions also apply to an unchanged record.
`Device`, initial DTR/RTS states, read modes, queue settings and AutoReconnect
remain separate; applying a record does not open or switch ports. Individual
property setters continue to work through the same configuration path.

`TSerialSettings` is defined in `LazSerialSettings`, which has no LCL
dependency, and is also accessible through `LazSerial`.
This does not remove the component's existing LCL requirement.

### Initial DTR/RTS states

To request initial DTR/RTS states, set `DtrOnOpen` and `RtsOnOpen` while the
port is closed and both `ClosePending` and `WritePending` are false:

```pascal
Serial.FlowControl := fcNone;
Serial.DtrOnOpen := olsInactive;
Serial.RtsOnOpen := olsInactive;
Serial.Open;
```

Each property accepts `olsDefault`, `olsInactive` or `olsActive`. The default
preserves the previous platform-specific behavior: Connect asserts RTS and DTR,
then serial configuration applies the selected flow control. An explicit state
replaces that initial assertion and is retained when configuring the port.
Active/inactive describe the modem signal, not a guaranteed electrical voltage.
These settings do not change how closing the port handles the lines.

The native transport applies explicit states immediately after acquiring the
handle, before configuring speed or starting reception. An OS or driver can
still toggle the lines during the underlying open call; these properties reduce
unnecessary transitions but cannot guarantee that a connected board will not
reset. Unsupported line control or a driver error fails opening, releases the
handle and leaves `Active = False`, regardless of `SynSer.RaiseExcept`.

Conflicting combinations raise `EArgumentException` before opening: an explicit
DTR state with DTR/DSR handshaking, inactive DTR with a flow-control mode requiring
active DTR, or an explicit RTS state with driver-controlled RTS (handshake or
toggle). Conflicting live `FlowControl` changes are also rejected and retain the
current settings. Assigning either opening-line property while active, writing
or cleaning up raises `EInvalidOperation`.

## Default reads and reader errors

`RcvLineCRLF` defaults to `False`: `ReadData` returns byte chunks, which do not
define protocol message boundaries.

In the default receive mode, with `RcvLineCRLF = True`, `ReadData` returns
one line without its CRLF.
An incomplete line stays buffered and `ReadData` returns an empty string with
`SynSer.LastError = ErrTimeout`. `DataAvailable` and the reader wait for new
bytes or a complete buffered line, so an incomplete line alone does not cause
repeated `OnRxData` callbacks. A complete empty line also returns an empty
string, with `SynSer.LastError = 0`.

A terminal reader error closes the port, sets `Active = False` and calls
`OnError(Sender, ErrorCode, ErrorMessage)` on the main thread, regardless of
`SynSer.RaiseExcept`. The event preserves the original error even if closing
the port changes `SynSer.LastError`. `ErrorCode = 0` identifies an exception
without a native serial error code. Readiness timeouts keep the reader running
and do not trigger `OnError`. The handler may reopen or destroy the component;
closing or destroying it before delivery cancels the old notification.
Reopening follows the [cleanup rules](#closing-and-reopening).

| Port event | Notification |
| --- | --- |
| `OnRxData` | Input is ready to read; see the selected receive mode for readiness rules. |
| `OnStatus` | Serial status and I/O progress notifications. |
| `OnError` | A terminal reader failure, after logical closing. |
| `OnRemoved` | A previously tracked connected device disappears; the connection is closed before notification. |
| `OnWriteCompleted` | An asynchronous write result; closing suppresses pending results. |

Device-list events belong to [the watcher](#watcher-events) and do not indicate
that an application opened or closed a port.

## Buffered reads

Set `BufferedRead := True` before opening to move native input and receive
bandwidth waits out of the LCL thread. `ReadData`, `TryReadData` and
`DataAvailable` then use memory only. The default is `False`, which retains
the existing synchronous receive path.

```pascal
Serial.BufferedRead := True;
Serial.ReadBufferLimit := 65536;
Serial.SynSer.MaxLineLength := 4096;
Serial.RcvLineCRLF := True;
Serial.Open;
```

Read available results from `OnRxData` on the main thread:

```pascal
procedure TMainForm.Receive(Sender: TObject);
var
  Data: string;
begin
  while Serial.TryReadData(Data) do
    Memo.Lines.Add(Data);
end;
```

`TryReadData` returns `True` for a completed empty line and `False` with an
empty output string when nothing is ready. `ReadData` remains available,
returning an empty string in either case. In packet mode, returned byte
portions preserve order and embedded zeroes but do not define protocol
message boundaries. `TryReadData` outside buffered mode raises
`EInvalidOperation`; reading a closed port reports a closed-port error.

### Custom delimiters

For another delimiter, use `TryReadUntil` with **`BufferedRead = True` and
`RcvLineCRLF = False`**. Set these explicitly before opening; the method never
changes them and reports the required setting through `EInvalidOperation`.
In `OnRxData`:

```pascal
var
  Data: RawByteString;
begin
  while Serial.TryReadUntil(';', Data) do
    ProcessMessage(Data);
end;
```

Matching is byte-exact, including multibyte and binary delimiters. `True`
consumes the delimiter and returns the preceding bytes, possibly empty;
`False` clears `Data` and preserves the incomplete message. `AMaxLength`
defaults to 4096 bytes including the delimiter. It must be positive and fit
the nonempty delimiter. Exceeding it raises `ESynaSerError/ErrMaxBuffer`
regardless of `RaiseExcept`, preserving all bytes; retry with a larger limit
or retrieve them through `TryReadData`. `DataAvailable` and `OnRxData` still
describe available bytes, so they do not guarantee a complete delimited result.

### Notifications and limits

`DataAvailable` checks for a ready result without consuming it. An incomplete
line does not repeatedly trigger `OnRxData`. Reading one of several ready
lines schedules notification for the remainder; a handler that does not
consume data does not cause an endless notification loop. `OnStatus`
receive counts are also delivered on the main thread and may combine
multiple native reads into one count.

`ReadBufferLimit` is a positive byte limit, defaulting to 65536. It covers
unread data, retained parser bytes and capacity reserved for the in-flight
read. The worker fails explicitly when no space remains for reception:
`OnError` reports `ErrReadBufferOverflow` (9990), available from `LazSerial`
and `LazSerialCommon`. Data is not silently evicted to continue reception.

`MaxLineLength` retains its existing interpretation, including the terminator.
An oversized line raises `ESynaSerError` with `ErrMaxBuffer` from
`ReadData`/`TryReadData`, regardless of `SynSer.RaiseExcept`, and is skipped
through its terminator. The port remains open and following valid lines can
be read. `DataAvailable` and `OnRxData` also signal this recoverable result;
it does not call `OnError`. Catch the exception in the receive handler when
line-length recovery is needed. With `MaxLineLength = 0`, the general receive
limit still applies. Choose a line limit below the receive-buffer limit to
leave room for continued reception and recovery.

Set `BufferedRead`, `ReadBufferLimit` and low-level Synaser settings while
the port is closed and cleanup has finished. While the buffered receiver is
active, accessing `SynSer`, changing port settings/device, opening the setup
dialog or setting RTS/DTR raises `EInvalidOperation`. Previously saved
`SynSer` references must remain unused too. Changing `RcvLineCRLF` through
the component preserves unread bytes and recalculates readiness. Synchronous
and asynchronous writes remain available under the
[write restrictions](#asynchronous-writes); synchronous writes still block.

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

By default (`WriteQueueEnabled = False`), only one asynchronous write may be
pending. `WritePending` stays true through native completion and cancellation
cleanup. The completion event is always
queued, even for an empty string or immediate success. Before calling the
handler, the component clears `WritePending`, allowing the handler to start
the next write, close the port or destroy the component. Handler exceptions
remain main-thread exceptions.

While `WritePending` is true, another asynchronous write in single-write mode,
synchronous `WriteData` or `WriteBuffer`, changing the device or serial settings,
setting modem control lines and accessing `SynSer` raise `EInvalidOperation`. Previously saved
`SynSer` references must also remain unused until completion. Reading and
reader events continue while the port is active.

In the default single-write mode, call `CancelWrite` to request cancellation
without waiting for the driver. It does nothing when no write is pending. If
the write has already finished, its actual result is retained. The operation
keeps its buffer and native I/O
storage alive until cancellation actually completes. A slow or faulty Windows
driver may extend cancellation beyond the operation deadline; the worker
performs that wait outside the LCL thread.

### Write queue

Enable the optional FIFO to accept multiple `WriteDataAsync` calls:

```pascal
Serial.WriteQueueEnabled := True;
Id1 := Serial.WriteDataAsync(Command1, 1000);
Id2 := Serial.WriteDataAsync(Command2, 1000);
```

Each accepted call copies its bytes and returns its own ID before transmission
starts. The timeout starts when that entry is launched. Startup failures and
normal results arrive through `OnWriteCompleted`; the next write starts after
the handler returns. Handler exceptions do not stop queue processing.

`WriteQueueByteLimit` defaults to 65536 and `WriteQueueItemLimit` to 64;
overflow rejects the new call without consuming an ID. Limits and the read-only
`PendingWriteCount`/`PendingWriteBytes` include active and waiting entries, plus
results awaiting delivery. `WritePending` remains true while any exist. Queue
settings may change only when idle; synchronous writes cannot bypass the FIFO.

A failed, timed-out or cancelled write cancels the remaining entries. Their
results retain their IDs and report `swoCancelled` with zero bytes written.
`CancelWrite` cancels the whole sequence, retaining the actual result of a write
that already completed. Closing clears the queue and suppresses its pending
notifications; AutoReconnect never replays it. The queue does not await replies.

## Closing and reopening

In the default receive mode, with no asynchronous write pending, `Close` waits
for queued output up to `SynSer.DeadlockTimeout`, then purges and closes the
port. After a failed write it purges immediately and preserves the original
write error.

With buffered reads or a pending asynchronous write, `Close` sets
`Active = False`, cancels I/O and normally returns without waiting for native
cancellation. It discards unread input, clears the write queue and suppresses
pending write-completion events. Data accepted into an OS output queue is not
a guarantee of transmission before closing.

`ClosePending` tracks background port cleanup; `WritePending` also remains
true until the component processes a pending write's completion. Shared receive
cleanup may outlast the write. Before reopening, wait for both flags to become
false, using a later UI event or timer callback so the LCL event loop can run.
`Open` raises `EInvalidOperation` while cleanup is pending. A terminal `OnError`
may arrive before cleanup finishes.

Closing or a terminal read error discards unread input; old data and
notifications never enter the next session. Destruction detaches callbacks
while native operations retain the resources they need for cleanup.

If a cleanup thread cannot be created or started, cleanup runs synchronously
in the calling thread before the startup error is reported. In this exceptional
case, `Close` can wait for native cleanup.

## Automatic reconnection

Enable recovery after unplugging a previously opened device:

```pascal
Serial.AutoReconnect := True;
Serial.Open;
```

`ReconnectIntervalMs` defaults to 1000; `ReconnectMaxAttempts` defaults to 5.
Recovery uses the saved `PersistentId`, or VID/PID plus serial number, and
requires exactly one matching port. Missing identity or ambiguous matches never
select another device. A successful snapshot must confirm removal or a changed
port path; reader failure alone and receive-buffer overflow do not trigger opening.

`ReconnectPending` covers waiting for the device, RX/TX cleanup and retries;
`Active` stays false until opening succeeds. Only actual opening attempts count
towards the limit, captured when recovery starts. `OnReconnected` runs on the
main thread after success; `OnReconnectFailed(Sender, ErrorCode, ErrorMessage)`
runs once on exhaustion with the last opening error. Further recovery requires
a manual opening. Initial manual opening failures still raise normally.

`Close`, `Active := False`, changing `Device` or disabling `AutoReconnect`
cancels recovery. Reopening uses the configured serial settings, starts a new
statistics session and never replays old data or unfinished writes.

## Connection statistics

Read `Serial.Statistics` on the main thread to obtain a `TSerialStatistics`
snapshot, including during I/O or cleanup:

```pascal
Stats := Serial.Statistics;
```

- `BytesReceived`, `BytesSent` — native byte counters; sent bytes are accepted
  by the OS, without confirmation of delivery to the device.
- `ReadBufferUsed`, `ReadBufferPeak` — current and peak buffered receive usage
  in bytes. Both are zero in legacy mode; compare usage with `ReadBufferLimit`.
- `ErrorCount`, `LastErrorCode`, `LastErrorMessage` — recorded operation
  failures and the last error. Ordinary read timeouts and cancellation do not
  count as errors.
- `CloseReason` — why the session closed, such as a user request, device
  removal or a terminal read error.

Statistics survive closing and reset on a successful new `Open`; failed
opening preserves the previous session. Counts may still advance during
cleanup. Calculate RX/TX rates from counter differences and elapsed monotonic
time, resetting the sampling baseline after opening.

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

Use `MatchesSerialDevice` or `FilterSerialDevices` from `LazSerialDevices`
to search an existing snapshot without depending on the current port name:

```pascal
Filter := Default(TSerialDeviceFilter);
Filter.VendorId := '0403';
Filter.ProductId := '6001';
Filter.SerialShort := SavedSerialNumber;
Matches := FilterSerialDevices(Devices, Filter);
if Length(Matches) = 1 then
  Serial.Device := Matches[0].Device;
```

The filter also accepts `PersistentId`. Empty fields impose no restriction;
specified fields must all match. USB IDs are normalized with `NormalizeUsbId`;
invalid IDs and missing required metadata do not match. `SerialShort` matches
exactly; `PersistentId` ignores case only on Windows. Filtering returns an
independent array of all matches in snapshot order. Multiple matches require
an explicit choice; metadata availability and ID stability depend on the device
and platform.

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

## Watcher events

Watcher events run on the main thread after successful refreshes:

| Event | Notification |
| --- | --- |
| `OnDevicesRefreshed(Sender, Devices)` | A copy of the complete list, including initial, unchanged and empty snapshots. |
| `OnDeviceAdded(Sender, Device)` | Each added port, with its current details. |
| `OnDeviceRemoved(Sender, Device)` | Each removed port, with its last known details. |
| `OnDeviceChanged(Sender, Previous, Current)` | Changed metadata for a retained port, with both records. |
| `OnComConnected(Sender)` | Once per refresh with any additions, without device details. |
| `OnComDisconnected(Sender)` | Once per refresh with any removals, without device details. |

The first snapshot fires only `OnDevicesRefreshed`. Subsequent notifications
follow the table order; reordering alone produces no device-change events.
Ports match by `Device`; a renamed port is removed and added. Failed refreshes
keep the previous list and fire no events. These events describe device-list
changes, not serial-port opening or closing.

## Platform notes

| Platform | Device metadata | Change detection, with polling fallback |
| --- | --- | --- |
| Linux | `udevadm`; device names remain available without metadata | Dynamically loaded `libudev`, then `inotify(/dev)` |
| Windows | SetupAPI, with registry fallback | COM-port device notifications |
| macOS | `system_profiler SPUSBDataType`; prefers `/dev/cu.*` over a matching `/dev/tty.*` | IOKit |
| Other Unix | Device names without guaranteed metadata | Polling |

On macOS, set `Serial.SynSer.NonBlock := True` before opening when a nonblocking
open is required. Windows accepts the property for form compatibility but does
not use it when opening a COM port.

See [development notes](DEVELOPMENT.md#platform-device-discovery) for platform
implementation details and [virtual ports](DEVELOPMENT.md#virtual-ports) for
manual testing.
