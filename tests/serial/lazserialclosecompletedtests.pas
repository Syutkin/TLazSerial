unit LazSerialCloseCompletedTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSerial,
  LazSerialCommon, LazSerialRead, LazSerialWrite, LazSerialTransportTests;

type
  TLazSerialCloseCompletedTests = class(TTestCase)
  private
    FOwner: TComponent;
    FSerial: TTestableLazSerial;
    FTransport: TFakeSerialTransport;
    FState: TObject;
    FStateReference: IInterface;
    FCount, FErrors: Integer;
    FAction: string;
    procedure Closed(Sender: TObject);
    procedure Failed(Sender: TObject; Code: Integer; const Message: string);
    procedure OpenGated(ABuffered: Boolean; AWrite: Boolean = False);
    procedure AwaitClosed;
    procedure Pump;
    procedure CheckDuplex(AReadFirst: Boolean);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SynchronousCloseIsDeferredAndNotDuplicated;
    procedure IdleCloseAndFailedOpenDoNotNotify;
    procedure EarlyReopenDropsOldNotification;
    procedure HandlerCanReopen;
    procedure HandlerCanDestroyOwner;
    procedure DestroyCancelsQueuedNotification;
    procedure HandlerExceptionPropagatesOnlyOnce;
    procedure BufferedCloseWaitsForNativeHandle;
    procedure DuplexCloseWithReadFinishingFirst;
    procedure DuplexCloseWithWriteFinishingFirst;
    procedure LegacyWriteCloseWaitsForNativeHandle;
    procedure ReaderFailureAlsoCompletesClosing;
    procedure DestroyDuringNativeCleanupDoesNotNotify;
    procedure ReconnectWaitsForCloseHandler;
  end;

implementation

uses LazSynaSer, LazSerialDevices, LazSerialReconnect, SerialWatcher,
  SerialWatcherSupport, SerialWatcherComponentTests;

type
  TCloseState = class(TInterfacedObject)
  public
    ReadStarted, WriteStarted, ReadRelease, WriteRelease, CloseStarted,
      CloseRelease: TEvent;
    ReadFailure: LongInt;
    constructor Create;
    destructor Destroy; override;
  end;

  TCloseSerial = class(TBlockSerial)
  private FState: TCloseState; FReference: IInterface;
  public
    constructor Create(AState: TCloseState);
    procedure Attach;
    procedure CloseSocket; override;
  end;

  TCloseRead = class(TSerialReadOperation)
  private FState: TCloseState; FReference: IInterface;
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; override;
  public
    constructor Create(const APort: ISerialWritePort; AState: TCloseState;
      ALimit: Integer; AChanged: TSerialReadChanged);
  end;

  TCloseWrite = class(TSerialWriteOperation)
  private FState: TCloseState; FReference: IInterface;
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); override;
  public
    constructor Create(const APort: ISerialWritePort; AState: TCloseState;
      const AData: AnsiString; AId: QWord; ATimeout: Cardinal;
      AFinished: TSerialWriteFinished);
  end;

  TCloseTransport = class(TFakeSerialTransport)
  private FPort: ISerialWritePort; FState: TCloseState; FReference: IInterface;
  public
    constructor Create(AState: TCloseState);
    procedure Connect(const ADevice: string); override;
    function IsOpen: Boolean; override;
    function NativeSerial: TBlockSerial; override;
    function CreateReadOperation(const ALimit: Integer;
      const AChanged: TSerialReadChanged): ISerialReadOperation; override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeout: Cardinal; const AFinished: TSerialWriteFinished):
      ISerialWriteOperation; override;
  end;

  TCloseWatcher = class(TSerialWatcher)
  public
    procedure Isolate;
    procedure Stop;
    procedure Publish(const ADevices: TSerialDeviceInfoArray);
  end;
  TCloseReconnect = class(TSerialReconnect);

constructor TCloseState.Create;
begin
  inherited Create;
  ReadStarted := TEvent.Create(nil, True, False, '');
  WriteStarted := TEvent.Create(nil, True, False, '');
  ReadRelease := TEvent.Create(nil, True, False, '');
  WriteRelease := TEvent.Create(nil, True, False, '');
  CloseStarted := TEvent.Create(nil, True, False, '');
  CloseRelease := TEvent.Create(nil, True, False, '');
end;

