unit SerialWindowsDeviceTests;

{$mode ObjFPC}{$H+}

interface

uses
  FpcUnit, TestRegistry, LazSerialDevices, LazSerialWindowsDevices;

type
  TSerialWindowsDeviceTests = class(TTestCase)
  published
    procedure ComPortNameRequiresNumericSuffix;
    procedure DeviceInfoIncludesSetupApiPropertiesAndParsedIdentifiers;
  end;

implementation

procedure TSerialWindowsDeviceTests.ComPortNameRequiresNumericSuffix;
begin
  AssertTrue(IsWindowsComPortName('COM1'));
  AssertTrue(IsWindowsComPortName(' com27 '));
  AssertFalse(IsWindowsComPortName('COM'));
  AssertFalse(IsWindowsComPortName('COM2x'));
  AssertFalse(IsWindowsComPortName('LPT1'));
end;

procedure TSerialWindowsDeviceTests.
  DeviceInfoIncludesSetupApiPropertiesAndParsedIdentifiers;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := BuildWindowsSerialDeviceInfo(
    'COM7',
    'Espressif Systems',
    'USB JTAG/serial debug unit (COM7)',
    'USB\VID_303A&PID_1001\ESP123456',
    22,
    True
  );

  AssertEquals('COM7', DeviceInfo.Device);
  AssertEquals('Espressif Systems', DeviceInfo.Vendor);
  AssertEquals('USB JTAG/serial debug unit', DeviceInfo.Model);
  AssertEquals('303a', DeviceInfo.VendorId);
  AssertEquals('1001', DeviceInfo.ProductId);
  AssertEquals('ESP123456', DeviceInfo.SerialShort);
  AssertEquals(
    'USB\VID_303A&PID_1001\ESP123456',
    DeviceInfo.PersistentId
  );
  AssertEquals('22', DeviceInfo.ErrorCode);
end;

initialization
  RegisterTest(TSerialWindowsDeviceTests);

end.
