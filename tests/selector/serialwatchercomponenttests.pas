unit SerialWatcherComponentTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSerialDevices,
  SerialWatcherSupport, SerialCommandRunner, SerialWatcher;

type
  TFakeSerialChangeSource = class(TSerialChangeSource)
  private
    FRequiresSettling: Boolean;
    FStartCount: Integer;
    FStopCount: Integer;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
    function GetRequiresSettling: Boolean; override;
  public
    procedure Signal;
    property StartCount: Integer read FStartCount;
    property StopCount: Integer read FStopCount;
    property RequiresSettlingValue: Boolean
      read FRequiresSettling write FRequiresSettling;
  end;

  TFakeSerialRefreshScheduler = class(TSerialRefreshScheduler)
  private
    FCancelCount: Integer;
    FLastDelayMs: Cardinal;
    FScheduleCount: Integer;
  protected
    procedure DoCancel; override;
    procedure DoSchedule(const ADelayMs: Cardinal); override;
  public
    procedure Fire;
    property CancelCount: Integer read FCancelCount;
    property LastDelayMs: Cardinal read FLastDelayMs;
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
    FApplyCount: Integer;
    FLoadCount: Integer;
    FLoadStarted: TEvent;
    FReleaseLoad: TEvent;
    FSnapshot: TSerialDeviceInfoArray;
  protected
    procedure ApplyDevices(
      const ADevices: TSerialDeviceInfoArray
    ); override;
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    constructor Create(
      AChangeSource: TSerialChangeSource;
      AScheduler: TSerialRefreshScheduler
    ); reintroduce;
    procedure ConfigureTiming(
      const AChangeDelayMs: Cardinal;
      const ASettleRetryDelayMs: Cardinal;
      const ASettleRetryCount: Cardinal
    );
    procedure SetSnapshot(const ADevices: array of TSerialDeviceInfo);
    procedure StopNow;
    property ApplyCount: Integer read FApplyCount;
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
    procedure CheckLifetimeInChild(const AMode: string);
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
    procedure NativeSignalUsesBoundedSettlingBackoff;
    procedure ChangedSnapshotStopsSettlingRetries;
    procedure PollingSignalDoesNotStartSettlingRetries;
    procedure SignalDuringRefreshSchedulesOneFollowUp;
    procedure StopCancelsSignalsAndScheduledRefresh;
    procedure DestroyStopsSourceAndCancelsScheduledRefresh;
    procedure DestroyCancelsHungSystemCommand;
    procedure FailedRefreshPreservesLastSnapshot;
    procedure FailedFirstRefreshDoesNotEstablishEmptyBaseline;
    procedure SuccessfulEmptyRefreshReportsRemoval;
    procedure DestroyFromConnectedEventPreservesHeap;
    procedure DestroyFromDisconnectedEventPreservesHeap;
    procedure DestroyDuringReplacementStopsFurtherEvents;
    procedure DestroyOwnerFromEventPreservesHeap;
  end;

procedure RunWatcherLifetimeHelper(const AMode: string);

implementation

type
  TFailingRefreshWatcher = class(TTestSerialWatcher)
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    FailLoad: Boolean;
    LoadStarted: TEvent;
    Worker: TThread;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure RefreshAndWait;
  end;

  TWatcherLifetimeProbe = class
  public
    Watcher: TFailingRefreshWatcher;
    Owner: TComponent;
    CallbackCount: Integer;
    FreeOwner: Boolean;
    procedure DestroyFromEvent(Sender: TObject);
  end;

