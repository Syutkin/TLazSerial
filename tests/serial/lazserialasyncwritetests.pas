unit LazSerialAsyncWriteTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ExtCtrls, FpcUnit, TestRegistry, LazSerialCommon,
  LazSerialWrite, LazSerial, LazSerialTransportTests;

type
  TLazSerialWriteOperationTests = class(TTestCase)
  private
    FCalls: Integer;
    FResult: TSerialWriteResult;
    procedure Completed(const AResult: TSerialWriteResult);
    procedure AwaitCompletion;
  published
    procedure ResultOwnsTheOriginalPayload;
    procedure CompletionIsQueuedToMainThread;
    procedure CancellationReturnsAResult;
    procedure TimeoutReturnsAResult;
    procedure DetachCancelsQueuedDelivery;
  end;

  IWriteTestGate = interface
    procedure Release;
  end;

  TWriteTestGate = class(TInterfacedObject, IWriteTestGate)
  public
    Started, Cancelling, Released: TEvent;
    Mode, CreatedOperations, DestroyedOperations, ClosedPorts, DestroyedPorts: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Release;
  end;

  TLazSerialAsyncComponentTests = class(TTestCase)
  private
    FSerial: TTestableLazSerial;
    FOwner: TComponent;
    FGate: IWriteTestGate;
    FGateObject: TWriteTestGate;
    FCalls, FAction, FTicks: Integer;
    FResult: TSerialWriteResult;
    FNextId: QWord;
    procedure Completed(Sender: TObject; const AResult: TSerialWriteResult);
    procedure Tick(Sender: TObject);
    procedure AwaitIdle;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure CompletionCanStartTheNextWrite;
    procedure CompletionCanDestroyComponent;
    procedure CompletionCanDestroyOwner;
    procedure CompletionExceptionLeavesComponentUsable;
    procedure PendingWriteRejectsConflictingOperations;
    procedure ReadContinuesDuringPendingWrite;
    procedure CloseDoesNotWaitForCancellation;
    procedure DestroyRetainsResourcesUntilCancellationFinishes;
    procedure ClosedSessionNeverDeliversResultAfterReopen;
    procedure InvalidRequestsDoNotConsumeAnIdentifier;
    procedure GenericExceptionReturnsCodeZero;
    procedure AsyncApiRejectsWorkerThread;
    procedure ClosedNativePortRejectsAsyncRequest;
  end;

  {$IFDEF UNIX}
  TLazSerialNativeWriteTests = class(TTestCase)
  private
    FSerial: TObject;
    FMaster, FNativeHandle: Integer;
    FCalls: Integer;
    FResult: TSerialWriteResult;
    FReceived: AnsiString;
    procedure Completed(Sender: TObject; const AResult: TSerialWriteResult);
    procedure Received(Sender: TObject);
    procedure AwaitCompletion;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure EmptyWriteQueuesCompletion;
    procedure BinaryWriteUsesNativePort;
    procedure BackpressureReturnsPartialTimeout;
    procedure BackpressureCanBeCancelled;
    procedure RestoresDescriptorFlags;
    procedure ReaderReceivesDuringBlockedWrite;
    procedure LongDeadlineDoesNotOverflowPolling;
  end;
  {$ENDIF}

implementation

uses
  Forms, LazSynaSer, LazSerialTransport
  {$IFDEF UNIX}, BaseUnix, ctypes{$ENDIF};

{$IFDEF UNIX}
function OpenWritePty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl;
  external 'util' name 'openpty';
{$ENDIF}