destructor TCloseState.Destroy;
begin
  ReadStarted.Free;
  WriteStarted.Free;
  ReadRelease.Free;
  WriteRelease.Free;
  CloseStarted.Free;
  CloseRelease.Free;
  inherited Destroy;
end;

constructor TCloseSerial.Create(AState: TCloseState);
begin inherited Create; FState := AState; FReference := AState; end;

procedure TCloseSerial.Attach;
begin FInstanceActive := True; end;

procedure TCloseSerial.CloseSocket;
begin
  if not FInstanceActive then Exit;
  FState.CloseStarted.SetEvent;
  FState.CloseRelease.WaitFor(5000);
  FInstanceActive := False;
end;

constructor TCloseRead.Create(const APort: ISerialWritePort; AState: TCloseState;
  ALimit: Integer; AChanged: TSerialReadChanged);
begin
  inherited Create(APort, ALimit, AChanged);
  FState := AState; FReference := AState;
end;

function TCloseRead.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
begin
  FState.ReadStarted.SetEvent;
  while not StopRequested and
    (InterlockedCompareExchange(FState.ReadFailure, 0, 0) = 0) do WaitDelay(1);
  FState.ReadRelease.WaitFor(5000);
  AReceived := 0;
  Result := InterlockedCompareExchange(FState.ReadFailure, 0, 0);
end;

constructor TCloseWrite.Create(const APort: ISerialWritePort; AState: TCloseState;
  const AData: AnsiString; AId: QWord; ATimeout: Cardinal;
  AFinished: TSerialWriteFinished);
begin
  inherited Create(APort, AData, AId, ATimeout, AFinished);
  FState := AState; FReference := AState;
end;

procedure TCloseWrite.ExecuteWrite(var AResult: TSerialWriteResult);
begin
  FState.WriteStarted.SetEvent;
  while not StopRequested do WaitDelay(1);
  FState.WriteRelease.WaitFor(5000);
  SetStopped(AResult);
end;

constructor TCloseTransport.Create(AState: TCloseState);
begin
  inherited Create;
  FState := AState; FReference := AState;
  FPort := TSerialWritePort.Create(TCloseSerial.Create(AState));
end;

procedure TCloseTransport.Connect(const ADevice: string);
begin inherited Connect(ADevice); TCloseSerial(NativeSerial).Attach; end;

function TCloseTransport.IsOpen: Boolean;
begin Result := NativeSerial.InstanceActive; end;

function TCloseTransport.NativeSerial: TBlockSerial;
begin Result := FPort.GetSerial; end;

function TCloseTransport.CreateReadOperation(const ALimit: Integer;
  const AChanged: TSerialReadChanged): ISerialReadOperation;
begin Result := TCloseRead.Create(FPort, FState, ALimit, AChanged); end;

function TCloseTransport.CreateWriteOperation(const AData: AnsiString;
  const AId: QWord; const ATimeout: Cardinal;
  const AFinished: TSerialWriteFinished): ISerialWriteOperation;
begin Result := TCloseWrite.Create(FPort, FState, AData, AId, ATimeout, AFinished); end;

