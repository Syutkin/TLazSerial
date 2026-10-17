# Migrating from TLazSerial 0.7.x to 0.8.0

Version 0.8.0 replaces string-based serial-device enumeration with
`TSerialDeviceInfoArray`. Opening, reading and writing through `TLazSerial`
remain unchanged.

## Enumerating devices

Before:

```pascal
Ports.CommaText := GetSerialPortNames;
LazSerial.Device := Ports[0];
```

After:

```pascal
uses
  LazSerialDevices;

Devices := GetSerialDevices;
if Length(Devices) > 0 then
  LazSerial.Device := Devices[0].Device;
```

Do not parse `FormatSerialDeviceDisplayName` output. Use the individual fields
of `TSerialDeviceInfo` when Vendor, Model, SerialShort, VID/PID, PersistentId or
ErrorCode is needed.

## Migrating `TSerialSelector`

`DeviceList`, `DeviceListFriend` and `Options` no longer exist. The selector
owns one structured snapshot and exposes:

- `Device` — the connectable name for the current selection;
- `Devices[Index]` and `DeviceCount` — structured snapshot access;
- `TryGetSelectedDevice` — safe access to the selected record;
- `AllowCustomDevice` — opt-in manual entry of a connectable name that is not
  present in the current snapshot;
- `ShowFriendlyName` and `DisplayOptions` — display-only configuration.

Example:

```pascal
SerialSelector.AllowCustomDevice := True;
LazSerial.Device := SerialSelector.Device;

if SerialSelector.TryGetSelectedDevice(DeviceInfo) then
  WriteLn(DeviceInfo.Model);
```

`Device` works for both a selected snapshot record and a manual value.
`TryGetSelectedDevice` only succeeds when metadata for the selected record is
available.

The old `ssoAppendFriendlyNames`, `ssoUseWMI`, `ssoHide_tty_usbserial`,
`ssoAppendSerialNumber` and `ssoAppendErrorCode` options are removed. Use
`ShowFriendlyName` and the `sddoVendor`, `sddoModel`, `sddoSerialShort` and
`sddoErrorCode` display options instead. Platform collector selection is now an
internal detail.

## Removed symbols

- `GetSerialPortNames` and its overloads;
- `GetFriendlyName`, `GetFriendlyNameDevID` and platform friendly-name helpers;
- `TSSOption`, `TSSOptionS` and all `sso*` values;
- `TSerialSelector.DeviceList`, `DeviceListFriend` and `Options`.

`TLazSerial.ShowSetupDialog` no longer accepts legacy enumeration options.

## Opting in to asynchronous writes (unreleased)

Existing synchronous write signatures remain unchanged. To use asynchronous
writes, call `WriteDataAsync(Data, TimeoutMs)` from the main thread and handle
`OnWriteCompleted`. The return value is an operation identifier; the result
event carries the actual byte count and error. `OnError` retains its reader
error contract.

There is one pending write per component. During that operation, synchronous
writes, configuration changes and direct `SynSer` access are rejected.
`CancelWrite` requests cancellation without waiting for completion. Closing
during a write starts background cleanup; wait for `WritePending = False`
before reopening. See [Asynchronous writes](README.md#asynchronous-writes)
for the complete lifecycle and result contract.
