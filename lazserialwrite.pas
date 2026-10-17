unit LazSerialWrite;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, LazSerialCommon, LazSynaSer;

type
  TSerialWriteFinished = procedure(const AResult: TSerialWriteResult) of object;

  { The transport and an outstanding write share ownership of the native port.
    A detached worker never needs to access the component or its transport. }
  ISerialWritePort = interface
    function GetSerial: TBlockSerial;
  end;

  TSerialWritePort = class(TInterfacedObject, ISerialWritePort)
  private
    FSerial: TBlockSerial;
  public
    constructor Create(ASerial: TBlockSerial);
    destructor Destroy; override;
    function GetSerial: TBlockSerial;
  end;

  ISerialWriteOperation = interface
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    procedure DeferDelivery;
  end;

  TSerialWriteOperation = class(TInterfacedObject, ISerialWriteOperation)
  private
    FLock: TCriticalSection;
    FCancelEvent: TEvent;
    FStopReason: LongInt;
    FPort: ISerialWritePort;
    FData: AnsiString;
    FTimeoutMs: Cardinal;
    FStartedAt: QWord;
    FStarted, FCompleted, FCloseRequested, FClosing, FClosed: Boolean;
    FDelivered: Boolean;
    FDeliveryDeferred: Boolean;
    FResult: TSerialWriteResult;
    FOnFinished: TSerialWriteFinished;
    FQueuedReference: ISerialWriteOperation;
    procedure Deliver;
    procedure DropDelivery;
    procedure QueueDelivery;
    procedure Run;
    procedure RunClose;
    procedure WorkerFinished;
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); virtual; abstract;
    function StopRequested: Boolean;
    procedure SetStopped(var AResult: TSerialWriteResult);
    function RemainingMs: Cardinal;
    function WaitDelay(const ADelayMs: Cardinal): Boolean;
    property Data: AnsiString read FData;
    property Port: ISerialWritePort read FPort;
    property CancelEvent: TEvent read FCancelEvent;
  public
    constructor Create(const APort: ISerialWritePort; const AData: AnsiString;
      const AId: QWord; const ATimeoutMs: Cardinal;
      const AOnFinished: TSerialWriteFinished);
    destructor Destroy; override;
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    procedure DeferDelivery;
  end;

implementation

type
  TSerialWriteWorker = class(TThread)
  private
    FOperation: ISerialWriteOperation;
    FTarget: TSerialWriteOperation;
    FCloseOnly: Boolean;
    procedure FinishedOnMain(Sender: TObject);
  protected
    procedure Execute; override;
  public
    constructor Create(ATarget: TSerialWriteOperation; ACloseOnly: Boolean);
  end;

constructor TSerialWritePort.Create(ASerial: TBlockSerial);
begin
  inherited Create;
  FSerial := ASerial;
end;

destructor TSerialWritePort.Destroy;
begin
  FSerial.Free;
  inherited Destroy;
end;

function TSerialWritePort.GetSerial: TBlockSerial;
begin
  Result := FSerial;
end;

