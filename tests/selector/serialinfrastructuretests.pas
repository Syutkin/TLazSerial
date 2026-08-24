unit SerialInfrastructureTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SyncObjs, FpcUnit, TestRegistry, LazSerialDevices,
  SerialDeviceRefresh, SerialWatcherSupport;

type
  TRefreshProbe = class
  private
    FCallbackThreadId: TThreadID;
    FDeliveredCount: Integer;
    FDeliveredDevices: TSerialDeviceInfoArray;
    FFinishedCount: Integer;
    FLoadCompleted: TEvent;
    FLoadDelayMs: Cardinal;
    FLoadStarted: TEvent;
    FOrder: string;
    FRaiseOnLoad: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function LoadDevices: TSerialDeviceInfoArray;
    procedure DevicesLoaded(const ADevices: TSerialDeviceInfoArray);
    procedure Finished;
    property CallbackThreadId: TThreadID read FCallbackThreadId;
    property DeliveredCount: Integer read FDeliveredCount;
    property DeliveredDevices: TSerialDeviceInfoArray read FDeliveredDevices;
    property FinishedCount: Integer read FFinishedCount;
    property LoadCompleted: TEvent read FLoadCompleted;
    property LoadDelayMs: Cardinal read FLoadDelayMs write FLoadDelayMs;
    property LoadStarted: TEvent read FLoadStarted;
    property Order: string read FOrder;
    property RaiseOnLoad: Boolean read FRaiseOnLoad write FRaiseOnLoad;
  end;

  TTestChangeSource = class(TSerialChangeSource)
  private
    FFailOnStart: Boolean;
    FRequiresSettling: Boolean;
    FStartCount: Integer;
    FStopCount: Integer;
    FStopCounter: PInteger;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
    function GetRequiresSettling: Boolean; override;
  public
    procedure SignalChanged;
    procedure SignalFailed;
    property FailOnStart: Boolean read FFailOnStart write FFailOnStart;
    property RequiresSettlingValue: Boolean
      read FRequiresSettling write FRequiresSettling;
    property StartCount: Integer read FStartCount;
    property StopCount: Integer read FStopCount;
    property StopCounter: PInteger read FStopCounter write FStopCounter;
  end;

  TTestRefreshScheduler = class(TSerialRefreshScheduler)
  private
    FCancelCount: Integer;
    FFailOnSchedule: Boolean;
    FLastDelayMs: Cardinal;
    FScheduleCount: Integer;
  protected
    procedure DoCancel; override;
    procedure DoSchedule(const ADelayMs: Cardinal); override;
  public
    procedure Fire;
    property CancelCount: Integer read FCancelCount;
    property FailOnSchedule: Boolean read FFailOnSchedule write FFailOnSchedule;
    property LastDelayMs: Cardinal read FLastDelayMs;
    property ScheduleCount: Integer read FScheduleCount;
  end;

  TInfrastructureObserver = class
  private
    FChangedCount: Integer;
    FFailedCount: Integer;
    FFirstCount: Integer;
    FSecondCount: Integer;
  public
    procedure Changed(Sender: TObject);
    procedure Failed(Sender: TObject);
    procedure First(Sender: TObject);
    procedure Second(Sender: TObject);
    property ChangedCount: Integer read FChangedCount;
    property FailedCount: Integer read FFailedCount;
    property FirstCount: Integer read FFirstCount;
    property SecondCount: Integer read FSecondCount;
  end;

  TSerialInfrastructureTests = class(TTestCase)
  private
    procedure PumpEventsUntil(
      const ACondition: PBoolean;
      const ATimeoutMs: Cardinal
    );
  published
    procedure RefreshDeliversSnapshotOnMainThreadInOrder;
    procedure RefreshLoaderExceptionDeliversEmptySnapshot;
    procedure RefreshCanBeCancelledBeforeStart;
    procedure RefreshCanBeCancelledDuringLoad;
    procedure RefreshDetachCallbacksSuppressesDelivery;
    procedure RefreshCancellationSuppressesQueuedDelivery;
    procedure RefreshNilCancellationIsIdempotent;
    procedure ChangeSourceStartStopIsIdempotent;
    procedure ChangeSourceRollsBackFailedStart;
    procedure ChangeSourceClearsCallbacksOnStopAndDestroy;
    procedure FallbackRejectsNilAndEmptyCandidates;
    procedure FallbackSkipsMultipleStartFailures;
    procedure FallbackReportsRuntimeExhaustion;
    procedure FallbackDelegatesSettlingAndIgnoresStaleSignals;
    procedure SchedulerReplacementRunsOnlyLatestCallback;
    procedure SchedulerCancelAndFailureSuppressCallbacks;
    procedure RealTimerSchedulerAndPollingSourceUseEventLoop;
  end;

