unit SerialWatcherComponentTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, FpcUnit, TestRegistry, LazSerialDevices, SerialWatcher;

type
  TTestSerialWatcher = class(TSerialWatcher)
  private
    FSnapshot: TSerialDeviceInfoArray;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    procedure PollNow;
    procedure SetSnapshot(const ADevices: array of TSerialDeviceInfo);
  end;

  TSerialWatcherComponentTests = class(TTestCase)
  private
    FConnectedCount: Integer;
    FDisconnectedCount: Integer;
    FWatcher: TTestSerialWatcher;
    function CreateDevice(const ADevice: string): TSerialDeviceInfo;
    procedure DeviceConnected(Sender: TObject);
    procedure DeviceDisconnected(Sender: TObject);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure RefreshEstablishesBaselineWithoutEvents;
    procedure PollReportsAddedDevice;
    procedure PollReportsRemovedDevice;
    procedure PollIgnoresOrderAndMetadataChanges;
    procedure PollReportsReplacementAsRemoveAndAdd;
    procedure ContainsDeviceUsesCurrentSnapshot;
  end;

implementation

function TTestSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FSnapshot));
  for I := Low(FSnapshot) to High(FSnapshot) do
    Result[I] := FSnapshot[I];
end;

procedure TTestSerialWatcher.PollNow;
begin
  PollDevices;
end;

procedure TTestSerialWatcher.SetSnapshot(
  const ADevices: array of TSerialDeviceInfo
);
var
  I: Integer;
begin
  SetLength(FSnapshot, Length(ADevices));
  for I := Low(ADevices) to High(ADevices) do
    FSnapshot[I] := ADevices[I];
end;

function TSerialWatcherComponentTests.CreateDevice(
  const ADevice: string
): TSerialDeviceInfo;
begin
  Result := Default(TSerialDeviceInfo);
  Result.Device := ADevice;
end;

procedure TSerialWatcherComponentTests.DeviceConnected(Sender: TObject);
begin
  Inc(FConnectedCount);
end;

procedure TSerialWatcherComponentTests.DeviceDisconnected(Sender: TObject);
begin
  Inc(FDisconnectedCount);
end;

procedure TSerialWatcherComponentTests.SetUp;
begin
  FConnectedCount := 0;
  FDisconnectedCount := 0;
  FWatcher := TTestSerialWatcher.Create(nil);
  FWatcher.OnComConnected := @DeviceConnected;
  FWatcher.OnComDisconnected := @DeviceDisconnected;
end;

procedure TSerialWatcherComponentTests.TearDown;
begin
  FWatcher.Free;
end;

procedure TSerialWatcherComponentTests.RefreshEstablishesBaselineWithoutEvents;
var
  DeviceA: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  FWatcher.SetSnapshot([DeviceA]);

  FWatcher.Refresh;

  AssertEquals(0, FConnectedCount);
  AssertEquals(0, FDisconnectedCount);
  AssertTrue(FWatcher.ContainsDevice(DeviceA.Device));
end;

procedure TSerialWatcherComponentTests.PollReportsAddedDevice;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  DeviceB := CreateDevice('/dev/ttyUSB0');
  FWatcher.SetSnapshot([DeviceA]);
  FWatcher.Refresh;

  FWatcher.SetSnapshot([DeviceA, DeviceB]);
  FWatcher.PollNow;

  AssertEquals(1, FConnectedCount);
  AssertEquals(0, FDisconnectedCount);
end;

procedure TSerialWatcherComponentTests.PollReportsRemovedDevice;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  DeviceB := CreateDevice('/dev/ttyUSB0');
  FWatcher.SetSnapshot([DeviceA, DeviceB]);
  FWatcher.Refresh;

  FWatcher.SetSnapshot([DeviceA]);
  FWatcher.PollNow;

  AssertEquals(0, FConnectedCount);
  AssertEquals(1, FDisconnectedCount);
end;

procedure TSerialWatcherComponentTests.PollIgnoresOrderAndMetadataChanges;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  DeviceB := CreateDevice('/dev/ttyUSB0');
  FWatcher.SetSnapshot([DeviceA, DeviceB]);
  FWatcher.Refresh;

  DeviceA.Model := 'Updated model';
  FWatcher.SetSnapshot([DeviceB, DeviceA]);
  FWatcher.PollNow;

  AssertEquals(0, FConnectedCount);
  AssertEquals(0, FDisconnectedCount);
end;

procedure TSerialWatcherComponentTests.PollReportsReplacementAsRemoveAndAdd;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  DeviceB := CreateDevice('/dev/ttyUSB0');
  FWatcher.SetSnapshot([DeviceA]);
  FWatcher.Refresh;

  FWatcher.SetSnapshot([DeviceB]);
  FWatcher.PollNow;

  AssertEquals(1, FConnectedCount);
  AssertEquals(1, FDisconnectedCount);
end;

procedure TSerialWatcherComponentTests.ContainsDeviceUsesCurrentSnapshot;
var
  DeviceA: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  FWatcher.SetSnapshot([DeviceA]);
  FWatcher.Refresh;

  AssertTrue(FWatcher.ContainsDevice('/dev/ttyACM0'));
  AssertFalse(FWatcher.ContainsDevice('/dev/ttyUSB0'));
end;

initialization
  RegisterTest(TSerialWatcherComponentTests);

end.