constructor TSerialWriteWorker.Create(ATarget: TSerialWriteOperation;
  ACloseOnly: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FOperation := ATarget;
  FTarget := ATarget;
  FCloseOnly := ACloseOnly;
  OnTerminate := @FinishedOnMain;
end;

procedure TSerialWriteWorker.Execute;
begin
  if FCloseOnly then
    FTarget.RunClose
  else
    FTarget.Run;
end;

procedure TSerialWriteWorker.FinishedOnMain(Sender: TObject);
begin
  FTarget.WorkerFinished;
end;

constructor TSerialWriteOperation.Create(const APort: ISerialWritePort;
  const AData: AnsiString; const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished);
begin
  inherited Create;
  if ATimeoutMs = 0 then
    raise EArgumentException.Create('Write timeout must be greater than zero');
  FLock := TCriticalSection.Create;
  FCancelEvent := TEvent.Create(nil, True, False, '');
  FPort := APort;
  FData := Copy(AData, 1, Length(AData));
  FTimeoutMs := ATimeoutMs;
  FResult.OperationId := AId;
  FResult.BytesRequested := Length(FData);
  FOnFinished := AOnFinished;
end;

destructor TSerialWriteOperation.Destroy;
begin
  FCancelEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TSerialWriteOperation.Start;
var
  Worker: TSerialWriteWorker;
begin
  if FStarted then
    raise EInvalidOperation.Create('Write operation has already started');
  FStartedAt := GetTickCount64;
  Worker := TSerialWriteWorker.Create(Self, False);
  try
    FStarted := True;
    Worker.Start;
  except
    Worker.Free;
    FStarted := False;
    raise;
  end;
end;

procedure TSerialWriteOperation.Cancel;
begin
  InterlockedCompareExchange(FStopReason, 1, 0);
  FCancelEvent.SetEvent;
end;

function TSerialWriteOperation.RemainingMs: Cardinal;
var
  Elapsed: QWord;
begin
  Elapsed := GetTickCount64 - FStartedAt;
  if Elapsed >= FTimeoutMs then
    Result := 0
  else
    Result := FTimeoutMs - Elapsed;
end;

function TSerialWriteOperation.StopRequested: Boolean;
begin
  if RemainingMs = 0 then
    if InterlockedCompareExchange(FStopReason, 2, 0) = 0 then
      FCancelEvent.SetEvent;
  Result := InterlockedCompareExchange(FStopReason, 0, 0) <> 0;
end;

procedure TSerialWriteOperation.SetStopped(var AResult: TSerialWriteResult);
begin
  if InterlockedCompareExchange(FStopReason, 0, 0) = 2 then
  begin
    AResult.Outcome := swoTimedOut;
    AResult.ErrorCode := ErrTimeout;
    AResult.ErrorMessage := TBlockSerial.GetErrorDesc(ErrTimeout);
  end
  else
  begin
    AResult.Outcome := swoCancelled;
    AResult.ErrorCode := 0;
    AResult.ErrorMessage := '';
  end;
end;

function TSerialWriteOperation.WaitDelay(const ADelayMs: Cardinal): Boolean;
var
  Delay: Cardinal;
begin
  if StopRequested then
    Exit(False);
  Delay := ADelayMs;
  if Delay > RemainingMs then
    Delay := RemainingMs;
  FCancelEvent.WaitFor(Delay);
  Result := not StopRequested;
end;

{ These delivery helpers run with FLock held. Queue entries own a reference,
  and detaching removes both the entry and that reference before destruction. }
procedure TSerialWriteOperation.DropDelivery;
begin
  TThread.RemoveQueuedEvents(nil, @Deliver);
  FQueuedReference := nil;
end;

procedure TSerialWriteOperation.QueueDelivery;
begin
  if Assigned(FOnFinished) and not FDelivered and not FDeliveryDeferred and
    (FQueuedReference = nil) then
  begin
    FQueuedReference := Self;
    TThread.ForceQueue(nil, @Deliver);
  end;
end;

procedure TSerialWriteOperation.Deliver;
var
  KeepAlive: ISerialWriteOperation;
  Callback: TSerialWriteFinished;
  WriteResult: TSerialWriteResult;
begin
  KeepAlive := Self;
  FLock.Acquire;
  try
    FQueuedReference := nil;
    FDelivered := True;
    Callback := FOnFinished;
    WriteResult := FResult;
  finally
    FLock.Release;
  end;
  if Assigned(Callback) then
    Callback(WriteResult);
end;

procedure TSerialWriteOperation.Detach;
begin
  FLock.Acquire;
  try
    FOnFinished := nil;
    DropDelivery;
  finally
    FLock.Release;
  end;
end;

procedure TSerialWriteOperation.ClosePort;
var
  NeedsWorker: Boolean;
  Worker: TSerialWriteWorker;
begin
  Cancel;
  FLock.Acquire;
  try
    FCloseRequested := True;
    FDeliveryDeferred := False;
    DropDelivery;
    NeedsWorker := FCompleted and not FClosed and not FClosing;
    if NeedsWorker then
      FClosing := True
    else if FClosed then
      QueueDelivery;
  finally
    FLock.Release;
  end;
  if NeedsWorker then
  begin
    Worker := TSerialWriteWorker.Create(Self, True);
    try
      Worker.Start;
    except
      Worker.Free;
      raise;
    end;
  end;
end;

procedure TSerialWriteOperation.DeferDelivery;
begin
  FLock.Acquire;
  try
    FDeliveryDeferred := True;
    DropDelivery;
  finally
    FLock.Release;
  end;
end;

procedure TSerialWriteOperation.Run;
var
  WriteResult: TSerialWriteResult;
  NeedsClose: Boolean;
begin
  WriteResult := FResult;
  try
    ExecuteWrite(WriteResult);
  except
    on E: Exception do
    begin
      WriteResult.Outcome := swoFailed;
      if E is ESynaSerError then
      begin
        WriteResult.ErrorCode := ESynaSerError(E).ErrorCode;
        WriteResult.ErrorMessage := ESynaSerError(E).ErrorMessage;
      end
      else
      begin
        WriteResult.ErrorCode := 0;
        WriteResult.ErrorMessage := E.Message;
      end;
    end;
  end;
  FLock.Acquire;
  try
    FResult := WriteResult;
    FCompleted := True;
    NeedsClose := FCloseRequested;
    if NeedsClose then
      FClosing := True;
  finally
    FLock.Release;
  end;
  if NeedsClose then
    RunClose;
end;

procedure TSerialWriteOperation.RunClose;
begin
  try
    try
      if FPort <> nil then
        FPort.GetSerial.CloseSocket;
    except
      // CloseSocket releases the handle even on an I/O error. Preserve the
      // operation result rather than replacing it with a cleanup exception.
      on E: ESynaSerError do ;
    end;
  finally
    FLock.Acquire;
    try
      FClosed := True;
      FClosing := False;
    finally
      FLock.Release;
    end;
  end;
end;

procedure TSerialWriteOperation.WorkerFinished;
begin
  // Queue from the main thread: FPC removes even Queue(nil, ...) entries
  // carrying a worker's thread ID when that worker frees itself.
  FLock.Acquire;
  try
    if FCompleted and not FClosing then
      QueueDelivery;
  finally
    FLock.Release;
  end;
end;

end.
