unit SerialDeviceFilterTests;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, FpcUnit, TestRegistry, LazSerialDevices;

type
  TSerialDeviceFilterTests = class(TTestCase)
  private
    FDevice: TSerialDeviceInfo;
    FFilter: TSerialDeviceFilter;
  protected
    procedure SetUp; override;
  published
    procedure EmptyFilterMatchesDevicesWithoutMetadata;
    procedure EachCriterionWorksIndependently;
    procedure AllSpecifiedCriteriaMustMatch;
    procedure UsbIdsNormalizeBothSides;
    procedure InvalidSpecifiedUsbIdsNeverMatch;
    procedure MissingAndInvalidUsbMetadataNeverMatch;
    procedure MissingTextMetadataNeverMatches;
    procedure SerialNumberMatchesExactly;
    procedure PersistentIdUsesPlatformCaseRules;
    procedure PersistentIdMatchesWholeValue;
    procedure DeviceRenameDoesNotAffectMatching;
    procedure EmptySnapshotAndNoMatchesReturnEmpty;
    procedure FilterKeepsAllMatchesInSnapshotOrder;
    procedure FilterPreservesAllMetadata;
    procedure ResultsAreIndependentOfSource;
    procedure FilterAgreesWithIndividualMatches;
  end;

implementation

procedure TSerialDeviceFilterTests.SetUp;
begin
  inherited SetUp;
  FDevice := Default(TSerialDeviceInfo);
  FDevice.Device := '/dev/ttyACM0';
  FDevice.Vendor := 'Vendor';
  FDevice.Model := 'USB Serial';
  FDevice.VendorId := '0403';
  FDevice.ProductId := '6001';
  FDevice.SerialShort := 'Adapter-Ab12';
  FDevice.PersistentId := 'USB\VID_0403&PID_6001\Adapter-Ab12';
  FDevice.ErrorCode := '5';
  FFilter := Default(TSerialDeviceFilter);
end;

procedure TSerialDeviceFilterTests.EmptyFilterMatchesDevicesWithoutMetadata;
var
  Devices, Matches: TSerialDeviceInfoArray;
begin
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FDevice := Default(TSerialDeviceInfo);
  FDevice.Device := '/dev/ttyS0';
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  SetLength(Devices, 1);
  Devices[0] := FDevice;
  Matches := FilterSerialDevices(Devices, FFilter);
  AssertEquals(1, Length(Matches));
  AssertEquals('/dev/ttyS0', Matches[0].Device);
end;

procedure TSerialDeviceFilterTests.EachCriterionWorksIndependently;
begin
  FFilter.VendorId := FDevice.VendorId;
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FFilter := Default(TSerialDeviceFilter);
  FFilter.ProductId := FDevice.ProductId;
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FFilter := Default(TSerialDeviceFilter);
  FFilter.SerialShort := FDevice.SerialShort;
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FFilter := Default(TSerialDeviceFilter);
  FFilter.PersistentId := FDevice.PersistentId;
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
end;

procedure TSerialDeviceFilterTests.AllSpecifiedCriteriaMustMatch;
begin
  FFilter.VendorId := FDevice.VendorId;
  FFilter.ProductId := FDevice.ProductId;
  FFilter.SerialShort := FDevice.SerialShort;
  FFilter.PersistentId := FDevice.PersistentId;
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FFilter.VendorId := '1234';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter.VendorId := FDevice.VendorId;
  FFilter.ProductId := '1234';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter.ProductId := FDevice.ProductId;
  FFilter.SerialShort := 'other';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter.SerialShort := FDevice.SerialShort;
  FFilter.PersistentId := 'other';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
end;

procedure TSerialDeviceFilterTests.UsbIdsNormalizeBothSides;
begin
  FDevice.VendorId := ' VID_1A86 ';
  FDevice.ProductId := ' PID_000A ';
  FFilter.VendorId := '0x1a86';
  FFilter.ProductId := 'a';
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FDevice.VendorId := '0x0403';
  FDevice.ProductId := 'a';
  FFilter.VendorId := '403';
  FFilter.ProductId := '0X000A';
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FDevice.VendorId := '0000';
  FFilter.VendorId := '0';
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
end;

