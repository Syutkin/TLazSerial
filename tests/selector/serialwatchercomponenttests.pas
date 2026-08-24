unit SerialWatcherComponentTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSerialDevices,
  SerialWatcherSupport, SerialCommandRunner, SerialWatcher;

type
  TFakeSerialChangeSource = class(TSerialChangeSource)
  private
    FStartCount: Integer;
    FStopCount: Integer;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  public
    procedure Signal;
    property StartCount: Integer read FStartCount;
    property StopCount: Integer read FStopCount;
  end;

  TFakeSerialRefreshScheduler = class(TSerialRefreshScheduler)
  private
    FCancelCount: Integer;
    FScheduleCount: Integer;
  protected
    procedure DoCancel; override;
    procedure DoSchedule(const ADelayMs: Cardinal); override;
  public
    procedure Fire;
    property CancelCount: Integer read FCancelCount;
    property ScheduleCount: Integer read FScheduleCount;
  end;

  TTestSerialWatcher = class(TSerialWatcher)
  private
    FLoadCount: Integer;
    FSnapshot: TSerialDeviceInfoArray;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    procedure PollNow;
    procedure SetSnapshot(const ADevices: array of TSerialDeviceInfo);
    property LoadCount: Integer read FLoadCount;
  end;

  TBackgroundTestSerialWatcher = class(TSerialWatcher)
  private
    FLoadCount: Integer;
    FLoadStarted: TEvent;
    FReleaseLoad: TEvent;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    property LoadStarted: TEvent read FLoadStarted write FLoadStarted;
    property LoadCount: Integer read FLoadCount;
    property ReleaseLoad: TEvent read FReleaseLoad write FReleaseLoad;
  end;

  TOrchestratedTestSerialWatcher = class(TSerialWatcher)
  private
    FLoadCount: Integer;
    FLoadStarted: TEvent;
    FReleaseLoad: TEvent;
    FSnapshot: TSerialDeviceInfoArray;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    constructor Create(
      AChangeSource: TSerialChangeSource;
      AScheduler: TSerialRefreshScheduler
    ); reintroduce;
    procedure SetSnapshot(const ADevices: array of TSerialDeviceInfo);
    procedure StopNow;
    property LoadCount: Integer read FLoadCount;
    property LoadStarted: TEvent read FLoadStarted write FLoadStarted;
    property ReleaseLoad: TEvent read FReleaseLoad write FReleaseLoad;
  end;

  TCancellableCommandSerialWatcher = class(TSerialWatcher)
  private
    FLoadStarted: TEvent;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    property LoadStarted: TEvent read FLoadStarted write FLoadStarted;
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
    procedure AdoptSnapshotEstablishesBaselineWithoutLoading;
    procedure RefreshLoadsDevicesInBackground;
    procedure RepeatedRefreshDoesNotStartSecondLoad;
    procedure BurstSignalsCoalesceIntoOneRefresh;
    procedure SignalDuringRefreshSchedulesOneFollowUp;
    procedure StopCancelsSignalsAndScheduledRefresh;
    procedure DestroyStopsSourceAndCancelsScheduledRefresh;
    procedure DestroyCancelsHungSystemCommand;
  end;

implementation

procedure TFakeSerialChangeSource.DoStart;
begin
  Inc(FStartCount);
end;

procedure TFakeSerialChangeSource.DoStop;
begin
  Inc(FStopCount);
end;

procedure TFakeSerialChangeSource.Signal;
begin
  Changed;
end;

procedure TFakeSerialRefreshScheduler.DoCancel;
begin
  Inc(FCancelCount);
end;

procedure TFakeSerialRefreshScheduler.DoSchedule(const ADelayMs: Cardinal);
begin
  Inc(FScheduleCount);
end;

procedure TFakeSerialRefreshScheduler.Fire;
begin
  RunScheduled;
end;

constructor TOrchestratedTestSerialWatcher.Create(
  AChangeSource: TSerialChangeSource;
  AScheduler: TSerialRefreshScheduler
);
begin
  inherited Create(nil);
  SetInfrastructure(
    AChangeSource,
    AScheduler,
    False
  );