implementation

uses
  Forms, SysUtils;

constructor TRefreshProbe.Create;
begin
  inherited Create;
  FLoadCompleted := TEvent.Create(nil, True, False, '');
  FLoadStarted := TEvent.Create(nil, True, False, '');
end;

destructor TRefreshProbe.Destroy;
begin
  FLoadStarted.Free;
  FLoadCompleted.Free;
  inherited Destroy;
end;

function TRefreshProbe.LoadDevices: TSerialDeviceInfoArray;
begin
  FLoadStarted.SetEvent;
  if FLoadDelayMs > 0 then
    Sleep(FLoadDelayMs);
  try
    if FRaiseOnLoad then
      raise EInvalidOperation.Create('Simulated loader failure');
    Result := nil;
    SetLength(Result, 1);
    Result[0].Device := 'COM42';
  finally
    FLoadCompleted.SetEvent;
  end;
end;

procedure TRefreshProbe.DevicesLoaded(
  const ADevices: TSerialDeviceInfoArray
);
var
  I: Integer;
begin
  Inc(FDeliveredCount);
  FCallbackThreadId := GetCurrentThreadID;
  FOrder := FOrder + 'L';
  SetLength(FDeliveredDevices, Length(ADevices));
  for I := Low(ADevices) to High(ADevices) do
    FDeliveredDevices[I] := ADevices[I];
end;

procedure TRefreshProbe.Finished;
begin
  Inc(FFinishedCount);
  FOrder := FOrder + 'F';
end;

procedure TTestChangeSource.DoStart;
begin
  Inc(FStartCount);
  if FFailOnStart then
    raise EInvalidOperation.Create('Simulated source start failure');
end;

procedure TTestChangeSource.DoStop;
begin
  Inc(FStopCount);
  if FStopCounter <> nil then
    Inc(FStopCounter^);
end;

function TTestChangeSource.GetRequiresSettling: Boolean;
begin
  Result := FRequiresSettling;
end;

procedure TTestChangeSource.SignalChanged;
begin
  Changed;
end;

procedure TTestChangeSource.SignalFailed;
begin
  Failed;
end;

procedure TTestRefreshScheduler.DoCancel;
begin
  Inc(FCancelCount);
end;

procedure TTestRefreshScheduler.DoSchedule(const ADelayMs: Cardinal);
begin
  Inc(FScheduleCount);
  FLastDelayMs := ADelayMs;
  if FFailOnSchedule then
    raise EInvalidOperation.Create('Simulated schedule failure');
end;

procedure TTestRefreshScheduler.Fire;
begin
  RunScheduled;
end;

procedure TInfrastructureObserver.Changed(Sender: TObject);
begin
  Inc(FChangedCount);
end;

procedure TInfrastructureObserver.Failed(Sender: TObject);
begin
  Inc(FFailedCount);
end;

procedure TInfrastructureObserver.First(Sender: TObject);
begin
  Inc(FFirstCount);
end;

procedure TInfrastructureObserver.Second(Sender: TObject);
begin
  Inc(FSecondCount);
end;

procedure TSerialInfrastructureTests.PumpEventsUntil(
  const ACondition: PBoolean;
  const ATimeoutMs: Cardinal
);
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    Application.ProcessMessages;
    CheckSynchronize(0);
    if (ACondition <> nil) and ACondition^ then
      Exit;
    Sleep(1);
  until GetTickCount64 >= Deadline;
end;

procedure TSerialInfrastructureTests.
  RefreshDeliversSnapshotOnMainThreadInOrder;
var
  Probe: TRefreshProbe;
  Refresh: TSerialDeviceRefreshThread;
begin
  Probe := TRefreshProbe.Create;
  Refresh := TSerialDeviceRefreshThread.Create(
    @Probe.LoadDevices,
    @Probe.DevicesLoaded,
    @Probe.Finished
  );
  try
    Refresh.Start;
    while (Probe.FinishedCount = 0) and not Refresh.Finished do
      PumpEventsUntil(nil, 10);
    PumpEventsUntil(nil, 10);

    AssertEquals(1, Probe.DeliveredCount);
    AssertEquals(1, Probe.FinishedCount);
    AssertEquals('LF', Probe.Order);
    AssertEquals(1, Length(Probe.DeliveredDevices));
    AssertEquals('COM42', Probe.DeliveredDevices[0].Device);
    AssertTrue(Probe.CallbackThreadId = MainThreadID);
    AssertTrue(Refresh.LoadSucceeded);
  finally
    CancelSerialDeviceRefresh(Refresh);
    Probe.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  RefreshLoaderExceptionDeliversEmptySnapshot;
