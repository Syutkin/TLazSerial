unit LazSerialCleanupFailureTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSynaSer,
  LazSerialCommon, LazSerialWrite, LazSerialRead;

type
  TLazSerialCleanupFailureTests = class(TTestCase)
  private
    FPort: ISerialWritePort;
    FLifecycle: ISerialPortLifecycle;
    FWrite: ISerialWriteOperation;
    FRead: ISerialReadOperation;
    FEntered, FReleased, FEnded: TEvent;
    FCalls: Integer;
    FResult: TSerialWriteResult;
    procedure Completed(const AResult: TSerialWriteResult);
    procedure Changed;
    procedure StartWrite(AFailClose, AFailWrite: Boolean);
    procedure WaitForWorker;
    procedure AwaitDelivery;
    procedure CheckCompletedWriteFailure(AStartFailure: Boolean);
    procedure CheckPortFailure(AStartFailure: Boolean);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure CompletedWriteClosesAfterCleanupCreationFailure;
    procedure PortClosesAfterCleanupCreationFailure;
    procedure ReaderCompletesAfterCleanupCreationFailure;
    procedure WriterCompletesAfterCleanupCreationFailure;
    procedure WriterReleaseCleanupFailureCompletes;
    procedure CleanupFailurePreservesOriginalReadError;
    procedure CleanupFailurePreservesOriginalWriteError;
    procedure CleanupFailureWaitsForBothLeases;
    procedure CleanupFailureReleasesLifecycleLock;
    procedure CleanupFailurePreservesStartupError;
    {$IFDEF LCL}
    procedure BufferedCloseFinishesWriteAfterReceiveCleanupFailure;
    {$ENDIF}
    {$IFDEF UNIX}
    procedure CompletedWriteClosesAfterCleanupStartFailure;
    procedure PortClosesAfterCleanupStartFailure;
    {$ENDIF}
  end;

implementation

{$IFDEF LCL}
uses LazSerial, LazSerialTransportTests;
{$ENDIF}

type
  TCloseProbe = class(TThread)
  public
    Lifecycle: ISerialPortLifecycle;
    Entered, Observed: TEvent;
    Pending: Boolean;
    procedure Execute; override;
  end;

  TCleanupSerial = class(TBlockSerial)
  public
    Probe: TCloseProbe;
    ProbeResult: TWaitResult;
    FailClose: Boolean;
    constructor Create;
    procedure CloseSocket; override;
  end;

  TCleanupWrite = class(TSerialWriteOperation)
  public
    Entered, Released: TEvent;
    FailClose, FailWrite: Boolean;
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); override;
  end;

  TCleanupRead = class(TSerialReadOperation)
  public
    Entered, Released: TEvent;
    FailClose, FailRead: Boolean;
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; override;
  end;

{$IFDEF LCL}
  TCleanupTransport = class(TFakeSerialTransport)
  public
    Port: ISerialWritePort;
    Read: ISerialReadOperation;
    Write: ISerialWriteOperation;
    Entered, Released: TEvent;
    function IsOpen: Boolean; override;
    function NativeSerial: TBlockSerial; override;
    function CreateReadOperation(const ALimit: Integer;
      const AOnChanged: TSerialReadChanged): ISerialReadOperation; override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeoutMs: Cardinal; const AOnFinished: TSerialWriteFinished):
      ISerialWriteOperation; override;
  end;
{$ENDIF}

var
  OriginalManager: TThreadManager;
  CapturedThread: TThreadID;
  WorkerEnded: TEvent;
  InjectedFailures: LongInt;
threadvar
  CaptureNext: Boolean;
  FailCreations: Integer;
  {$IFDEF UNIX}
  FailStart: Boolean;
  StartingThread: TThread;
  {$ENDIF}

function BeginCleanupThread(sa: Pointer; stacksize: PtrUInt;
  ThreadFunction: TThreadFunc; p: Pointer; creationFlags: DWord;
  var ThreadId: TThreadID): TThreadID;
begin
  if FailCreations > 0 then
  begin
    Dec(FailCreations);
    InterlockedIncrement(InjectedFailures);
    ThreadId := Default(TThreadID);
    Exit(Default(TThreadID));
  end;
  Result := OriginalManager.BeginThread(sa, stacksize, ThreadFunction, p,
    creationFlags, ThreadId);
  {$IFDEF UNIX}
  if FailStart then StartingThread := TThread(p);
  {$ENDIF}
  if CaptureNext then
  begin
    CaptureNext := False;
    CapturedThread := ThreadId;
  end;