end;

function TOrchestratedTestSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
var
  I: Integer;
begin
  Inc(FLoadCount);
  if FLoadStarted <> nil then
    FLoadStarted.SetEvent;
  if FReleaseLoad <> nil then
    FReleaseLoad.WaitFor(1000);

  Result := nil;
  SetLength(Result, Length(FSnapshot));
  for I := Low(FSnapshot) to High(FSnapshot) do
    Result[I] := FSnapshot[I];
end;

procedure TOrchestratedTestSerialWatcher.SetSnapshot(
  const ADevices: array of TSerialDeviceInfo
);
var
  I: Integer;
begin
  SetLength(FSnapshot, Length(ADevices));
  for I := Low(ADevices) to High(ADevices) do
    FSnapshot[I] := ADevices[I];
end;

procedure TOrchestratedTestSerialWatcher.StopNow;
begin
  StopWatching;
end;

function TCancellableCommandSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
var
  Output: string;
begin
  if FLoadStarted <> nil then
    FLoadStarted.SetEvent;
  RunSerialCommand('/bin/sleep', ['5'], 30000, Output);
  Result := nil;
end;

function TBackgroundTestSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
begin
  Inc(FLoadCount);
  if FLoadStarted <> nil then
    FLoadStarted.SetEvent;
  if FReleaseLoad <> nil then
    FReleaseLoad.WaitFor(500);
  Result := nil;
  SetLength(Result, 1);
  Result[0].Device := 'COM1';
end;

function TTestSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
var
  I: Integer;
begin
  Inc(FLoadCount);
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

  FWatcher.PollNow;

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
  FWatcher.PollNow;

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
  FWatcher.PollNow;

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
  FWatcher.PollNow;

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
  FWatcher.PollNow;

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
  FWatcher.PollNow;

  AssertTrue(FWatcher.ContainsDevice('/dev/ttyACM0'));
  AssertFalse(FWatcher.ContainsDevice('/dev/ttyUSB0'));
end;

procedure TSerialWatcherComponentTests.AdoptSnapshotEstablishesBaselineWithoutLoading;
var
  DeviceA: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');

  FWatcher.AdoptSnapshot([DeviceA]);

  AssertEquals(0, FWatcher.LoadCount);
  AssertTrue(FWatcher.ContainsDevice(DeviceA.Device));
  AssertEquals(0, FConnectedCount);
  AssertEquals(0, FDisconnectedCount);
end;

procedure TSerialWatcherComponentTests.RefreshLoadsDevicesInBackground;
var
  Deadline: QWord;
  Elapsed: QWord;
  LoadStarted: TEvent;
  ReleaseLoad: TEvent;
  StartedAt: QWord;
  Watcher: TBackgroundTestSerialWatcher;
begin
  LoadStarted := TEvent.Create(nil, True, False, '');
  ReleaseLoad := TEvent.Create(nil, True, False, '');
  Watcher := TBackgroundTestSerialWatcher.Create(nil);
  try
    Watcher.LoadStarted := LoadStarted;
    Watcher.ReleaseLoad := ReleaseLoad;

    StartedAt := GetTickCount64;
    Watcher.Refresh;
    Elapsed := GetTickCount64 - StartedAt;

    AssertTrue('Refresh must not wait for LoadDevices', Elapsed < 100);
    AssertEquals(
      Ord(wrSignaled),
      Ord(LoadStarted.WaitFor(1000))
    );
    ReleaseLoad.SetEvent;

    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until Watcher.ContainsDevice('COM1') or
      (GetTickCount64 >= Deadline);
    AssertTrue(Watcher.ContainsDevice('COM1'));
  finally
    ReleaseLoad.SetEvent;
    Watcher.Free;
    ReleaseLoad.Free;
    LoadStarted.Free;
  end;
end;

procedure TSerialWatcherComponentTests.RepeatedRefreshDoesNotStartSecondLoad;
var
  Deadline: QWord;
  LoadStarted: TEvent;
  ReleaseLoad: TEvent;
  Watcher: TBackgroundTestSerialWatcher;
