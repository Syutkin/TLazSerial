unit SerialPlatformChangeSourceSmokeTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, FpcUnit, TestRegistry;

type
  TSerialPlatformChangeSourceSmokeTests = class(TTestCase)
  private
    FChangedCount: Integer;
    FFailedCount: Integer;
    procedure Changed(Sender: TObject);
    procedure Failed(Sender: TObject);
    procedure PumpMessages;
  published
    procedure FactorySourceStartsAndStopsRepeatedly;
  end;

implementation

uses
  Forms, SysUtils, SerialWatcherSupport
  {$IFDEF Linux}
  , SerialLinuxChangeSource
  {$ENDIF}
  {$IFDEF Windows}
  , SerialWindowsChangeSource
  {$ENDIF}
  {$IFDEF Darwin}
  , SerialMacChangeSource
  {$ENDIF};

const
  StartStopCycleCount = 3;
  PostStopPumpCount = 10;

function CreatePlatformChangeSource: TSerialChangeSource;
begin
  {$IFDEF Linux}
  Result := CreateLinuxSerialChangeSource;
  {$ELSE}
  {$IFDEF Windows}
  Result := CreateWindowsSerialChangeSource;
  {$ELSE}
  {$IFDEF Darwin}
  Result := CreateMacSerialChangeSource;
  {$ELSE}
  Result := TSerialPollingChangeSource.Create(1000);
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
end;

procedure TSerialPlatformChangeSourceSmokeTests.Changed(Sender: TObject);
begin
  Inc(FChangedCount);
end;

procedure TSerialPlatformChangeSourceSmokeTests.Failed(Sender: TObject);
begin
  Inc(FFailedCount);
end;

procedure TSerialPlatformChangeSourceSmokeTests.PumpMessages;
var
  I: Integer;
begin
  for I := 1 to PostStopPumpCount do
  begin
    Application.ProcessMessages;
    CheckSynchronize;
    Sleep(10);
  end;
end;

procedure TSerialPlatformChangeSourceSmokeTests.
  FactorySourceStartsAndStopsRepeatedly;
var
  ChangedAfterStop: Integer;
  Cycle: Integer;
  FailedAfterStop: Integer;
  Source: TSerialChangeSource;
begin
  Source := CreatePlatformChangeSource;
  try
    for Cycle := 1 to StartStopCycleCount do
    begin
      Source.Start(@Changed, @Failed);
      CheckTrue(Source.Active, 'The native change source did not start');
      Application.ProcessMessages;

      Source.Stop;
      CheckFalse(Source.Active, 'The native change source did not stop');
      ChangedAfterStop := FChangedCount;
      FailedAfterStop := FFailedCount;
      PumpMessages;
      CheckEquals(ChangedAfterStop, FChangedCount,
        'A changed callback arrived after the native source stopped');
      CheckEquals(FailedAfterStop, FFailedCount,
        'A failure callback arrived after the native source stopped');
    end;
  finally
    Source.Free;
  end;

  ChangedAfterStop := FChangedCount;
  FailedAfterStop := FFailedCount;
  PumpMessages;
  CheckEquals(ChangedAfterStop, FChangedCount,
    'A changed callback arrived after the native source was destroyed');
  CheckEquals(FailedAfterStop, FFailedCount,
    'A failure callback arrived after the native source was destroyed');
end;

initialization
  RegisterTest(TSerialPlatformChangeSourceSmokeTests);

end.