end;

{$IFDEF UNIX}
procedure SetCleanupEvent(AEvent: PRTLEvent);
var Worker: TThread;
begin
  if FailStart and (StartingThread <> nil) then
  begin
    FailStart := False;
    Worker := StartingThread;
    StartingThread := nil;
    InterlockedIncrement(InjectedFailures);
    // Model a failed start with a cancelled worker. Wake the RTL wrapper so
    // Free can join it, but never let Execute or OnTerminate run.
    Worker.FreeOnTerminate := False;
    Worker.OnTerminate := nil;
    Worker.Terminate;
    OriginalManager.RtlEventSetEvent(AEvent);
    raise EThread.Create('injected cleanup start failure');
  end;
  OriginalManager.RtlEventSetEvent(AEvent);
end;
{$ENDIF}

procedure EndCleanupThread(ExitCode: DWord);
var EndThreadHandler: TEndThreadHandler;
begin
  EndThreadHandler := OriginalManager.EndThread;
  if GetCurrentThreadID = CapturedThread then WorkerEnded.SetEvent;
  EndThreadHandler(ExitCode);
end;

procedure TCloseProbe.Execute;
begin
  if Entered.WaitFor(3000) <> wrSignaled then Exit;
  Pending := Lifecycle.GetClosePending;
  Observed.SetEvent;
end;

constructor TCleanupSerial.Create;
begin
  inherited Create;
  FInstanceActive := True;
end;

procedure TCleanupSerial.CloseSocket;
begin
  if (Probe <> nil) and FInstanceActive then
  begin
    Probe.Entered.SetEvent;
    ProbeResult := Probe.Observed.WaitFor(2000);
  end;
  FInstanceActive := False;
  inherited CloseSocket;
  if FailClose then raise EInvalidOperation.Create('secondary cleanup failure');
end;

procedure TCleanupWrite.ExecuteWrite(var AResult: TSerialWriteResult);
begin
  Entered.SetEvent;
  Released.WaitFor(5000);
  if FailClose then FailCreations := 1;
  if FailWrite then
  begin
    AResult.Outcome := swoFailed;
    AResult.ErrorCode := ErrFrame;
    AResult.ErrorMessage := 'original write failure';
  end
  else
  begin
    AResult.Outcome := swoCompleted;
    AResult.BytesWritten := Length(Data);
  end;
end;

function TCleanupRead.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
var Lifecycle: ISerialPortLifecycle;
begin
  Entered.SetEvent;
  Released.WaitFor(5000);
  if FailClose then FailCreations := 1;
  AReceived := 0;
  Result := 0;
  if FailRead then
  begin
    Supports(Port, ISerialPortLifecycle, Lifecycle);
    Lifecycle.RequestClose;
    Result := ErrFrame;
  end;
end;

{$IFDEF LCL}
function TCleanupTransport.IsOpen: Boolean;
begin
  Result := Port.GetSerial.InstanceActive;
end;

function TCleanupTransport.NativeSerial: TBlockSerial;
begin
  Result := Port.GetSerial;
end;

function TCleanupTransport.CreateReadOperation(const ALimit: Integer;
  const AOnChanged: TSerialReadChanged): ISerialReadOperation;
var Operation: TCleanupRead;
begin
  Operation := TCleanupRead.Create(Port, ALimit, AOnChanged);
  Operation.Entered := Entered;
  Operation.Released := Released;
  Read := Operation;
  Result := Read;
  CaptureNext := True;
end;