type
  TAsyncContractThread = class(TThread)
  public
    Serial: TLazSerial;
    Rejected: Integer;
    procedure Execute; override;
  end;

  TGateSerial = class(TBlockSerial)
  private
    FGate: IWriteTestGate;
    FGateObject: TWriteTestGate;
  public
    constructor Create(AGate: TWriteTestGate);
    destructor Destroy; override;
    procedure Attach;
    procedure CloseSocket; override;
  end;

  TGateWriteOperation = class(TSerialWriteOperation)
  private
    FGate: IWriteTestGate;
    FGateObject: TWriteTestGate;
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); override;
  public
    constructor Create(const APort: ISerialWritePort; const AData: AnsiString;
      const AId: QWord; const ATimeoutMs: Cardinal;
      const AOnFinished: TSerialWriteFinished; AGate: TWriteTestGate);
    destructor Destroy; override;
  end;

  TGateTransport = class(TFakeSerialTransport)
  private
    FPort: ISerialWritePort;
    FGate: IWriteTestGate;
    FGateObject: TWriteTestGate;
  public
    constructor Create(AGate: TWriteTestGate);
    procedure Connect(const ADevice: string); override;
    procedure Close; override;
    function IsOpen: Boolean; override;
    function NativeSerial: TBlockSerial; override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeoutMs: Cardinal; const AOnFinished: TSerialWriteFinished):
      ISerialWriteOperation; override;
  end;

  TScriptedWriteOperation = class(TSerialWriteOperation)
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); override;
  public
    WaitForStop: Boolean;
  end;

procedure TAsyncContractThread.Execute;
var
  I: Integer;
begin
  for I := 0 to 2 do
    try
      case I of
        0: Serial.WriteDataAsync('foreign thread', 1000);
        1: Serial.CancelWrite;
        2: if Serial.WritePending then ;
      end;
    except
      on E: ELazSerialThreadError do Inc(Rejected);
    end;
end;

constructor TWriteTestGate.Create;
begin
  inherited Create;
  Started := TEvent.Create(nil, True, False, '');
  Cancelling := TEvent.Create(nil, True, False, '');
  Released := TEvent.Create(nil, True, False, '');
  Mode := 1;
end;

destructor TWriteTestGate.Destroy;
begin
  Released.Free;
  Cancelling.Free;
  Started.Free;
  inherited Destroy;
end;

procedure TWriteTestGate.Release;
begin
  Released.SetEvent;
end;

constructor TGateSerial.Create(AGate: TWriteTestGate);
begin
  inherited Create;
  FGate := AGate;
  FGateObject := AGate;
end;

destructor TGateSerial.Destroy;
begin
  InterlockedIncrement(FGateObject.DestroyedPorts);
  inherited Destroy;
end;

procedure TGateSerial.Attach;
begin
  FInstanceActive := True;
end;

procedure TGateSerial.CloseSocket;
begin
  if FInstanceActive then
  begin
    FInstanceActive := False;
    InterlockedIncrement(FGateObject.ClosedPorts);
  end;
  SetSynaError(0);
end;

constructor TGateTransport.Create(AGate: TWriteTestGate);
begin
  inherited Create;
  FGate := AGate;
  FGateObject := AGate;
  FPort := TSerialWritePort.Create(TGateSerial.Create(AGate));
end;

procedure TGateTransport.Connect(const ADevice: string);
begin
  inherited Connect(ADevice);
  TGateSerial(NativeSerial).Attach;
end;

procedure TGateTransport.Close;
begin
  inherited Close;
  NativeSerial.CloseSocket;
end;

function TGateTransport.IsOpen: Boolean;
begin
  Result := NativeSerial.InstanceActive;
end;

function TGateTransport.NativeSerial: TBlockSerial;
begin
  Result := FPort.GetSerial;
end;