begin
  LoadStarted := TEvent.Create(nil, True, False, '');
  ReleaseLoad := TEvent.Create(nil, True, False, '');
  Watcher := TBackgroundTestSerialWatcher.Create(nil);
  try
    Watcher.LoadStarted := LoadStarted;
    Watcher.ReleaseLoad := ReleaseLoad;

    Watcher.Refresh;
    AssertEquals(
      Ord(wrSignaled),
      Ord(LoadStarted.WaitFor(1000))
    );
    Watcher.Refresh;

    AssertEquals(1, Watcher.LoadCount);
    ReleaseLoad.SetEvent;
    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until Watcher.ContainsDevice('COM1') or
      (GetTickCount64 >= Deadline);
    AssertTrue(Watcher.ContainsDevice('COM1'));
  finally
    ReleaseLoad.SetEvent;
    Watcher.Free;
    ReleaseLoad.Free;
    LoadStarted.Free;
  end;
end;

procedure TSerialWatcherComponentTests.BurstSignalsCoalesceIntoOneRefresh;
var
  Deadline: QWord;
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
  Scheduler: TFakeSerialRefreshScheduler;
  Source: TFakeSerialChangeSource;
  Watcher: TOrchestratedTestSerialWatcher;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  DeviceB := CreateDevice('/dev/ttyUSB0');
  Source := TFakeSerialChangeSource.Create;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  Watcher := TOrchestratedTestSerialWatcher.Create(Source, Scheduler);
  try
    Watcher.OnComConnected := @DeviceConnected;
    Watcher.AdoptSnapshot([DeviceA]);
    Watcher.SetSnapshot([DeviceA, DeviceB]);
    AssertEquals(1, Source.StartCount);

    Source.Signal;
    Source.Signal;
    Source.Signal;

    AssertTrue('Burst signals must leave one scheduled refresh',
      Scheduler.Scheduled);
    AssertEquals(0, Watcher.LoadCount);
    Scheduler.Fire;

    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until Watcher.ContainsDevice(DeviceB.Device) or
      (GetTickCount64 >= Deadline);
    AssertTrue(Watcher.ContainsDevice(DeviceB.Device));
    AssertEquals(1, Watcher.LoadCount);
    AssertEquals(1, FConnectedCount);
  finally
    Watcher.Free;
    Scheduler.Free;
    Source.Free;
  end;
end;

procedure TSerialWatcherComponentTests.
  SignalDuringRefreshSchedulesOneFollowUp;
var
  Deadline: QWord;
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
  DeviceC: TSerialDeviceInfo;
  LoadStarted: TEvent;
  ReleaseLoad: TEvent;
  Scheduler: TFakeSerialRefreshScheduler;
  Source: TFakeSerialChangeSource;
  Watcher: TOrchestratedTestSerialWatcher;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  DeviceB := CreateDevice('/dev/ttyUSB0');
  DeviceC := CreateDevice('/dev/ttyUSB1');
  LoadStarted := TEvent.Create(nil, True, False, '');
  ReleaseLoad := TEvent.Create(nil, True, False, '');
  Source := TFakeSerialChangeSource.Create;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  Watcher := TOrchestratedTestSerialWatcher.Create(Source, Scheduler);
  try
    Watcher.OnComConnected := @DeviceConnected;
    Watcher.LoadStarted := LoadStarted;
    Watcher.ReleaseLoad := ReleaseLoad;
    Watcher.AdoptSnapshot([DeviceA]);
    Watcher.SetSnapshot([DeviceA, DeviceB]);

    Source.Signal;
    Scheduler.Fire;
    AssertEquals(Ord(wrSignaled), Ord(LoadStarted.WaitFor(1000)));

    Source.Signal;
    Source.Signal;
    AssertFalse(Scheduler.Scheduled);
    AssertEquals(1, Watcher.LoadCount);

    ReleaseLoad.SetEvent;
    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until Scheduler.Scheduled or (GetTickCount64 >= Deadline);
    AssertTrue('Dirty refresh must be scheduled after delivery',
      Scheduler.Scheduled);

    Watcher.SetSnapshot([DeviceA, DeviceB, DeviceC]);
    Scheduler.Fire;
    Deadline := GetTickCount64 + 3000;
    repeat
      CheckSynchronize(10);
      if Scheduler.Scheduled then
        Scheduler.Fire;
    until Watcher.ContainsDevice(DeviceC.Device) or
      (GetTickCount64 >= Deadline);
    AssertTrue(Format(
      'Follow-up refresh must publish the latest snapshot; loads=%d schedules=%d cancels=%d scheduled=%s',
      [Watcher.LoadCount, Scheduler.ScheduleCount, Scheduler.CancelCount,
      BoolToStr(Scheduler.Scheduled, True)]),
      Watcher.ContainsDevice(DeviceC.Device));
    AssertEquals(2, Watcher.LoadCount);
    AssertEquals(2, FConnectedCount);
  finally
    ReleaseLoad.SetEvent;
    Watcher.Free;
    Scheduler.Free;
    Source.Free;
    ReleaseLoad.Free;
    LoadStarted.Free;
  end;