procedure TSerialDeviceFilterTests.InvalidSpecifiedUsbIdsNeverMatch;
const
  InvalidIds: array[0..5] of string = (
    ' ', 'VID_', '0x', '12345', 'GGGG', '0403*'
  );
var
  I: Integer;
begin
  for I := Low(InvalidIds) to High(InvalidIds) do
  begin
    FFilter := Default(TSerialDeviceFilter);
    FFilter.VendorId := InvalidIds[I];
    AssertFalse(InvalidIds[I], MatchesSerialDevice(FDevice, FFilter));
    FDevice.VendorId := InvalidIds[I];
    AssertFalse('Identical invalid VID', MatchesSerialDevice(FDevice, FFilter));
    FFilter := Default(TSerialDeviceFilter);
    FFilter.ProductId := InvalidIds[I];
    AssertFalse(InvalidIds[I], MatchesSerialDevice(FDevice, FFilter));
    FDevice.ProductId := InvalidIds[I];
    AssertFalse('Identical invalid PID', MatchesSerialDevice(FDevice, FFilter));
  end;
end;

procedure TSerialDeviceFilterTests.MissingAndInvalidUsbMetadataNeverMatch;
begin
  FFilter.VendorId := '0403';
  FDevice.VendorId := '';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FDevice.VendorId := 'GGGG';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter := Default(TSerialDeviceFilter);
  FFilter.ProductId := '6001';
  FDevice.ProductId := '';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FDevice.ProductId := 'GGGG';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
end;

procedure TSerialDeviceFilterTests.MissingTextMetadataNeverMatches;
begin
  FFilter.SerialShort := FDevice.SerialShort;
  FDevice.SerialShort := '';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter := Default(TSerialDeviceFilter);
  FFilter.PersistentId := FDevice.PersistentId;
  FDevice.PersistentId := '';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
end;

procedure TSerialDeviceFilterTests.SerialNumberMatchesExactly;
begin
  FFilter.SerialShort := FDevice.SerialShort;
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FFilter.SerialShort := LowerCase(FDevice.SerialShort);
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter.SerialShort := ' ' + FDevice.SerialShort;
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter.SerialShort := 'Adapter-*';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
end;

procedure TSerialDeviceFilterTests.PersistentIdUsesPlatformCaseRules;
begin
  FFilter.PersistentId := LowerCase(FDevice.PersistentId);
  {$IFDEF Windows}
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  {$ELSE}
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  {$ENDIF}
end;

procedure TSerialDeviceFilterTests.PersistentIdMatchesWholeValue;
begin
  FFilter.PersistentId := FDevice.PersistentId;
  AssertTrue(MatchesSerialDevice(FDevice, FFilter));
  FFilter.PersistentId := ' ' + FDevice.PersistentId;
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
  FFilter.PersistentId := Copy(FDevice.PersistentId, 1, 10) + '*';
  AssertFalse(MatchesSerialDevice(FDevice, FFilter));
end;

procedure TSerialDeviceFilterTests.DeviceRenameDoesNotAffectMatching;
var
  Devices, Matches: TSerialDeviceInfoArray;
begin
  SetLength(Devices, 1);
  Devices[0] := FDevice;
  Devices[0].Device := '/dev/ttyACM7';
  FFilter.VendorId := FDevice.VendorId;
  FFilter.ProductId := FDevice.ProductId;
  FFilter.SerialShort := FDevice.SerialShort;
  FFilter.PersistentId := FDevice.PersistentId;
  Matches := FilterSerialDevices(Devices, FFilter);
  AssertEquals(1, Length(Matches));
  AssertEquals('/dev/ttyACM7', Matches[0].Device);
end;

procedure TSerialDeviceFilterTests.EmptySnapshotAndNoMatchesReturnEmpty;
var
  Devices, Matches: TSerialDeviceInfoArray;
begin
  Devices := nil;
  Matches := FilterSerialDevices(Devices, FFilter);
  AssertEquals(0, Length(Matches));
  SetLength(Devices, 1);
  Devices[0] := FDevice;
  FFilter.SerialShort := 'missing';
  Matches := FilterSerialDevices(Devices, FFilter);
  AssertEquals(0, Length(Matches));