procedure TCloseWatcher.Isolate;
begin
  SetInfrastructure(TSerialManualChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;

procedure TCloseWatcher.Stop;
begin StopWatching; end;

procedure TCloseWatcher.Publish(const ADevices: TSerialDeviceInfoArray);
begin ApplyDevices(ADevices); end;

procedure TLazSerialCloseCompletedTests.SetUp;
var I: Integer;
begin
  FOwner := TComponent.Create(nil);
  FSerial := TTestableLazSerial.Create(FOwner);
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialWatcher then
      TCloseWatcher(FSerial.Components[I]).Isolate;
  FTransport := TFakeSerialTransport.Create;
  FSerial.InstallTransport(FTransport);
  FSerial.Device := 'close-test';
  FSerial.OnCloseCompleted := @Closed;
  FSerial.OnError := @Failed;
end;

procedure TLazSerialCloseCompletedTests.TearDown;
var State: TCloseState; Deadline: QWord;
begin
  if FState <> nil then
  begin
    State := TCloseState(FState);
    State.ReadRelease.SetEvent;
    State.WriteRelease.SetEvent;
    State.CloseRelease.SetEvent;
  end;
  if FSerial <> nil then
  begin
    FSerial.OnCloseCompleted := nil;
    FSerial.Close;
    Deadline := GetTickCount64 + 3000;
    while (FSerial.ClosePending or FSerial.WritePending) and
      (GetTickCount64 < Deadline) do CheckSynchronize(1);
  end;
  FreeAndNil(FOwner);
  FSerial := nil;
  Pump;
  FStateReference := nil;
end;

procedure TLazSerialCloseCompletedTests.Closed(Sender: TObject);
begin
  Inc(FCount);
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  AssertFalse(FSerial.Active);
  AssertFalse(FSerial.ClosePending);
  AssertFalse(FSerial.WritePending);
  if FAction = 'reopen' then FSerial.Open
  else if FAction = 'destroy' then
  begin FSerial := nil; FreeAndNil(FOwner); end
  else if FAction = 'raise' then raise EInvalidOperation.Create('close handler');
end;

procedure TLazSerialCloseCompletedTests.Failed(Sender: TObject; Code: Integer;
  const Message: string);
begin Inc(FErrors); end;

procedure TLazSerialCloseCompletedTests.Pump;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 30;
  repeat CheckSynchronize(1); until GetTickCount64 >= Deadline;
end;

procedure TLazSerialCloseCompletedTests.AwaitClosed;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 3000;
  while (FCount = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals('One close completion must arrive', 1, FCount);
  Pump;
  AssertEquals('No duplicate after native worker termination', 1, FCount);
end;

procedure TLazSerialCloseCompletedTests.OpenGated(ABuffered: Boolean; AWrite: Boolean);
var State: TCloseState;
begin
  State := TCloseState.Create; FState := State; FStateReference := State;
  FTransport := TCloseTransport.Create(State);
  FSerial.InstallTransport(FTransport);
  FSerial.BufferedRead := ABuffered;
  FSerial.Open;
  if ABuffered then AssertEquals(Ord(wrSignaled), Ord(State.ReadStarted.WaitFor(2000)));
  if AWrite then
  begin
    FSerial.WriteDataAsync('unfinished', 5000);
    AssertEquals(Ord(wrSignaled), Ord(State.WriteStarted.WaitFor(2000)));
  end;
end;

procedure TLazSerialCloseCompletedTests.SynchronousCloseIsDeferredAndNotDuplicated;
begin
  FSerial.Open;
  FSerial.Close;
  AssertEquals(0, FCount);
  FSerial.Close;
  AwaitClosed;
  FSerial.Close;
  Pump;
  AssertEquals(1, FCount);
end;

procedure TLazSerialCloseCompletedTests.IdleCloseAndFailedOpenDoNotNotify;
begin
  FSerial.Close;
  FTransport.FailConnect := True;
  try FSerial.Open; Fail('Opening must fail');
  except on E: EInvalidOperation do ; end;
  FSerial.Close;
  Pump;
  AssertEquals(0, FCount);
end;

procedure TLazSerialCloseCompletedTests.EarlyReopenDropsOldNotification;
begin
  FSerial.Open;
  FSerial.Close;
  FSerial.Open;
  Pump;
  AssertEquals(0, FCount);
  FSerial.Close;
  AwaitClosed;
end;

procedure TLazSerialCloseCompletedTests.HandlerCanReopen;
begin
  FSerial.Open;
  FAction := 'reopen';
  FSerial.Close;
  AwaitClosed;
  AssertTrue(FSerial.Active);
  FAction := '';
end;

procedure TLazSerialCloseCompletedTests.HandlerCanDestroyOwner;
begin
  FSerial.Open;
  FAction := 'destroy';
  FSerial.Close;
  AwaitClosed;
  AssertNull(FOwner);
end;

procedure TLazSerialCloseCompletedTests.DestroyCancelsQueuedNotification;
begin
  FSerial.Open;
  FSerial.Close;
  FSerial := nil;
  FreeAndNil(FOwner);
  Pump;
  AssertEquals(0, FCount);
end;

procedure TLazSerialCloseCompletedTests.HandlerExceptionPropagatesOnlyOnce;
begin
  FSerial.Open;
  FAction := 'raise';
  FSerial.Close;
  try CheckSynchronize; Fail('Handler exception must propagate');
  except on E: EInvalidOperation do AssertEquals('close handler', E.Message); end;
  Pump;
  AssertEquals(1, FCount);
end;

procedure TLazSerialCloseCompletedTests.BufferedCloseWaitsForNativeHandle;
var State: TCloseState;
begin
  OpenGated(True);
  State := TCloseState(FState);
  FSerial.Close;
  AssertEquals(0, FCount);
  State.ReadRelease.SetEvent;
  AssertEquals(Ord(wrSignaled), Ord(State.CloseStarted.WaitFor(2000)));
  Pump;
  AssertTrue(FSerial.ClosePending);
  AssertEquals(0, FCount);
  State.CloseRelease.SetEvent;
  AwaitClosed;
end;

procedure TLazSerialCloseCompletedTests.CheckDuplex(AReadFirst: Boolean);
var State: TCloseState;
begin
  OpenGated(True, True);
  State := TCloseState(FState);
  FSerial.Close;
  if AReadFirst then State.ReadRelease.SetEvent else State.WriteRelease.SetEvent;
  Pump;
  AssertTrue(FSerial.ClosePending);
  AssertEquals(0, FCount);
  State.ReadRelease.SetEvent;
  State.WriteRelease.SetEvent;
  AssertEquals(Ord(wrSignaled), Ord(State.CloseStarted.WaitFor(2000)));
  Pump;
  AssertEquals(0, FCount);
  State.CloseRelease.SetEvent;
  AwaitClosed;
end;

procedure TLazSerialCloseCompletedTests.DuplexCloseWithReadFinishingFirst;
begin CheckDuplex(True); end;
procedure TLazSerialCloseCompletedTests.DuplexCloseWithWriteFinishingFirst;
begin CheckDuplex(False); end;

procedure TLazSerialCloseCompletedTests.LegacyWriteCloseWaitsForNativeHandle;
var State: TCloseState;
begin
  OpenGated(False, True);
  State := TCloseState(FState);
  FSerial.Close;
  State.WriteRelease.SetEvent;
  AssertEquals(Ord(wrSignaled), Ord(State.CloseStarted.WaitFor(2000)));
  Pump;
  AssertEquals(0, FCount);
  State.CloseRelease.SetEvent;
  AwaitClosed;
end;

procedure TLazSerialCloseCompletedTests.ReaderFailureAlsoCompletesClosing;
var State: TCloseState; Deadline: QWord;
begin
  OpenGated(True);
  State := TCloseState(FState);
  InterlockedExchange(State.ReadFailure, ErrNoDeviceAnswer);
  State.ReadRelease.SetEvent;
  Deadline := GetTickCount64 + 2000;
  while (FErrors = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(1, FErrors);
  AssertFalse(FSerial.Active);
  AssertEquals(0, FCount);
  State.CloseRelease.SetEvent;
  AwaitClosed;
end;

procedure TLazSerialCloseCompletedTests.DestroyDuringNativeCleanupDoesNotNotify;
var State: TCloseState;
begin
  OpenGated(True);
  State := TCloseState(FState);
  FSerial.Close;
  FSerial := nil;
  FreeAndNil(FOwner);
  State.ReadRelease.SetEvent;
  State.CloseRelease.SetEvent;
  Pump;
  AssertEquals(0, FCount);
end;

procedure TLazSerialCloseCompletedTests.ReconnectWaitsForCloseHandler;
var
  I: Integer;
  Watcher: TCloseWatcher;
  Scheduler: TFakeSerialRefreshScheduler;
  Device: TSerialDeviceInfo;
begin
  Watcher := nil;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialReconnect then
      TCloseReconnect(FSerial.Components[I]).ReplaceScheduler(Scheduler)
    else if FSerial.Components[I] is TSerialWatcher then
      Watcher := TCloseWatcher(FSerial.Components[I]);
  Device := Default(TSerialDeviceInfo);
  Device.Device := FSerial.Device;
  Device.PersistentId := 'persistent-close-test';
  Watcher.Publish([Device]);
  FSerial.AutoReconnect := True;
  FSerial.Open;
  Watcher.Stop;
  Watcher.Publish([Device]);
  Watcher.Publish([]);
  Watcher.Publish([Device]);
  AssertTrue('A returned device schedules recovery', Scheduler.Scheduled);
  Scheduler.Fire;
  AssertFalse('Automatic opening waits for the close callback', FSerial.Active);
  AwaitClosed;
  AssertTrue('Close completion preserves recovery', FSerial.ReconnectPending);
  Scheduler.Fire;
  AssertTrue('Recovery can open after close completion', FSerial.Active);
  Watcher.Stop;
end;

initialization
  RegisterTest(TLazSerialCloseCompletedTests);
end.