end;

procedure TSerialWatcherComponentTests.StopCancelsSignalsAndScheduledRefresh;
var
  DeviceA: TSerialDeviceInfo;
  Scheduler: TFakeSerialRefreshScheduler;
  Source: TFakeSerialChangeSource;
  Watcher: TOrchestratedTestSerialWatcher;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  Source := TFakeSerialChangeSource.Create;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  Watcher := TOrchestratedTestSerialWatcher.Create(Source, Scheduler);
  try
    Watcher.AdoptSnapshot([DeviceA]);
    Source.Signal;
    AssertTrue(Scheduler.Scheduled);

    Watcher.StopNow;

    AssertEquals(1, Source.StopCount);
    AssertFalse(Scheduler.Scheduled);
    Source.Signal;
    Scheduler.Fire;
    AssertEquals(0, Watcher.LoadCount);
  finally
    Watcher.Free;
    Scheduler.Free;
    Source.Free;
  end;
end;

procedure TSerialWatcherComponentTests.
  DestroyStopsSourceAndCancelsScheduledRefresh;
var
  DeviceA: TSerialDeviceInfo;
  Scheduler: TFakeSerialRefreshScheduler;
  Source: TFakeSerialChangeSource;
  Watcher: TOrchestratedTestSerialWatcher;
begin
  DeviceA := CreateDevice('/dev/ttyACM0');
  Source := TFakeSerialChangeSource.Create;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  Watcher := TOrchestratedTestSerialWatcher.Create(Source, Scheduler);
  Watcher.AdoptSnapshot([DeviceA]);
  Source.Signal;
  AssertTrue(Scheduler.Scheduled);

  Watcher.Free;
  Watcher := nil;

  AssertEquals(1, Source.StopCount);
  AssertFalse(Scheduler.Scheduled);
  Source.Signal;
  Scheduler.Fire;
  AssertEquals(0, FConnectedCount);
  Scheduler.Free;
  Source.Free;
end;

procedure TSerialWatcherComponentTests.DestroyCancelsHungSystemCommand;
{$IFDEF UNIX}
var
  Elapsed: QWord;
  LoadStarted: TEvent;
  StartedAt: QWord;
  Watcher: TCancellableCommandSerialWatcher;
{$ENDIF}
begin
  {$IFDEF UNIX}
  LoadStarted := TEvent.Create(nil, True, False, '');
  Watcher := TCancellableCommandSerialWatcher.Create(nil);
  try
    Watcher.LoadStarted := LoadStarted;
    Watcher.Refresh;
    AssertEquals(Ord(wrSignaled), Ord(LoadStarted.WaitFor(1000)));

    StartedAt := GetTickCount64;
    Watcher.Free;
    Watcher := nil;
    Elapsed := GetTickCount64 - StartedAt;

    AssertTrue(
      'Destroy must cancel a running system metadata command',
      Elapsed < 1000
    );
  finally
    Watcher.Free;
    LoadStarted.Free;
  end;
  {$ENDIF}
end;

initialization
  RegisterTest(TSerialWatcherComponentTests);

end.
