unit SerialPlatformCollectorSmokeTests;

{$mode ObjFPC}{$H+}

interface

uses
  FpcUnit, TestRegistry;

type
  TSerialPlatformCollectorSmokeTests = class(TTestCase)
  published
    procedure NativeCollectorReturnsValidSnapshot;
  end;

implementation

uses
  SysUtils, LazSerialDevices;

procedure TSerialPlatformCollectorSmokeTests.NativeCollectorReturnsValidSnapshot;
var
  Devices: TSerialDeviceInfoArray;
  I: Integer;
  J: Integer;
begin
  Devices := GetSerialDevices;

  for I := Low(Devices) to High(Devices) do
  begin
    CheckNotEquals('', Trim(Devices[I].Device),
      'A native collector returned an empty device identifier');
    for J := Low(Devices) to I - 1 do
      {$IFDEF Windows}
      CheckFalse(SameText(Devices[I].Device, Devices[J].Device),
        'A native collector returned a duplicate device identifier');
      {$ELSE}
      CheckFalse(Devices[I].Device = Devices[J].Device,
        'A native collector returned a duplicate device identifier');
      {$ENDIF}
  end;
end;

initialization
  RegisterTest(TSerialPlatformCollectorSmokeTests);

end.