constructor TFailingRefreshWatcher.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  LoadStarted := TEvent.Create(nil, True, False, '');
  SetInfrastructure(TSerialManualChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;

destructor TFailingRefreshWatcher.Destroy;
begin
  // Stop/join the worker before releasing events used by the loader.
  StopWatching;
  LoadStarted.Free;
  inherited Destroy;
end;

function TFailingRefreshWatcher.LoadDevices: TSerialDeviceInfoArray;
begin
  Worker := TThread.CurrentThread;
  LoadStarted.SetEvent;
  if FailLoad then
    raise EInvalidOperation.Create('Simulated device enumeration failure');
  Result := inherited LoadDevices;
end;

procedure TFailingRefreshWatcher.RefreshAndWait;
var
  Deadline: QWord;
begin
  LoadStarted.ResetEvent;
  Refresh;
  if LoadStarted.WaitFor(1000) <> wrSignaled then
    raise Exception.Create('Device refresh did not start');
  Deadline := GetTickCount64 + 1000;
  // Do not pump callbacks until Queue has completed and the worker has exited.
  while not Worker.Finished and (GetTickCount64 < Deadline) do
    Sleep(1);
  if not Worker.Finished then
    raise Exception.Create('Device refresh did not finish');
  CheckSynchronize(0);
end;

procedure TWatcherLifetimeProbe.DestroyFromEvent(Sender: TObject);
var
  ToFree: TFailingRefreshWatcher;
begin
  Inc(CallbackCount);
  if CallbackCount > 1 then
    raise Exception.Create('Callback after watcher destruction');
  ToFree := Watcher;
  Watcher := nil;
  if FreeOwner then
    FreeAndNil(Owner)
  else
    ToFree.Free;
end;

procedure RunWatcherLifetimeHelper(const AMode: string);
var
  DeviceA, DeviceB: TSerialDeviceInfo;
  Probe: TWatcherLifetimeProbe;
begin
  Probe := TWatcherLifetimeProbe.Create;
  try
    Probe.Owner := TComponent.Create(nil);
    Probe.Watcher := TFailingRefreshWatcher.Create(Probe.Owner);
    DeviceA := Default(TSerialDeviceInfo);
    DeviceA.Device := '/dev/audit-a';
    DeviceB := Default(TSerialDeviceInfo);
    DeviceB.Device := '/dev/audit-b';
    Probe.Watcher.OnComConnected := @Probe.DestroyFromEvent;
    Probe.Watcher.OnComDisconnected := @Probe.DestroyFromEvent;
    Probe.FreeOwner := AMode = 'owner';
    if AMode = 'connect' then
    begin
      Probe.Watcher.AdoptSnapshot(nil);
      Probe.Watcher.SetSnapshot([DeviceA]);
    end
    else
    begin
      Probe.Watcher.AdoptSnapshot([DeviceA]);
      if AMode = 'replace' then
        Probe.Watcher.SetSnapshot([DeviceB])
      else
        Probe.Watcher.SetSnapshot([]);
    end;
    Probe.Watcher.RefreshAndWait;
    CheckSynchronize(0);
    if (Probe.Watcher <> nil) or (Probe.CallbackCount <> 1) then
      raise Exception.Create('Lifetime callback was not exercised');
    WriteLn('watcher lifetime helper completed');
  finally
    Probe.Watcher.Free;
    Probe.Owner.Free;
    Probe.Free;
  end;
end;

procedure TSerialWatcherComponentTests.CheckLifetimeInChild(const AMode: string);
var
  Output: string;
  Success: Boolean;
begin
  Success := RunSerialCommand(ExpandFileName(ParamStr(0)),
    ['--watcher-lifetime-helper', AMode], 5000, Output);
  AssertTrue('Watcher lifetime helper failed: ' + Output, Success);
  AssertTrue('Lifetime callback must execute: ' + Output,
    Pos('watcher lifetime helper completed', Output) > 0);
  AssertEquals('HeapTrc detected use after free: ' + Output, 0,
    Pos('marked memory', LowerCase(Output)));
end;

procedure TSerialWatcherComponentTests.DestroyFromConnectedEventPreservesHeap;
begin
  CheckLifetimeInChild('connect');
end;

procedure TSerialWatcherComponentTests.DestroyFromDisconnectedEventPreservesHeap;
begin
  CheckLifetimeInChild('disconnect');
end;

procedure TSerialWatcherComponentTests.DestroyDuringReplacementStopsFurtherEvents;
begin
  CheckLifetimeInChild('replace');
end;

procedure TSerialWatcherComponentTests.DestroyOwnerFromEventPreservesHeap;
begin
  CheckLifetimeInChild('owner');
end;

procedure TSerialWatcherComponentTests.FailedRefreshPreservesLastSnapshot;
var
  DeviceA: TSerialDeviceInfo;
  Watcher: TFailingRefreshWatcher;
begin
  Watcher := TFailingRefreshWatcher.Create(nil);
  try
    DeviceA := CreateDevice('/dev/audit-a');
    Watcher.AdoptSnapshot([DeviceA]);
    Watcher.OnComDisconnected := @DeviceDisconnected;
    Watcher.OnComConnected := @DeviceConnected;
    Watcher.FailLoad := True;
    Watcher.RefreshAndWait;
    AssertEquals('Enumeration failure must not report device removal',
      0, FDisconnectedCount);
    AssertEquals(0, FConnectedCount);
    AssertTrue(Watcher.ContainsDevice(DeviceA.Device));
    Watcher.FailLoad := False;
    Watcher.SetSnapshot([DeviceA]);
    Watcher.RefreshAndWait;
    AssertEquals('Recovery must not synthesize reconnection', 0, FConnectedCount);
  finally
    Watcher.Free;
  end;
end;

procedure TSerialWatcherComponentTests.FailedFirstRefreshDoesNotEstablishEmptyBaseline;
var
  DeviceA: TSerialDeviceInfo;
  Watcher: TFailingRefreshWatcher;
begin
  Watcher := TFailingRefreshWatcher.Create(nil);
  try
    Watcher.OnComConnected := @DeviceConnected;
    Watcher.FailLoad := True;
    Watcher.RefreshAndWait;
    Watcher.FailLoad := False;
    DeviceA := CreateDevice('/dev/audit-a');
    Watcher.SetSnapshot([DeviceA]);
    Watcher.RefreshAndWait;
    AssertTrue(Watcher.ContainsDevice(DeviceA.Device));
    AssertEquals('First successful snapshot establishes the baseline',
      0, FConnectedCount);
  finally
    Watcher.Free;
  end;
end;

procedure TSerialWatcherComponentTests.SuccessfulEmptyRefreshReportsRemoval;
var
  DeviceA: TSerialDeviceInfo;
  Watcher: TFailingRefreshWatcher;
begin
  Watcher := TFailingRefreshWatcher.Create(nil);
  try
    DeviceA := CreateDevice('/dev/audit-a');
    Watcher.AdoptSnapshot([DeviceA]);
    Watcher.OnComDisconnected := @DeviceDisconnected;
    Watcher.SetSnapshot([]);
    Watcher.RefreshAndWait;
    AssertEquals(1, FDisconnectedCount);
    AssertFalse(Watcher.ContainsDevice(DeviceA.Device));
  finally
    Watcher.Free;
  end;
end;

procedure TFakeSerialChangeSource.DoStart;
begin
  Inc(FStartCount);
end;

procedure TFakeSerialChangeSource.DoStop;
begin
  Inc(FStopCount);
end;

function TFakeSerialChangeSource.GetRequiresSettling: Boolean;
begin
  Result := FRequiresSettling;
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
  FLastDelayMs := ADelayMs;
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

procedure TOrchestratedTestSerialWatcher.ConfigureTiming(
  const AChangeDelayMs: Cardinal;
  const ASettleRetryDelayMs: Cardinal;
  const ASettleRetryCount: Cardinal
);
begin
  ConfigureChangeTiming(
    AChangeDelayMs,
    ASettleRetryDelayMs,
    ASettleRetryCount
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

procedure TOrchestratedTestSerialWatcher.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray
);
begin
  inherited ApplyDevices(ADevices);
  Inc(FApplyCount);
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

procedure RunOrchestratedRefresh(
  AWatcher: TOrchestratedTestSerialWatcher;
  AScheduler: TFakeSerialRefreshScheduler;
  const AExpectedApplyCount: Integer
);
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 1000;
  repeat
    if AScheduler.Scheduled then
      AScheduler.Fire;
    CheckSynchronize(10);
  until (AWatcher.ApplyCount >= AExpectedApplyCount) or
    (GetTickCount64 >= Deadline);
end;

procedure TSerialWatcherComponentTests.NativeSignalUsesBoundedSettlingBackoff;
var
  DeviceA: TSerialDeviceInfo;
  Scheduler: TFakeSerialRefreshScheduler;
  Source: TFakeSerialChangeSource;
  Watcher: TOrchestratedTestSerialWatcher;
begin
  DeviceA := CreateDevice('COM1');
  Source := TFakeSerialChangeSource.Create;
  Source.RequiresSettlingValue := True;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  Watcher := TOrchestratedTestSerialWatcher.Create(Source, Scheduler);
  try
    Watcher.ConfigureTiming(150, 250, 3);
    Watcher.AdoptSnapshot([DeviceA]);
    Watcher.SetSnapshot([DeviceA]);

    Source.Signal;
    AssertEquals(150, Scheduler.LastDelayMs);

    RunOrchestratedRefresh(Watcher, Scheduler, 1);
    AssertEquals(1, Watcher.LoadCount);
    AssertTrue(Scheduler.Scheduled);
    AssertEquals(250, Scheduler.LastDelayMs);

    RunOrchestratedRefresh(Watcher, Scheduler, 2);
    AssertTrue(Scheduler.Scheduled);
    AssertEquals(500, Scheduler.LastDelayMs);

    RunOrchestratedRefresh(Watcher, Scheduler, 3);
    AssertTrue(Scheduler.Scheduled);
    AssertEquals(1000, Scheduler.LastDelayMs);

    RunOrchestratedRefresh(Watcher, Scheduler, 4);
    AssertEquals(4, Watcher.LoadCount);
    AssertFalse(Scheduler.Scheduled);
  finally
    Watcher.Free;
    Scheduler.Free;
    Source.Free;
  end;
end;

procedure TSerialWatcherComponentTests.ChangedSnapshotStopsSettlingRetries;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
  Scheduler: TFakeSerialRefreshScheduler;
  Source: TFakeSerialChangeSource;
  Watcher: TOrchestratedTestSerialWatcher;
begin
  DeviceA := CreateDevice('COM1');
  DeviceB := CreateDevice('COM2');
  Source := TFakeSerialChangeSource.Create;
  Source.RequiresSettlingValue := True;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  Watcher := TOrchestratedTestSerialWatcher.Create(Source, Scheduler);
  try
    Watcher.ConfigureTiming(150, 250, 3);
    Watcher.AdoptSnapshot([DeviceA]);
    Watcher.SetSnapshot([DeviceA, DeviceB]);

    Source.Signal;
    RunOrchestratedRefresh(Watcher, Scheduler, 1);

    AssertTrue(Watcher.ContainsDevice(DeviceB.Device));
    AssertFalse(Scheduler.Scheduled);
  finally
    Watcher.Free;
    Scheduler.Free;
    Source.Free;
  end;
end;

procedure TSerialWatcherComponentTests.PollingSignalDoesNotStartSettlingRetries;
var
  DeviceA: TSerialDeviceInfo;
  Scheduler: TFakeSerialRefreshScheduler;
  Source: TFakeSerialChangeSource;
  Watcher: TOrchestratedTestSerialWatcher;
begin
  DeviceA := CreateDevice('COM1');
  Source := TFakeSerialChangeSource.Create;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  Watcher := TOrchestratedTestSerialWatcher.Create(Source, Scheduler);
  try
    Watcher.ConfigureTiming(150, 250, 3);
    Watcher.AdoptSnapshot([DeviceA]);
    Watcher.SetSnapshot([DeviceA]);

    Source.Signal;
    RunOrchestratedRefresh(Watcher, Scheduler, 1);

    AssertEquals(1, Watcher.LoadCount);
    AssertFalse(Scheduler.Scheduled);
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
