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