var
  Probe: TRefreshProbe;
  Refresh: TSerialDeviceRefreshThread;
begin
  Probe := TRefreshProbe.Create;
  Probe.RaiseOnLoad := True;
  Refresh := TSerialDeviceRefreshThread.Create(
    @Probe.LoadDevices,
    @Probe.DevicesLoaded,
    @Probe.Finished
  );
  try
    Refresh.Start;
    while (Probe.FinishedCount = 0) and not Refresh.Finished do
      PumpEventsUntil(nil, 10);
    PumpEventsUntil(nil, 10);

    AssertEquals(1, Probe.DeliveredCount);
    AssertEquals(0, Length(Probe.DeliveredDevices));
    AssertEquals(1, Probe.FinishedCount);
    AssertFalse(Refresh.LoadSucceeded);
  finally
    CancelSerialDeviceRefresh(Refresh);
    Probe.Free;
  end;
end;

procedure TSerialInfrastructureTests.RefreshCanBeCancelledBeforeStart;
var
  Probe: TRefreshProbe;
  Refresh: TSerialDeviceRefreshThread;
begin
  Probe := TRefreshProbe.Create;
  Refresh := TSerialDeviceRefreshThread.Create(
    @Probe.LoadDevices,
    @Probe.DevicesLoaded,
    @Probe.Finished
  );
  try
    CancelSerialDeviceRefresh(Refresh);
    AssertNull(Refresh);
    AssertEquals(0, Probe.DeliveredCount);
    AssertEquals(0, Probe.FinishedCount);
  finally
    CancelSerialDeviceRefresh(Refresh);
    Probe.Free;
  end;
end;

procedure TSerialInfrastructureTests.RefreshCanBeCancelledDuringLoad;
var
  Elapsed: QWord;
  Probe: TRefreshProbe;
  Refresh: TSerialDeviceRefreshThread;
  StartedAt: QWord;
begin
  Probe := TRefreshProbe.Create;
  Probe.LoadDelayMs := 100;
  Refresh := TSerialDeviceRefreshThread.Create(
    @Probe.LoadDevices,
    @Probe.DevicesLoaded,
    @Probe.Finished
  );
  try
    Refresh.Start;
    AssertEquals(Ord(wrSignaled), Ord(Probe.LoadStarted.WaitFor(1000)));
    StartedAt := GetTickCount64;
    CancelSerialDeviceRefresh(Refresh);
    Elapsed := GetTickCount64 - StartedAt;

    AssertTrue(Elapsed < 1000);
    AssertEquals(0, Probe.DeliveredCount);
    AssertEquals(0, Probe.FinishedCount);
  finally
    CancelSerialDeviceRefresh(Refresh);
    Probe.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  RefreshDetachCallbacksSuppressesDelivery;
var
  Probe: TRefreshProbe;
  Refresh: TSerialDeviceRefreshThread;
begin
  Probe := TRefreshProbe.Create;
  Refresh := TSerialDeviceRefreshThread.Create(
    @Probe.LoadDevices,
    @Probe.DevicesLoaded,
    @Probe.Finished
  );
  try
    Refresh.DetachCallbacks;
    Refresh.Start;
    Refresh.WaitFor;
    CheckSynchronize(0);

    AssertEquals(0, Probe.DeliveredCount);
    AssertEquals(0, Probe.FinishedCount);
  finally
    CancelSerialDeviceRefresh(Refresh);
    Probe.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  RefreshCancellationSuppressesQueuedDelivery;
var
  Probe: TRefreshProbe;
  Refresh: TSerialDeviceRefreshThread;
begin
  Probe := TRefreshProbe.Create;
  Refresh := TSerialDeviceRefreshThread.Create(
    @Probe.LoadDevices,
    @Probe.DevicesLoaded,
    @Probe.Finished
  );
  try
    Refresh.Start;
    AssertEquals(Ord(wrSignaled), Ord(Probe.LoadCompleted.WaitFor(1000)));
    CancelSerialDeviceRefresh(Refresh);
    CheckSynchronize(0);

    AssertEquals(0, Probe.DeliveredCount);
    AssertEquals(0, Probe.FinishedCount);
  finally
    CancelSerialDeviceRefresh(Refresh);
    Probe.Free;
  end;
end;

procedure TSerialInfrastructureTests.RefreshNilCancellationIsIdempotent;
var
  Refresh: TSerialDeviceRefreshThread;
