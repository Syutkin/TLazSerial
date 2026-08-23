unit SerialDeviceFormatTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerialDevices;

type
  TSerialDeviceFormatTests = class(TTestCase)
  private
    function CreateDevice: TSerialDeviceInfo;
  published
    procedure DeviceInfoStoresStructuredFields;
    procedure NormalizeUsbIdAcceptsKnownFormats;
    procedure NormalizeUsbIdRejectsInvalidValues;
    procedure FriendlyNameIncludesEveryEnabledField;
    procedure FriendlyNameControlsFieldsIndependently;
    procedure FriendlyNameDoesNotRepeatVendorFromModel;
    procedure FriendlyNameTrimsValuesAndPreservesUnicode;
    procedure FriendlyNameSuppressesZeroErrorCode;
    procedure EmptyMetadataProducesNoFriendlyName;
    procedure EmptyOptionsHideFriendlyName;
    procedure DisplayNameWrapsFriendlyName;
    procedure DisplayNameUsesDeviceWhenFriendlyNameIsEmpty;
  end;

implementation

function TSerialDeviceFormatTests.CreateDevice: TSerialDeviceInfo;
begin
  Result.Device := '/dev/ttyACM0';
  Result.Vendor := 'QinHeng Electronics';
  Result.Model := 'USB Single Serial';
  Result.SerialShort := '5ABA019711';
  Result.VendorId := '1a86';
  Result.ProductId := '55d3';
  Result.PersistentId := '/dev/serial/by-id/usb-1a86_USB_Single_Serial_5ABA019711';
  Result.ErrorCode := '12';
end;

procedure TSerialDeviceFormatTests.DeviceInfoStoresStructuredFields;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;

  AssertEquals('/dev/ttyACM0', DeviceInfo.Device);
  AssertEquals('QinHeng Electronics', DeviceInfo.Vendor);
  AssertEquals('USB Single Serial', DeviceInfo.Model);
  AssertEquals('5ABA019711', DeviceInfo.SerialShort);
  AssertEquals('1a86', DeviceInfo.VendorId);
  AssertEquals('55d3', DeviceInfo.ProductId);
  AssertEquals(
    '/dev/serial/by-id/usb-1a86_USB_Single_Serial_5ABA019711',
    DeviceInfo.PersistentId
  );
  AssertEquals('12', DeviceInfo.ErrorCode);
end;

procedure TSerialDeviceFormatTests.NormalizeUsbIdAcceptsKnownFormats;
begin
  AssertEquals('1a86', NormalizeUsbId('1A86'));
  AssertEquals('55d3', NormalizeUsbId('0x55D3'));
  AssertEquals('0403', NormalizeUsbId('VID_0403'));
  AssertEquals('55d3', NormalizeUsbId('PID_55D3'));
  AssertEquals('0403', NormalizeUsbId('403'));
end;

procedure TSerialDeviceFormatTests.NormalizeUsbIdRejectsInvalidValues;
begin
  AssertEquals('', NormalizeUsbId(''));
  AssertEquals('', NormalizeUsbId('0x12345'));
  AssertEquals('', NormalizeUsbId('GGGG'));
  AssertEquals('', NormalizeUsbId('VID_'));
end;

procedure TSerialDeviceFormatTests.FriendlyNameIncludesEveryEnabledField;
var
  DeviceInfo: TSerialDeviceInfo;
  FriendlyName: string;
begin
  DeviceInfo := CreateDevice;
  FriendlyName := FormatSerialDeviceFriendlyName(
    DeviceInfo,
    [sddoVendor, sddoModel, sddoSerialShort, sddoErrorCode]
  );

  AssertTrue(Pos('QinHeng Electronics', FriendlyName) > 0);
  AssertTrue(Pos('USB Single Serial', FriendlyName) > 0);
  AssertTrue(Pos('5ABA019711', FriendlyName) > 0);
  AssertTrue(Pos('12', FriendlyName) > 0);
end;

procedure TSerialDeviceFormatTests.FriendlyNameControlsFieldsIndependently;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;

  AssertEquals(
    'QinHeng Electronics',
    FormatSerialDeviceFriendlyName(DeviceInfo, [sddoVendor])
  );
  AssertEquals(
    'USB Single Serial',
    FormatSerialDeviceFriendlyName(DeviceInfo, [sddoModel])
  );
  AssertEquals(
    '5ABA019711',
    FormatSerialDeviceFriendlyName(DeviceInfo, [sddoSerialShort])
  );
end;

procedure TSerialDeviceFormatTests.FriendlyNameDoesNotRepeatVendorFromModel;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;
  DeviceInfo.Vendor := 'QINHENG ELECTRONICS';
  DeviceInfo.Model := 'QinHeng Electronics USB Single Serial';

  AssertEquals(
    'QinHeng Electronics USB Single Serial',
    FormatSerialDeviceFriendlyName(DeviceInfo, [sddoVendor, sddoModel])
  );
end;

procedure TSerialDeviceFormatTests.FriendlyNameTrimsValuesAndPreservesUnicode;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;
  DeviceInfo.Vendor := '  Эспрессив Системс  ';
  DeviceInfo.Model := '  Тестовый адаптер  ';

  AssertEquals(
    'Эспрессив Системс Тестовый адаптер',
    FormatSerialDeviceFriendlyName(DeviceInfo, [sddoVendor, sddoModel])
  );
end;

procedure TSerialDeviceFormatTests.FriendlyNameSuppressesZeroErrorCode;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;
  DeviceInfo.ErrorCode := '0';
  AssertEquals(
    '',
    FormatSerialDeviceFriendlyName(DeviceInfo, [sddoErrorCode])
  );

  DeviceInfo.ErrorCode := '00';
  AssertEquals(
    '',
    FormatSerialDeviceFriendlyName(DeviceInfo, [sddoErrorCode])
  );
end;

procedure TSerialDeviceFormatTests.EmptyMetadataProducesNoFriendlyName;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := Default(TSerialDeviceInfo);
  DeviceInfo.Device := '/dev/ttyS0';

  AssertEquals('', FormatSerialDeviceFriendlyName(DeviceInfo));
  AssertEquals('/dev/ttyS0', FormatSerialDeviceDisplayName(DeviceInfo));
end;

procedure TSerialDeviceFormatTests.EmptyOptionsHideFriendlyName;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;
  AssertEquals('', FormatSerialDeviceFriendlyName(DeviceInfo, []));
end;

procedure TSerialDeviceFormatTests.DisplayNameWrapsFriendlyName;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;
  DeviceInfo.ErrorCode := '';

  AssertEquals(
    '/dev/ttyACM0 <QinHeng Electronics USB Single Serial 5ABA019711>',
    FormatSerialDeviceDisplayName(DeviceInfo)
  );
end;

procedure TSerialDeviceFormatTests.DisplayNameUsesDeviceWhenFriendlyNameIsEmpty;
var
  DeviceInfo: TSerialDeviceInfo;
begin
  DeviceInfo := CreateDevice;
  AssertEquals(
    '/dev/ttyACM0',
    FormatSerialDeviceDisplayName(DeviceInfo, [])
  );
end;

initialization
  RegisterTest(TSerialDeviceFormatTests);

end.