function TCleanupTransport.CreateWriteOperation(const AData: AnsiString;
  const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
var Operation: TCleanupWrite;
begin
  Operation := TCleanupWrite.Create(Port, AData, AId, ATimeoutMs, AOnFinished);
  Operation.Entered := Entered;
  Operation.Released := Released;
  Write := Operation;
  Write.DeferDelivery;
  Result := Write;
  CaptureNext := True;
end;
{$ENDIF}

procedure TLazSerialCleanupFailureTests.SetUp;
var Manager: TThreadManager;
begin
  inherited SetUp;
  FEntered := TEvent.Create(nil, True, False, '');
  FReleased := TEvent.Create(nil, True, False, '');
  FEnded := TEvent.Create(nil, True, False, '');
  WorkerEnded := FEnded;
  CapturedThread := Default(TThreadID);
  InjectedFailures := 0;
  FailCreations := 0;
  {$IFDEF UNIX}
  FailStart := False;
  StartingThread := nil;
  {$ENDIF}
  CaptureNext := False;
  FCalls := 0;
  GetThreadManager(OriginalManager);
  Manager := OriginalManager;
  Manager.BeginThread := @BeginCleanupThread;
  Manager.EndThread := @EndCleanupThread;
  {$IFDEF UNIX}
  Manager.RtlEventSetEvent := @SetCleanupEvent;
  {$ENDIF}
  SetThreadManager(Manager);
  FPort := TSerialWritePort.Create(TCleanupSerial.Create);
  Supports(FPort, ISerialPortLifecycle, FLifecycle);
end;

procedure TLazSerialCleanupFailureTests.TearDown;
begin
  FailCreations := 0;
  {$IFDEF UNIX}
  FailStart := False;
  StartingThread := nil;
  {$ENDIF}
  TCleanupSerial(FPort.GetSerial).FailClose := False;
  FReleased.SetEvent;
  if FWrite <> nil then FWrite.Detach;
  if FRead <> nil then FRead.Detach;
  // A failed assertion must not leave a worker or its native handle behind.
  if FRead <> nil then FRead.ClosePort;
  if FWrite <> nil then FWrite.ClosePort;
  if CapturedThread <> Default(TThreadID) then WaitForWorker;
  FLifecycle.RequestClose;
  while FLifecycle.GetClosePending do CheckSynchronize(1);
  CheckSynchronize(1);
  FRead := nil;
  FWrite := nil;
  FLifecycle := nil;
  FPort := nil;
  SetThreadManager(OriginalManager);
  FEnded.Free;
  FReleased.Free;
  FEntered.Free;
  inherited TearDown;
end;

procedure TLazSerialCleanupFailureTests.Completed(const AResult: TSerialWriteResult);
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  Inc(FCalls);
  FResult := AResult;
end;

procedure TLazSerialCleanupFailureTests.Changed;
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  Inc(FCalls);
end;

procedure TLazSerialCleanupFailureTests.StartWrite(AFailClose, AFailWrite: Boolean);
var Operation: TCleanupWrite;
begin
  Operation := TCleanupWrite.Create(FPort, 'payload', 42, 10000, @Completed);
  FWrite := Operation;
  Operation.Entered := FEntered;
  Operation.Released := FReleased;
  Operation.FailClose := AFailClose;
  Operation.FailWrite := AFailWrite;
  CaptureNext := True;
  FWrite.Start;
  AssertEquals(Ord(wrSignaled), Ord(FEntered.WaitFor(2000)));
end;

procedure TLazSerialCleanupFailureTests.WaitForWorker;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 3000;
  while (FEnded.WaitFor(0) <> wrSignaled) and (GetTickCount64 < Deadline) do
    CheckSynchronize(1);
  AssertEquals('Worker must terminate', Ord(wrSignaled), Ord(FEnded.WaitFor(0)));
end;

procedure TLazSerialCleanupFailureTests.AwaitDelivery;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while (FCalls = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertTrue('Operation must deliver its final state', FCalls > 0);
end;

procedure TLazSerialCleanupFailureTests.CheckCompletedWriteFailure(AStartFailure: Boolean);
var Raised: Boolean;
begin
  StartWrite(False, False);
  FWrite.DeferDelivery;
  FReleased.SetEvent;
  WaitForWorker;
  AssertEquals(0, FCalls);
  {$IFDEF UNIX}
  if AStartFailure then FailStart := True else
  {$ENDIF}
    FailCreations := 1;
  Raised := False;
  try FWrite.ClosePort; except on E: EThread do Raised := True; end;
  AssertTrue('Report the thread creation error', Raised);
  AssertEquals('Exactly one worker creation must fail', 1, InjectedFailures);
  AssertFalse('Failed cleanup creation must still release the port',
    FPort.GetSerial.InstanceActive);
  AwaitDelivery;
  AssertEquals('Exactly one final callback', 1, FCalls);
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
  AssertEquals(7, FResult.BytesWritten);
end;

procedure TLazSerialCleanupFailureTests.CheckPortFailure(AStartFailure: Boolean);
var Raised: Boolean;
begin
  {$IFDEF UNIX}
  if AStartFailure then FailStart := True else
  {$ENDIF}
    FailCreations := 1;
  Raised := False;
  try FLifecycle.RequestClose; except on E: EThread do Raised := True; end;
  AssertTrue('Report the thread creation error', Raised);
  AssertEquals('Exactly one worker creation must fail', 1, InjectedFailures);
  AssertFalse('Cleanup failure must not leave ClosePending set', FLifecycle.GetClosePending);
  AssertFalse(FPort.GetSerial.InstanceActive);
end;

procedure TLazSerialCleanupFailureTests.CompletedWriteClosesAfterCleanupCreationFailure;
begin
  CheckCompletedWriteFailure(False);
end;

procedure TLazSerialCleanupFailureTests.PortClosesAfterCleanupCreationFailure;
begin
  CheckPortFailure(False);
end;

{$IFDEF UNIX}
procedure TLazSerialCleanupFailureTests.CompletedWriteClosesAfterCleanupStartFailure;
begin
  CheckCompletedWriteFailure(True);
end;

procedure TLazSerialCleanupFailureTests.PortClosesAfterCleanupStartFailure;
begin
  CheckPortFailure(True);
end;
{$ENDIF}

procedure TLazSerialCleanupFailureTests.ReaderCompletesAfterCleanupCreationFailure;
var Operation: TCleanupRead; Error: Integer; Message: string;
begin
  Operation := TCleanupRead.Create(FPort, 32, @Changed);
  Operation.FailClose := True;
  FRead := Operation;
  Operation.Entered := FEntered;
  Operation.Released := FReleased;
  CaptureNext := True;
  FRead.Start;
  AssertEquals(Ord(wrSignaled), Ord(FEntered.WaitFor(2000)));
  FRead.ClosePort;
  FReleased.SetEvent;
  WaitForWorker;
  AssertEquals('Exactly one worker creation must fail', 1, InjectedFailures);
  AssertFalse('Reader completion must survive ReleaseIO failure', FRead.GetClosePending);
  AssertFalse(FPort.GetSerial.InstanceActive);
  AssertTrue('Cleanup failure must remain observable', FRead.GetFailure(Error, Message));
  AssertTrue(Message <> '');
end;

procedure TLazSerialCleanupFailureTests.WriterCompletesAfterCleanupCreationFailure;
begin
  StartWrite(True, False);
  FWrite.ClosePort;
  FReleased.SetEvent;
  WaitForWorker;
  AssertEquals('Exactly one worker creation must fail', 1, InjectedFailures);
  AssertFalse(FPort.GetSerial.InstanceActive);
  AwaitDelivery;
  AssertEquals('Exactly one final callback', 1, FCalls);
  AssertEquals(Ord(swoFailed), Ord(FResult.Outcome));
  AssertTrue(FResult.ErrorMessage <> '');
  AssertEquals(7, FResult.BytesWritten);
end;

procedure TLazSerialCleanupFailureTests.WriterReleaseCleanupFailureCompletes;
begin
  StartWrite(True, False);
  FLifecycle.RequestClose;
  FWrite.ClosePort;
  FReleased.SetEvent;
  WaitForWorker;
  AssertEquals('The last lease triggers failed cleanup startup', 1, InjectedFailures);
  AssertFalse(FLifecycle.GetClosePending);
  AssertFalse(FPort.GetSerial.InstanceActive);
  AwaitDelivery;
  AssertEquals('Exactly one final callback', 1, FCalls);
  AssertEquals(Ord(swoFailed), Ord(FResult.Outcome));
  AssertTrue(FResult.ErrorMessage <> '');
  AssertEquals(7, FResult.BytesWritten);
end;

procedure TLazSerialCleanupFailureTests.CleanupFailurePreservesOriginalReadError;
var Operation: TCleanupRead; Error: Integer; Message: string;
begin
  Operation := TCleanupRead.Create(FPort, 32, @Changed);
  Operation.FailClose := True;
  Operation.FailRead := True;
  Operation.Entered := FEntered;
  Operation.Released := FReleased;
  FRead := Operation;
  CaptureNext := True;
  FRead.Start;
  AssertEquals(Ord(wrSignaled), Ord(FEntered.WaitFor(2000)));
  FReleased.SetEvent;
  WaitForWorker;
  FRead.ClosePort;
  AssertEquals('Exactly one worker creation must fail', 1, InjectedFailures);
  AssertFalse(FRead.GetClosePending);
  AssertFalse(FPort.GetSerial.InstanceActive);
  AssertTrue(FRead.GetFailure(Error, Message));
  AssertEquals(ErrFrame, Error);
  AssertEquals(TBlockSerial.GetErrorDesc(ErrFrame), Message);
end;

procedure TLazSerialCleanupFailureTests.CleanupFailurePreservesOriginalWriteError;
begin
  StartWrite(True, True);
  FWrite.ClosePort;
  FReleased.SetEvent;
  WaitForWorker;
  AssertEquals('Exactly one worker creation must fail', 1, InjectedFailures);
  AssertFalse(FPort.GetSerial.InstanceActive);
  AwaitDelivery;
  AssertEquals('Exactly one final callback', 1, FCalls);
  AssertEquals(Ord(swoFailed), Ord(FResult.Outcome));
  AssertEquals(ErrFrame, FResult.ErrorCode);
  AssertEquals('original write failure', FResult.ErrorMessage);
end;

procedure TLazSerialCleanupFailureTests.CleanupFailureWaitsForBothLeases;
var ReadFirst, Raised: Boolean;
begin
  for ReadFirst := False to True do
  begin
    FPort := TSerialWritePort.Create(TCleanupSerial.Create);
    Supports(FPort, ISerialPortLifecycle, FLifecycle);
    FLifecycle.AcquireIO(True);
    FLifecycle.AcquireIO(False);
    FLifecycle.RequestClose;
    FailCreations := 1;
    FLifecycle.ReleaseIO(ReadFirst);
    AssertTrue('The other lease still owns the open port', FPort.GetSerial.InstanceActive);
    AssertTrue(FLifecycle.GetClosePending);
    AssertEquals('Do not start cleanup before both leases end', Ord(ReadFirst), InjectedFailures);
    Raised := False;
    try FLifecycle.ReleaseIO(not ReadFirst); except on E: EThread do Raised := True; end;
    AssertTrue(Raised);
    AssertFalse(FLifecycle.GetClosePending);
    AssertFalse(FPort.GetSerial.InstanceActive);
  end;
  AssertEquals(2, InjectedFailures);
end;

procedure TLazSerialCleanupFailureTests.CleanupFailureReleasesLifecycleLock;
var Probe: TCloseProbe;
begin
  Probe := TCloseProbe.Create(True);
  Probe.Lifecycle := FLifecycle;
  Probe.Entered := TEvent.Create(nil, True, False, '');
  Probe.Observed := TEvent.Create(nil, True, False, '');
  TCleanupSerial(FPort.GetSerial).Probe := Probe;
  try
    Probe.Start;
    CheckPortFailure(False);
    AssertEquals('Native close must not hold the lifecycle lock',
      Ord(wrSignaled), Ord(TCleanupSerial(FPort.GetSerial).ProbeResult));
    AssertTrue('ClosePending remains observable during native cleanup', Probe.Pending);
  finally
    TCleanupSerial(FPort.GetSerial).Probe := nil;
    Probe.Entered.SetEvent;
    Probe.WaitFor;
    Probe.Entered.Free;
    Probe.Observed.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialCleanupFailureTests.CleanupFailurePreservesStartupError;
begin
  TCleanupSerial(FPort.GetSerial).FailClose := True;
  CheckPortFailure(False);
end;

{$IFDEF LCL}
procedure TLazSerialCleanupFailureTests.BufferedCloseFinishesWriteAfterReceiveCleanupFailure;
var Serial: TTestableLazSerial; Transport: TCleanupTransport;
  Deadline: QWord; Raised: Boolean;
begin
  Serial := TTestableLazSerial.Create(nil);
  Transport := TCleanupTransport.Create;
  Transport.Port := FPort;
  Transport.Entered := FEntered;
  Transport.Released := FReleased;
  Serial.InstallTransport(Transport);
  try
    Serial.BufferedRead := True;
    Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(FEntered.WaitFor(2000)));
    Transport.Read.Cancel;
    FReleased.SetEvent;
    WaitForWorker;
    FEntered.ResetEvent;
    FEnded.ResetEvent;
    Serial.WriteDataAsync('payload', 10000);
    WaitForWorker;
    AssertTrue(Serial.WritePending);
    FailCreations := 2;
    Raised := False;
    try Serial.Close; except on E: EThread do Raised := True; end;
    AssertTrue('Close must report the original startup error', Raised);
    Deadline := GetTickCount64 + 2000;
    while (Serial.ClosePending or Serial.WritePending) and
      (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertEquals('Both cleanup startups were rejected', 2, InjectedFailures);
    AssertFalse('The TX result must not remain deferred after RX cleanup fails', Serial.WritePending);
    AssertFalse(Serial.ClosePending);
    AssertFalse(Serial.Active);
    AssertFalse(FPort.GetSerial.InstanceActive);
  finally
    FailCreations := 0;
    Serial.Free;
  end;
end;
{$ENDIF}

initialization
  RegisterTest(TLazSerialCleanupFailureTests);
end.