end;

procedure TSerialDeviceFilterTests.FilterKeepsAllMatchesInSnapshotOrder;
var
  Devices, Matches: TSerialDeviceInfoArray;
  I: Integer;
begin
  SetLength(Devices, 5);
  for I := 0 to High(Devices) do
  begin
    Devices[I] := FDevice;
    Devices[I].Device := 'port' + IntToStr(I);
  end;
  Devices[1].VendorId := '1234';
  Devices[3].ProductId := '1234';
  // Identical serial numbers and PersistentIds must not hide ambiguity.
  FFilter.VendorId := FDevice.VendorId;
  FFilter.ProductId := FDevice.ProductId;
  Matches := FilterSerialDevices(Devices, FFilter);
  AssertEquals(3, Length(Matches));
  AssertEquals('port0', Matches[0].Device);
  AssertEquals('port2', Matches[1].Device);
  AssertEquals('port4', Matches[2].Device);
end;

procedure TSerialDeviceFilterTests.FilterPreservesAllMetadata;
var
  Devices, Matches: TSerialDeviceInfoArray;
begin
  SetLength(Devices, 1);
  Devices[0] := FDevice;
  FFilter.SerialShort := FDevice.SerialShort;
  Matches := FilterSerialDevices(Devices, FFilter);
  AssertEquals(1, Length(Matches));
  AssertEquals(FDevice.Device, Matches[0].Device);
  AssertEquals(FDevice.Vendor, Matches[0].Vendor);
  AssertEquals(FDevice.Model, Matches[0].Model);
  AssertEquals(FDevice.VendorId, Matches[0].VendorId);
  AssertEquals(FDevice.ProductId, Matches[0].ProductId);
  AssertEquals(FDevice.SerialShort, Matches[0].SerialShort);
  AssertEquals(FDevice.PersistentId, Matches[0].PersistentId);
  AssertEquals(FDevice.ErrorCode, Matches[0].ErrorCode);
end;

procedure TSerialDeviceFilterTests.ResultsAreIndependentOfSource;
var
  Devices, Matches: TSerialDeviceInfoArray;
begin
  SetLength(Devices, 1);
  Devices[0] := FDevice;
  Matches := FilterSerialDevices(Devices, FFilter);
  AssertEquals(1, Length(Matches));
  Matches[0].SerialShort := 'changed result';
  AssertEquals(FDevice.SerialShort, Devices[0].SerialShort);
  Devices[0].Device := 'changed source';
  AssertEquals(FDevice.Device, Matches[0].Device);
  // Also safe when the caller replaces its own snapshot with the result.
  Devices := FilterSerialDevices(Devices, FFilter);
  AssertEquals(1, Length(Devices));
  AssertEquals('changed source', Devices[0].Device);
end;

procedure TSerialDeviceFilterTests.FilterAgreesWithIndividualMatches;
var
  Devices, Matches: TSerialDeviceInfoArray;
  I, ExpectedCount: Integer;
begin
  SetLength(Devices, 4);
  Devices[0] := FDevice;
  Devices[1] := FDevice;
  Devices[1].SerialShort := 'other';
  Devices[2] := FDevice;
  Devices[2].VendorId := 'bad';
  Devices[3].Device := 'without metadata';
  FFilter.VendorId := FDevice.VendorId;
  FFilter.SerialShort := FDevice.SerialShort;
  Matches := FilterSerialDevices(Devices, FFilter);
  ExpectedCount := 0;
  for I := 0 to High(Devices) do
    if MatchesSerialDevice(Devices[I], FFilter) then
    begin
      AssertTrue(ExpectedCount < Length(Matches));
      AssertEquals(Devices[I].Device, Matches[ExpectedCount].Device);
      Inc(ExpectedCount);
    end;
  AssertEquals(1, ExpectedCount);
  AssertEquals(ExpectedCount, Length(Matches));
end;

initialization
  RegisterTest(TSerialDeviceFilterTests);

end.