begin
  Refresh := nil;
  CancelSerialDeviceRefresh(Refresh);
  CancelSerialDeviceRefresh(Refresh);
  AssertNull(Refresh);
end;

procedure TSerialInfrastructureTests.ChangeSourceStartStopIsIdempotent;
var
  Observer: TInfrastructureObserver;
  Source: TTestChangeSource;
begin
  Observer := TInfrastructureObserver.Create;
  Source := TTestChangeSource.Create;
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    Source.Start(@Observer.Changed, @Observer.Failed);
    Source.SignalChanged;
    Source.Stop;
    Source.Stop;
    Source.SignalChanged;
    Source.SignalFailed;

    AssertEquals(1, Source.StartCount);
    AssertEquals(1, Source.StopCount);
    AssertEquals(1, Observer.ChangedCount);
    AssertEquals(0, Observer.FailedCount);
    AssertFalse(Source.Active);
  finally
    Source.Free;
    Observer.Free;
  end;
end;

procedure TSerialInfrastructureTests.ChangeSourceRollsBackFailedStart;
var
  Raised: Boolean;
  Source: TTestChangeSource;
begin
  Source := TTestChangeSource.Create;
  try
    Source.FailOnStart := True;
    Raised := False;
    try
      Source.Start(nil);
    except
      on E: EInvalidOperation do
        Raised := True;
    end;

    AssertTrue(Raised);
    AssertFalse(Source.Active);
    AssertEquals(1, Source.StartCount);
    AssertEquals(0, Source.StopCount);
  finally
    Source.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  ChangeSourceClearsCallbacksOnStopAndDestroy;
var
  DestroyStopCount: Integer;
  Observer: TInfrastructureObserver;
  Source: TTestChangeSource;
begin
  Observer := TInfrastructureObserver.Create;
  Source := TTestChangeSource.Create;
  Source.Start(@Observer.Changed, @Observer.Failed);
  Source.Stop;
  Source.SignalChanged;
  Source.SignalFailed;
  AssertEquals(1, Source.StopCount);
  Source.Free;

  AssertEquals(0, Observer.ChangedCount);
  AssertEquals(0, Observer.FailedCount);

  DestroyStopCount := 0;
  Source := TTestChangeSource.Create;
  Source.StopCounter := @DestroyStopCount;
  Source.Start(nil);
  Source.Free;
  AssertEquals(1, DestroyStopCount);
  Observer.Free;
end;

procedure TSerialInfrastructureTests.FallbackRejectsNilAndEmptyCandidates;
var
  Raised: Boolean;
  Source: TSerialFallbackChangeSource;
begin
  Source := nil;
  Raised := False;
  try
    Source := TSerialFallbackChangeSource.Create([]);
  except
    on E: EArgumentException do
      Raised := True;
  end;
  Source.Free;
  AssertTrue(Raised);

  Source := nil;
  Raised := False;
  try
    Source := TSerialFallbackChangeSource.Create([nil]);
  except
    on E: EArgumentNilException do
      Raised := True;
  end;
  Source.Free;
  AssertTrue(Raised);
end;

procedure TSerialInfrastructureTests.FallbackSkipsMultipleStartFailures;
var
  First: TTestChangeSource;
  Second: TTestChangeSource;
  Source: TSerialFallbackChangeSource;
  Third: TTestChangeSource;
begin
  First := TTestChangeSource.Create;
  First.FailOnStart := True;
  Second := TTestChangeSource.Create;
  Second.FailOnStart := True;
  Third := TTestChangeSource.Create;
  Source := TSerialFallbackChangeSource.Create([First, Second, Third]);
  try
    Source.Start(nil);

    AssertEquals(2, Source.CurrentIndex);
    AssertEquals(1, First.StartCount);
    AssertEquals(1, Second.StartCount);
    AssertEquals(1, Third.StartCount);
    AssertTrue(Third.Active);
  finally
    Source.Free;
  end;
end;

procedure TSerialInfrastructureTests.FallbackReportsRuntimeExhaustion;
var
  Candidate: TTestChangeSource;
  Observer: TInfrastructureObserver;
  Source: TSerialFallbackChangeSource;
begin
  Candidate := TTestChangeSource.Create;
  Observer := TInfrastructureObserver.Create;
  Source := TSerialFallbackChangeSource.Create([Candidate]);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    Candidate.SignalFailed;

    AssertEquals(1, Observer.FailedCount);
    AssertEquals(0, Observer.ChangedCount);
    AssertEquals(1, Source.CurrentIndex);
  finally
    Source.Free;
    Observer.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  FallbackDelegatesSettlingAndIgnoresStaleSignals;
