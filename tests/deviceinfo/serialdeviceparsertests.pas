unit SerialDeviceParserTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerialDevices,
  LazSerialDeviceParsers;

type
  TSerialDeviceParserTests = class(TTestCase)
  private
    function FindFixture(const AFileName: string): string;
    function LoadFixture(const AFileName: string): string;
  published
    procedure DecodeUdevEncodedValueDecodesHexBytes;
    procedure DecodeUdevEncodedValuePreservesMalformedEscapes;
    procedure ParseLinuxPropertiesUsesDatabaseNamesFirst;
    procedure ParseLinuxPropertiesUsesEncodedFallbacks;
    procedure ParseLinuxPropertiesUsesPlainAndUsbFallbacks;
    procedure ParseLinuxPropertiesNormalizesIdsAndSelectsByIdLink;
    procedure ParseLinuxPropertiesToleratesMalformedInput;
    procedure ParseLinuxPropertiesWithNoMetadataKeepsDevice;
  end;

implementation

function TSerialDeviceParserTests.FindFixture(const AFileName: string): string;
var
  Candidate: string;
  Directory: string;
  I: Integer;
begin
  Directory := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  for I := 0 to 8 do
  begin
    Candidate := IncludeTrailingPathDelimiter(Directory) +
      'fixtures' + DirectorySeparator + AFileName;
    if FileExists(Candidate) then
      Exit(Candidate);
    Directory := ExtractFileDir(Directory);
  end;
  raise Exception.CreateFmt('Could not find test fixture %s', [AFileName]);
end;

function TSerialDeviceParserTests.LoadFixture(const AFileName: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FindFixture(AFileName));
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TSerialDeviceParserTests.DecodeUdevEncodedValueDecodesHexBytes;
begin
  AssertEquals('USB JTAG/serial', DecodeUdevEncodedValue(
    'USB\x20JTAG\x2fserial'
  ));
  AssertEquals('É', DecodeUdevEncodedValue('\xc3\x89'));
end;

procedure TSerialDeviceParserTests.
  DecodeUdevEncodedValuePreservesMalformedEscapes;
begin
  AssertEquals('Broken\xZZVendor', DecodeUdevEncodedValue(
    'Broken\xZZVendor'
  ));
  AssertEquals('Broken\x2', DecodeUdevEncodedValue('Broken\x2'));
end;

procedure TSerialDeviceParserTests.ParseLinuxPropertiesUsesDatabaseNamesFirst;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := ParseLinuxUdevProperties(
    '/dev/ttyACM0',
    LoadFixture('linux-udev-ch343.txt')
  );

  AssertEquals('QinHeng Electronics', DeviceInfo.Vendor);
  AssertEquals('USB Serial CH343', DeviceInfo.Model);
  AssertEquals('5ABA019711', DeviceInfo.SerialShort);
end;

procedure TSerialDeviceParserTests.ParseLinuxPropertiesUsesEncodedFallbacks;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := ParseLinuxUdevProperties(
    '/dev/ttyACM0',
    LoadFixture('linux-udev-esp32.txt')
  );

  AssertEquals('Espressif Systems', DeviceInfo.Vendor);
  AssertEquals('USB JTAG/serial debug unit', DeviceInfo.Model);
end;

procedure TSerialDeviceParserTests.ParseLinuxPropertiesUsesPlainAndUsbFallbacks;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := ParseLinuxUdevProperties(
    '/dev/ttyUSB0',
    LoadFixture('linux-udev-minimal.txt')
  );

  AssertEquals('Silicon Labs', DeviceInfo.Vendor);
  AssertEquals('CP2102N USB to UART Bridge Controller', DeviceInfo.Model);
  AssertEquals('0001', DeviceInfo.SerialShort);
  AssertEquals('10c4', DeviceInfo.VendorId);
  AssertEquals('ea60', DeviceInfo.ProductId);
  AssertEquals('', DeviceInfo.PersistentId);
end;

procedure TSerialDeviceParserTests.
  ParseLinuxPropertiesNormalizesIdsAndSelectsByIdLink;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := ParseLinuxUdevProperties(
    '/dev/ttyACM0',
    LoadFixture('linux-udev-esp32.txt')
  );

  AssertEquals('/dev/ttyACM0', DeviceInfo.Device);
  AssertEquals('303a', DeviceInfo.VendorId);
  AssertEquals('1001', DeviceInfo.ProductId);
  AssertEquals('123456', DeviceInfo.SerialShort);
  AssertEquals(
    '/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_123456-if00',
    DeviceInfo.PersistentId
  );
end;

procedure TSerialDeviceParserTests.ParseLinuxPropertiesToleratesMalformedInput;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := ParseLinuxUdevProperties(
    '/dev/ttyACM9',
    LoadFixture('linux-udev-malformed.txt')
  );

  AssertEquals('/dev/ttyACM9', DeviceInfo.Device);
  AssertEquals('Broken\xZZVendor', DeviceInfo.Vendor);
  AssertEquals('Broken\x2', DeviceInfo.Model);
  AssertEquals('', DeviceInfo.VendorId);
  AssertEquals('', DeviceInfo.ProductId);
  AssertEquals('', DeviceInfo.SerialShort);
  AssertEquals('/dev/serial/by-id/usb-valid', DeviceInfo.PersistentId);
end;

procedure TSerialDeviceParserTests.ParseLinuxPropertiesWithNoMetadataKeepsDevice;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := ParseLinuxUdevProperties('/dev/ttyS0', 'invalid line');

  AssertEquals('/dev/ttyS0', DeviceInfo.Device);
  AssertEquals('', DeviceInfo.Vendor);
  AssertEquals('', DeviceInfo.Model);
  AssertEquals('', DeviceInfo.SerialShort);
  AssertEquals('', DeviceInfo.VendorId);
  AssertEquals('', DeviceInfo.ProductId);
  AssertEquals('', DeviceInfo.PersistentId);
  AssertEquals('', DeviceInfo.ErrorCode);
end;

initialization
  RegisterTest(TSerialDeviceParserTests);

end.
