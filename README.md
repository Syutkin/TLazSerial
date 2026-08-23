# TLazSerial

TLazSerial is a serial-port component for Free Pascal and Lazarus. It provides
the visual `TLazSerial` transport component, a serial-port setup dialog and a
structured API for enumerating serial devices.

The current public API version is 0.8.0. This release intentionally removes the
legacy string-based device enumeration API; see [MIGRATION.md](MIGRATION.md).

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
- Windows: WMI, with registry fallback;
- macOS: one `system_profiler SPUSBDataType` snapshot, preferring `/dev/cu.*`
  over a matching `/dev/tty.*` alias;
- other Unix targets: device names without guaranteed metadata.

## Serial selector

`TSerialSelector` displays the structured snapshot without mixing the friendly
text with the connectable name:

```pascal
var
  Device: TSerialDeviceInfo;
begin
  if SerialSelector.TryGetSelectedDevice(Device) then
    Serial.Device := Device.Device;
end;
```

Use `ShowFriendlyName` to switch friendly text on or off. `DisplayOptions`
independently controls Vendor, Model, SerialShort and ErrorCode output.

## Examples and tests

- `examples/serial-gps/` contains the serial/GPS example and setup dialog
  usage;
- `examples/serial-selector/` demonstrates `TSerialSelector` and friendly-name
  options;
- `tests/deviceinfo/` covers formatters, parsers and platform collectors;
- `tests/selector/` covers selector and watcher behavior.

The test projects are built with Lazarus:

```text
lazbuild --ws=qt6 tests/deviceinfo/serialdeviceinfotests.lpi
lazbuild --ws=qt6 tests/selector/serialselectortests.lpi
```

## History and license

TLazSerial was created by Jurassic Pork and is based on SdpoSerial by Paulo
Costa, Synaser by Lukas Gebauer and TComPort. Development of the 0.7 series was
continued by CM630; the current fork is maintained at
<https://github.com/Syutkin/TLazSerial>.

Versions through 0.6 are available from
<https://github.com/JurassicPork/TLazSerial>. The 0.7 development history is
available from <https://github.com/CM630/TLazSerial>.

The library is distributed under the GNU Library General Public License,
version 2 or, at your option, any later version. See [LICENSE](LICENSE) for the
full license text. Bundled Synapse-derived units retain their BSD license
notices in the corresponding source files.