var
  First: TTestChangeSource;
  Observer: TInfrastructureObserver;
  Second: TTestChangeSource;
  Source: TSerialFallbackChangeSource;
begin
  First := TTestChangeSource.Create;
  First.RequiresSettlingValue := False;
  Second := TTestChangeSource.Create;
  Second.RequiresSettlingValue := True;
  Observer := TInfrastructureObserver.Create;
  Source := TSerialFallbackChangeSource.Create([First, Second]);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    AssertFalse(Source.RequiresSettling);
    First.SignalFailed;
    AssertTrue(Source.RequiresSettling);
    AssertEquals(1, Observer.ChangedCount);

    First.SignalChanged;
    First.SignalFailed;
    AssertEquals(1, Observer.ChangedCount);
    AssertEquals(0, Observer.FailedCount);
    AssertEquals(1, Source.CurrentIndex);
  finally
    Source.Free;
    Observer.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  SchedulerReplacementRunsOnlyLatestCallback;
var
  Observer: TInfrastructureObserver;
  Scheduler: TTestRefreshScheduler;
begin
  Observer := TInfrastructureObserver.Create;
  Scheduler := TTestRefreshScheduler.Create;
  try
    Scheduler.Schedule(10, @Observer.First);
    Scheduler.Schedule(25, @Observer.Second);
    AssertEquals(2, Scheduler.ScheduleCount);
    AssertEquals(1, Scheduler.CancelCount);
    AssertEquals(25, Scheduler.LastDelayMs);
    Scheduler.Fire;
    Scheduler.Fire;

    AssertEquals(0, Observer.FirstCount);
    AssertEquals(1, Observer.SecondCount);
    AssertEquals(2, Scheduler.CancelCount);
    AssertFalse(Scheduler.Scheduled);
  finally
    Scheduler.Free;
    Observer.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  SchedulerCancelAndFailureSuppressCallbacks;
var
  Observer: TInfrastructureObserver;
  Raised: Boolean;
  Scheduler: TTestRefreshScheduler;
begin
  Observer := TInfrastructureObserver.Create;
  Scheduler := TTestRefreshScheduler.Create;
  try
    Scheduler.Schedule(10, @Observer.First);
    Scheduler.Cancel;
    Scheduler.Fire;
    AssertEquals(0, Observer.FirstCount);
    AssertFalse(Scheduler.Scheduled);

    Scheduler.FailOnSchedule := True;
    Raised := False;
    try
      Scheduler.Schedule(10, @Observer.Second);
    except
      on E: EInvalidOperation do
        Raised := True;
    end;
    Scheduler.Fire;
    AssertTrue(Raised);
    AssertEquals(0, Observer.SecondCount);
    AssertFalse(Scheduler.Scheduled);
  finally
    Scheduler.Free;
    Observer.Free;
  end;
end;

procedure TSerialInfrastructureTests.
  RealTimerSchedulerAndPollingSourceUseEventLoop;
var
  CountBeforeStop: Integer;
  Deadline: QWord;
  Observer: TInfrastructureObserver;
  Polling: TSerialPollingChangeSource;
  Scheduler: TSerialTimerScheduler;
begin
  Observer := TInfrastructureObserver.Create;
  Scheduler := TSerialTimerScheduler.Create;
  Polling := TSerialPollingChangeSource.Create(1);
  try
    Scheduler.Schedule(1, @Observer.First);
    Deadline := GetTickCount64 + 1000;
    repeat
      Application.ProcessMessages;
      Sleep(1);
    until (Observer.FirstCount > 0) or (GetTickCount64 >= Deadline);
    AssertEquals(1, Observer.FirstCount);
    AssertFalse(Scheduler.Scheduled);

    Polling.Start(@Observer.Changed);
    Deadline := GetTickCount64 + 1000;
    repeat
      Application.ProcessMessages;
      Sleep(1);
    until (Observer.ChangedCount > 0) or (GetTickCount64 >= Deadline);
    AssertTrue(Observer.ChangedCount > 0);
    Polling.Stop;
    CountBeforeStop := Observer.ChangedCount;
    Deadline := GetTickCount64 + 20;
    repeat
      Application.ProcessMessages;
      Sleep(1);
    until GetTickCount64 >= Deadline;
    AssertEquals(CountBeforeStop, Observer.ChangedCount);
  finally
    Polling.Free;
    Scheduler.Free;
    Observer.Free;
  end;
end;

initialization
  RegisterTest(TSerialInfrastructureTests);

end.
