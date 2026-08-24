# TLazSerial

TLazSerial is a serial-port component for Free Pascal and Lazarus. It provides
the visual `TLazSerial` transport component, a serial-port setup dialog and a
structured API for enumerating serial devices.

The current public API version is 0.8.0. This release intentionally removes the
legacy string-based device enumeration API; see [MIGRATION.md](MIGRATION.md).

## Features

- visual `TLazSerial` component for opening, configuring, reading from and
  writing to serial ports;
- standard and custom baud rates, configurable data bits, parity, flow control
  and one, one-and-a-half or two stop bits;
- `OnRxData`, `OnStatus` and `OnRemoved` events;
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

Reader-originated `OnRxData` and `OnStatus` callbacks are delivered on the LCL
main thread. A handler may close or destroy its `TLazSerial` component; an
exception raised by a handler remains a main-thread exception and does not stop
the serial reader.

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
- `tests/deviceinfo/` covers formatters, parsers and platform collectors;
- `tests/selector/` covers selector and watcher behavior.

A screenshot of the original GPS example is available
[here](https://user-images.githubusercontent.com/9909302/160068324-3467fac2-90e4-4625-9bfb-9cc0ef058bad.PNG).

The test projects are built with Lazarus:

```text
lazbuild --ws=qt6 tests/deviceinfo/serialdeviceinfotests.lpi
lazbuild --ws=qt6 tests/selector/serialselectortests.lpi
```

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