function TGateTransport.CreateWriteOperation(const AData: AnsiString;
  const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
begin
  Result := TGateWriteOperation.Create(FPort, AData, AId, ATimeoutMs,
    AOnFinished, FGateObject);
end;

constructor TGateWriteOperation.Create(const APort: ISerialWritePort;
  const AData: AnsiString; const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished; AGate: TWriteTestGate);
begin
  inherited Create(APort, AData, AId, ATimeoutMs, AOnFinished);
  FGate := AGate;
  FGateObject := AGate;
  InterlockedIncrement(AGate.CreatedOperations);
end;

destructor TGateWriteOperation.Destroy;
begin
  InterlockedIncrement(FGateObject.DestroyedOperations);
  inherited Destroy;
end;

procedure TGateWriteOperation.ExecuteWrite(var AResult: TSerialWriteResult);
begin
  FGateObject.Started.SetEvent;
  case FGateObject.Mode of
    0:
      begin
        while not StopRequested do
          WaitDelay(5);
        FGateObject.Cancelling.SetEvent;
        FGateObject.Released.WaitFor(INFINITE);
        SetStopped(AResult);
      end;
    1: AResult.BytesWritten := Length(Data);
    2: raise Exception.Create('scripted write failure');
  end;
end;

procedure TLazSerialAsyncComponentTests.SetUp;
begin
  inherited SetUp;
  FGateObject := TWriteTestGate.Create;
  FGate := FGateObject;
  FOwner := TComponent.Create(nil);
  FSerial := TTestableLazSerial.Create(FOwner);
  FSerial.InstallTransport(TGateTransport.Create(FGateObject));
  FSerial.OnWriteCompleted := @Completed;
  FSerial.Open;
end;

procedure TLazSerialAsyncComponentTests.TearDown;
var
  Started: QWord;
begin
  FGate.Release;
  FreeAndNil(FSerial);
  FreeAndNil(FOwner);
  Started := GetTickCount64;
  while ((FGateObject.DestroyedOperations < FGateObject.CreatedOperations) or
    (FGateObject.DestroyedPorts = 0)) and (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  AssertEquals('Release every detached write', FGateObject.CreatedOperations,
    FGateObject.DestroyedOperations);
  AssertEquals('Release the shared native port exactly once', 1,
    FGateObject.DestroyedPorts);
  FGate := nil;
  inherited TearDown;
end;

procedure TLazSerialAsyncComponentTests.Completed(Sender: TObject;
  const AResult: TSerialWriteResult);
begin
  AssertTrue(GetCurrentThreadID = MainThreadID);
  AssertFalse(FSerial.WritePending);
  Inc(FCalls);
  FResult := AResult;
  case FAction of
    1: FreeAndNil(FSerial);
    2:
      begin
        FreeAndNil(FOwner);
        FSerial := nil;
      end;
    3:
      begin
        FAction := 0;
        FNextId := FSerial.WriteDataAsync('next', 1000);
      end;
    4: raise EAbort.Create('scripted completion exception');
  end;
end;

procedure TLazSerialAsyncComponentTests.Tick(Sender: TObject);
begin
  Inc(FTicks);
end;

procedure TLazSerialAsyncComponentTests.AwaitIdle;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (FSerial <> nil) and FSerial.WritePending and
    (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  if FSerial <> nil then
    AssertFalse('Complete the pending operation', FSerial.WritePending);
end;

procedure TLazSerialAsyncComponentTests.CompletionCanStartTheNextWrite;
var
  Id: QWord;
begin
  FAction := 3;
  Id := FSerial.WriteDataAsync('first', 1000);
  AwaitIdle;
  AssertEquals(2, FCalls);
  AssertTrue(FNextId > Id);
  AssertEquals(FNextId, FResult.OperationId);
end;

procedure TLazSerialAsyncComponentTests.CompletionCanDestroyComponent;
begin
  FAction := 1;
  FSerial.WriteDataAsync('data', 1000);
  AwaitIdle;
  AssertTrue(FSerial = nil);
  AssertEquals(1, FCalls);
end;

procedure TLazSerialAsyncComponentTests.CompletionCanDestroyOwner;
begin
  FAction := 2;
  FSerial.WriteDataAsync('data', 1000);
  AwaitIdle;
  AssertTrue(FSerial = nil);
  AssertTrue(FOwner = nil);
end;

procedure TLazSerialAsyncComponentTests.CompletionExceptionLeavesComponentUsable;
var
  Raised: Boolean;
begin
  FAction := 4;
  FSerial.WriteDataAsync('data', 1000);
  Raised := False;
  try
    AwaitIdle;
  except
    on E: EAbort do Raised := True;
  end;
  AssertTrue('The exception must stay on the main thread', Raised);
  AssertFalse(FSerial.WritePending);
  FAction := 0;
  FSerial.WriteDataAsync('next', 1000);
  AwaitIdle;
  AssertEquals(2, FCalls);
end;

procedure TLazSerialAsyncComponentTests.PendingWriteRejectsConflictingOperations;
var
  I: Integer;
  Buffer: Byte;
  Raised: Boolean;
begin
  FGateObject.Mode := 0;
  Buffer := 0;
  FSerial.WriteDataAsync('pending', 1000);
  for I := 0 to 13 do
  begin
    Raised := False;
    try
      case I of
        0: FSerial.WriteData('sync');
        1: FSerial.WriteBuffer(Buffer, 1);
        2: FSerial.WriteDataAsync('overlap', 1000);
        3: FSerial.Device := 'other';
        4: FSerial.BaudRate := br__9600;
        5: FSerial.CustomBaudRate := 12345;
        6: FSerial.DataBits := db7bits;
        7: FSerial.Parity := pOdd;
        8: FSerial.StopBits := sbTwo;
        9: FSerial.FlowControl := fcRTS_CTS;
        10: FSerial.SetDTR(True);
        11: FSerial.SetRTS(True);
        12: FSerial.RcvLineCRLF := True;
        13: FSerial.SynSer.SetSynaError(0);
      end;
    except
      on E: EInvalidOperation do Raised := True;
    end;
    AssertTrue('Reject conflicting operation ' + IntToStr(I), Raised);
  end;
end;

procedure TLazSerialAsyncComponentTests.ReadContinuesDuringPendingWrite;
begin
  FGateObject.Mode := 0;
  FSerial.WriteDataAsync('pending', 1000);
  // This operation does not hold the component's transport lock while waiting.
  AssertEquals('', FSerial.ReadData);
  AssertTrue(FSerial.Active);
  AssertTrue(FSerial.WritePending);
end;

procedure TLazSerialAsyncComponentTests.CloseDoesNotWaitForCancellation;
var
  Timer: TTimer;
  Started: QWord;
  Raised: Boolean;
begin
  FGateObject.Mode := 0;
  FSerial.WriteDataAsync('pending', 1000);
  AssertEquals(Ord(wrSignaled), Ord(FGateObject.Started.WaitFor(1000)));
  FSerial.Close;
  AssertFalse(FSerial.Active);
  AssertTrue(FSerial.WritePending);
  Raised := False;
  try
    FSerial.Open;
  except
    on E: EInvalidOperation do Raised := True;
  end;
  AssertTrue('Do not reopen while old native resources are still in use', Raised);
  AssertEquals(Ord(wrSignaled), Ord(FGateObject.Cancelling.WaitFor(1000)));
  Timer := TTimer.Create(nil);
  try
    Timer.Interval := 1;
    Timer.OnTimer := @Tick;
    Timer.Enabled := True;
    Started := GetTickCount64;
    while (FTicks < 3) and (GetTickCount64 - Started < 1000) do
    begin
      Application.ProcessMessages;
      Sleep(1);
    end;
    AssertTrue('LCL timers must run while native cancellation is blocked', FTicks >= 3);
    AssertEquals(0, FGateObject.ClosedPorts);
    AssertTrue(FSerial.WritePending);
  finally
    Timer.Free;
  end;
  FGate.Release;
  AwaitIdle;
  AssertEquals(1, FGateObject.ClosedPorts);
  AssertEquals('Close suppresses the old public completion', 0, FCalls);
end;

procedure TLazSerialAsyncComponentTests.DestroyRetainsResourcesUntilCancellationFinishes;
begin
  FGateObject.Mode := 0;
  FSerial.WriteDataAsync('pending', 1000);
  AssertEquals(Ord(wrSignaled), Ord(FGateObject.Started.WaitFor(1000)));
  FreeAndNil(FSerial);
  AssertEquals(0, FGateObject.DestroyedPorts);
  AssertEquals(0, FGateObject.DestroyedOperations);
  FGate.Release;
end;

procedure TLazSerialAsyncComponentTests.ClosedSessionNeverDeliversResultAfterReopen;
var
  Id: QWord;
begin
  FGateObject.Mode := 0;
  Id := FSerial.WriteDataAsync('pending', 1000);
  FSerial.Close;
  FGate.Release;
  AwaitIdle;
  FGateObject.Mode := 1;
  FSerial.Open;
  AssertTrue(FSerial.WriteDataAsync('new session', 1000) > Id);
  AwaitIdle;
  AssertEquals(1, FCalls);
  AssertEquals(11, FResult.BytesWritten);
end;

procedure TLazSerialAsyncComponentTests.InvalidRequestsDoNotConsumeAnIdentifier;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    FSerial.WriteDataAsync('invalid', 0);
  except
    on E: EArgumentException do Raised := True;
  end;
  AssertTrue(Raised);
  AssertFalse(FSerial.WritePending);
  AssertEquals(1, FSerial.WriteDataAsync('valid', 1000));
  AwaitIdle;
end;

procedure TLazSerialAsyncComponentTests.GenericExceptionReturnsCodeZero;
begin
  FGateObject.Mode := 2;
  FSerial.WriteDataAsync('data', 1000);
  AwaitIdle;
  AssertEquals(Ord(swoFailed), Ord(FResult.Outcome));
  AssertEquals(0, FResult.ErrorCode);
  AssertEquals('scripted write failure', FResult.ErrorMessage);
end;

procedure TLazSerialAsyncComponentTests.AsyncApiRejectsWorkerThread;
var
  Worker: TAsyncContractThread;
begin
  Worker := TAsyncContractThread.Create(True);
  try
    Worker.Serial := FSerial;
    Worker.Start;
    Worker.WaitFor;
    AssertEquals(3, Worker.Rejected);
    AssertEquals(0, FGateObject.CreatedOperations);
    AssertFalse(FSerial.WritePending);
  finally
    Worker.Free;
  end;
end;

procedure TLazSerialAsyncComponentTests.ClosedNativePortRejectsAsyncRequest;
var
  Raised: Boolean;
begin
  FSerial.SynSer.CloseSocket;
  Raised := False;
  try
    FSerial.WriteDataAsync('closed', 1000);
  except
    on E: Exception do
    begin
      Raised := True;
      AssertTrue(Pos('closed port', E.Message) > 0);
    end;
  end;
  AssertTrue(Raised);
  AssertFalse(FSerial.WritePending);
  AssertEquals(0, FGateObject.CreatedOperations);
end;

procedure TScriptedWriteOperation.ExecuteWrite(var AResult: TSerialWriteResult);
begin
  if WaitForStop then
  begin
    while not StopRequested do
      WaitDelay(5);
    SetStopped(AResult);
  end
  else
  begin
    if Data <> 'A' + #0 + 'B' then
      raise Exception.Create('The accepted buffer changed');
    AResult.BytesWritten := Length(Data);
  end;
end;

procedure TLazSerialWriteOperationTests.Completed(const AResult: TSerialWriteResult);
begin
  AssertTrue('Delivery must run on the main thread',
    GetCurrentThreadID = MainThreadID);
  Inc(FCalls);
  FResult := AResult;
end;

procedure TLazSerialWriteOperationTests.AwaitCompletion;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (FCalls = 0) and (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  AssertEquals('Exactly one write result must be delivered', 1, FCalls);
end;

procedure TLazSerialWriteOperationTests.ResultOwnsTheOriginalPayload;
var
  Operation: ISerialWriteOperation;
  Payload: AnsiString;
begin
  Payload := 'A' + #0 + 'B';
  Operation := TScriptedWriteOperation.Create(nil, Payload, 42, 1000, @Completed);
  Payload[1] := 'X';
  Operation.Start;
  AwaitCompletion;
  AssertEquals(42, FResult.OperationId);
  AssertEquals(3, FResult.BytesRequested);
  AssertEquals(3, FResult.BytesWritten);
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
end;

procedure TLazSerialWriteOperationTests.CompletionIsQueuedToMainThread;
var
  Operation: ISerialWriteOperation;
begin
  Operation := TScriptedWriteOperation.Create(nil, 'A' + #0 + 'B', 1, 1000,
    @Completed);
  Operation.Start;
  AssertEquals('Start must not invoke a callback inline', 0, FCalls);
  AwaitCompletion;
end;

procedure TLazSerialWriteOperationTests.CancellationReturnsAResult;
var
  Operation: ISerialWriteOperation;
  Script: TScriptedWriteOperation;
begin
  Script := TScriptedWriteOperation.Create(nil, 'pending', 1, 1000, @Completed);
  Operation := Script;
  Script.WaitForStop := True;
  Operation.Start;
  Operation.Cancel;
  AwaitCompletion;
  AssertEquals(Ord(swoCancelled), Ord(FResult.Outcome));
  AssertEquals(0, FResult.ErrorCode);
end;

procedure TLazSerialWriteOperationTests.TimeoutReturnsAResult;
var
  Operation: ISerialWriteOperation;
  Script: TScriptedWriteOperation;
begin
  Script := TScriptedWriteOperation.Create(nil, 'pending', 1, 10, @Completed);
  Operation := Script;
  Script.WaitForStop := True;
  Operation.Start;
  AwaitCompletion;
  AssertEquals(Ord(swoTimedOut), Ord(FResult.Outcome));
  AssertTrue(FResult.ErrorCode <> 0);
end;

procedure TLazSerialWriteOperationTests.DetachCancelsQueuedDelivery;
var
  Operation: ISerialWriteOperation;
begin
  Operation := TScriptedWriteOperation.Create(nil, 'A' + #0 + 'B', 1, 1000,
    @Completed);
  Operation.Start;
  Operation.Detach;
  Operation.ClosePort;
  // Let the detached worker finish without delivering to this test instance.
  Sleep(20);
  CheckSynchronize;
  AssertEquals(0, FCalls);
end;

{$IFDEF UNIX}
procedure TLazSerialNativeWriteTests.SetUp;
var
  Slave: cint;
  Name: array[0..255] of Char;
  Serial: TLazSerial;
begin
  inherited SetUp;
  FMaster := -1;
  AssertEquals(0, OpenWritePty(@FMaster, @Slave, @Name[0], nil, nil));
  try
    Serial := TLazSerial.Create(nil);
    FSerial := Serial;
    Serial.Device := StrPas(Name);
    Serial.Open;
    FNativeHandle := Serial.SynSer.Handle;
    Serial.OnWriteCompleted := @Completed;
    fpFcntl(FMaster, F_SETFL, fpFcntl(FMaster, F_GETFL) or O_NONBLOCK);
  finally
    fpClose(Slave);
  end;
end;

procedure TLazSerialNativeWriteTests.TearDown;
var
  Started: QWord;
begin
  FreeAndNil(FSerial);
  Started := GetTickCount64;
  while (fpFcntl(FNativeHandle, F_GETFD) >= 0) and
    (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  CheckSynchronize;
  if FMaster >= 0 then
    fpClose(FMaster);
  inherited TearDown;
end;

procedure TLazSerialNativeWriteTests.Completed(Sender: TObject;
  const AResult: TSerialWriteResult);
begin
  AssertTrue(GetCurrentThreadID = MainThreadID);
  AssertFalse('Clear pending before calling user code', TLazSerial(Sender).WritePending);
  Inc(FCalls);
  FResult := AResult;
end;

procedure TLazSerialNativeWriteTests.AwaitCompletion;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (FCalls = 0) and (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  AssertEquals(1, FCalls);
end;

procedure TLazSerialNativeWriteTests.EmptyWriteQueuesCompletion;
var
  Id: QWord;
begin
  Id := TLazSerial(FSerial).WriteDataAsync('', 1000);
  AssertTrue(TLazSerial(FSerial).WritePending);
  AssertEquals(0, FCalls);
  AwaitCompletion;
  AssertEquals(Id, FResult.OperationId);
  AssertEquals(0, FResult.BytesWritten);
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
end;

procedure TLazSerialNativeWriteTests.BinaryWriteUsesNativePort;
const
  Payload = 'A' + #0 + #255 + 'B';
var
  Buffer: array[0..3] of Byte;
begin
  TLazSerial(FSerial).WriteDataAsync(Payload, 1000);
  AwaitCompletion;
  AssertEquals(4, FResult.BytesWritten);
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
  AssertEquals(4, fpRead(FMaster, Buffer[0], SizeOf(Buffer)));
  AssertEquals(Ord('A'), Buffer[0]);
  AssertEquals(0, Buffer[1]);
  AssertEquals(255, Buffer[2]);
  AssertEquals(Ord('B'), Buffer[3]);
end;

procedure TLazSerialNativeWriteTests.BackpressureReturnsPartialTimeout;
begin
  TLazSerial(FSerial).WriteDataAsync(StringOfChar('X', 2 * 1024 * 1024), 20);
  AwaitCompletion;
  AssertEquals(Ord(swoTimedOut), Ord(FResult.Outcome));
  AssertTrue('Preserve the count accepted before backpressure', FResult.BytesWritten > 0);
  AssertTrue(FResult.BytesWritten < FResult.BytesRequested);
  AssertTrue(FResult.ErrorCode <> 0);
end;

procedure TLazSerialNativeWriteTests.BackpressureCanBeCancelled;
begin
  TLazSerial(FSerial).WriteDataAsync(StringOfChar('X', 2 * 1024 * 1024), 1000);
  TLazSerial(FSerial).CancelWrite;
  AssertTrue(TLazSerial(FSerial).WritePending);
  AwaitCompletion;
  AssertEquals(Ord(swoCancelled), Ord(FResult.Outcome));
  AssertEquals(0, FResult.ErrorCode);
end;

procedure TLazSerialNativeWriteTests.RestoresDescriptorFlags;
{$IFDEF DARWIN}
const
  // Set by the kernel after writing; F_SETFL cannot restore this marker.
  FWASWRITTEN = $00010000;
{$ENDIF}
var
  Flags, RestoredFlags: Integer;
begin
  Flags := fpFcntl(FNativeHandle, F_GETFL);
  AssertTrue('Read initial descriptor flags', Flags >= 0);
  TLazSerial(FSerial).WriteDataAsync(StringOfChar('X', 2 * 1024 * 1024), 20);
  AwaitCompletion;
  RestoredFlags := fpFcntl(FNativeHandle, F_GETFL);
  AssertTrue('Read restored descriptor flags', RestoredFlags >= 0);
  {$IFDEF DARWIN}
  Flags := Flags and not FWASWRITTEN;
  RestoredFlags := RestoredFlags and not FWASWRITTEN;
  {$ENDIF}
  AssertEquals(Flags, RestoredFlags);
end;

procedure TLazSerialNativeWriteTests.Received(Sender: TObject);
begin
  FReceived := FReceived + TLazSerial(Sender).ReadData;
end;

procedure TLazSerialNativeWriteTests.ReaderReceivesDuringBlockedWrite;
const
  Incoming = 'incoming';
var
  Started: QWord;
begin
  TLazSerial(FSerial).OnRxData := @Received;
  TLazSerial(FSerial).WriteDataAsync(StringOfChar('X', 2 * 1024 * 1024), 2000);
  AssertEquals(Length(Incoming), fpWrite(FMaster, Incoming[1], Length(Incoming)));
  Started := GetTickCount64;
  while (FReceived <> Incoming) and (GetTickCount64 - Started < 1000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  AssertEquals(Incoming, FReceived);
  AssertTrue('Input must be received while the write is still pending',
    TLazSerial(FSerial).WritePending);
  TLazSerial(FSerial).CancelWrite;
  AwaitCompletion;
  AssertEquals(Ord(swoCancelled), Ord(FResult.Outcome));
end;

procedure TLazSerialNativeWriteTests.LongDeadlineDoesNotOverflowPolling;
begin
  TLazSerial(FSerial).WriteDataAsync('long', High(Cardinal));
  AwaitCompletion;
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
  AssertEquals(4, FResult.BytesWritten);
end;
{$ENDIF}

initialization
  RegisterTest(TLazSerialAsyncComponentTests);
  RegisterTest(TLazSerialWriteOperationTests);
  {$IFDEF UNIX}
  RegisterTest(TLazSerialNativeWriteTests);
  {$ENDIF}

end.
