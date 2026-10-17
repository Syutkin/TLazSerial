unit LazSerialWrite;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, LazSerialCommon, LazSerialStatistics, LazSynaSer
  {$IFDEF MSWINDOWS}, Windows{$ELSE}, BaseUnix{$ENDIF};

type
  TSerialWriteFinished = procedure(const AResult: TSerialWriteResult) of object;

  { The transport and outstanding operations share ownership of the native port.
    A detached worker never needs to access the component or its transport. }
  ISerialWritePort = interface
    function GetSerial: TBlockSerial;
  end;

  ISerialPortLifecycle = interface
    ['{A0BB4841-4671-4A93-AD3E-948C1F0F99E3}']
    procedure AcquireIO(ARead: Boolean);
    procedure ReleaseIO(ARead: Boolean);
    procedure RequestClose;
    function GetClosePending: Boolean;
  end;

  TSerialWritePort = class(TInterfacedObject, ISerialWritePort, ISerialPortLifecycle)
  private
    FSerial: TBlockSerial;
    FLock: SyncObjs.TCriticalSection;
    FReaders, FWriters: Integer;
    FReadSettings, FConfiguring, FRestoring: Boolean;
    {$IFDEF MSWINDOWS}
    FPreviousTimeouts: TCommTimeouts;
    {$ELSE}
    FPreviousFlags: Integer;
    {$ENDIF}
    FCloseRequested, FClosing, FClosed: Boolean;
    procedure ConfigureReader;
    procedure RestoreReader;
    procedure StartClose;
    procedure RunClose;
  public
    constructor Create(ASerial: TBlockSerial);
    destructor Destroy; override;
    function GetSerial: TBlockSerial;
    procedure AcquireIO(ARead: Boolean);
    procedure ReleaseIO(ARead: Boolean);
    procedure RequestClose;
    function GetClosePending: Boolean;
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
    FLock: SyncObjs.TCriticalSection;
    FCancelEvent: TEvent;
    FStopReason: LongInt;
    FPort: ISerialWritePort;
    FLifecycle: ISerialPortLifecycle;
    FReserved: Boolean;
    FData: AnsiString;
    FStatistics: ISerialStatisticsState;
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
    property Statistics: ISerialStatisticsState read FStatistics;
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
  TSerialPortCloseWorker = class(TThread)
  private
    FOwner: TSerialWritePort;
    FReference: ISerialPortLifecycle;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TSerialWritePort);
  end;

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

procedure SetWriteFailure(var AResult: TSerialWriteResult; E: Exception);
begin
  AResult.Outcome := swoFailed;
  if E is ESynaSerError then
  begin
    AResult.ErrorCode := ESynaSerError(E).ErrorCode;
    AResult.ErrorMessage := ESynaSerError(E).ErrorMessage;
  end
  else
  begin
    AResult.ErrorCode := 0;
    AResult.ErrorMessage := E.Message;
  end;
end;

constructor TSerialWritePort.Create(ASerial: TBlockSerial);
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
  FSerial := ASerial;
end;

destructor TSerialWritePort.Destroy;
begin
  FSerial.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSerialWritePort.GetSerial: TBlockSerial;
begin
  Result := FSerial;
end;

constructor TSerialPortCloseWorker.Create(AOwner: TSerialWritePort);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FOwner := AOwner;
  FReference := AOwner;
end;

procedure TSerialPortCloseWorker.Execute;
begin
  FOwner.RunClose;
end;

procedure TSerialWritePort.ConfigureReader;
{$IFDEF MSWINDOWS}
var Timeouts: TCommTimeouts;
{$ELSE}
var Error: Integer;
{$ENDIF}
begin
  if FReadSettings or (FSerial.Handle = INVALID_HANDLE_VALUE) then Exit;
  {$IFDEF MSWINDOWS}
  if not Windows.GetCommTimeouts(FSerial.Handle, FPreviousTimeouts) then
    RaiseLastOSError;
  Timeouts := FPreviousTimeouts;
  Timeouts.ReadIntervalTimeout := MAXDWORD;
  Timeouts.ReadTotalTimeoutMultiplier := 0;
  Timeouts.ReadTotalTimeoutConstant := 10;
  if not Windows.SetCommTimeouts(FSerial.Handle, Timeouts) then RaiseLastOSError;
  {$ELSE}
  FPreviousFlags := fpFcntl(FSerial.Handle, F_GETFL);
  if (FPreviousFlags < 0) or
    (fpFcntl(FSerial.Handle, F_SETFL, FPreviousFlags or O_NONBLOCK) < 0) then
  begin
    Error := fpGetErrno;
    raise EOSError.CreateFmt('Cannot configure native reader: %d', [Error]);
  end;
  {$ENDIF}
  FReadSettings := True;
end;

procedure TSerialWritePort.RestoreReader;
{$IFDEF MSWINDOWS}
var Timeouts: TCommTimeouts;
{$ENDIF}
begin
  if not FReadSettings then Exit;
  {$IFDEF MSWINDOWS}
  // All operation leases have ended, so no writer can race this merge.
  if Windows.GetCommTimeouts(FSerial.Handle, Timeouts) then
  begin
    Timeouts.ReadIntervalTimeout := FPreviousTimeouts.ReadIntervalTimeout;
    Timeouts.ReadTotalTimeoutMultiplier := FPreviousTimeouts.ReadTotalTimeoutMultiplier;
    Timeouts.ReadTotalTimeoutConstant := FPreviousTimeouts.ReadTotalTimeoutConstant;
    Windows.SetCommTimeouts(FSerial.Handle, Timeouts);
  end;
  {$ELSE}
  fpFcntl(FSerial.Handle, F_SETFL, FPreviousFlags);
  {$ENDIF}
  FReadSettings := False;
end;

procedure TSerialWritePort.AcquireIO(ARead: Boolean);
begin
  FLock.Acquire;
  try
    if FClosed and FSerial.InstanceActive then
    begin
      FClosed := False;
      FCloseRequested := False;
    end;
    if FCloseRequested or FConfiguring or FRestoring then
      raise EInvalidOperation.Create('Serial port is closing or configuring');
    if ARead then
    begin
      if FReaders <> 0 then raise EInvalidOperation.Create('A reader already owns the port');
      FConfiguring := True;
      Inc(FReaders);
    end
    else Inc(FWriters);
  finally
    FLock.Release;
  end;
  if ARead then
  begin
    // Opening already configures the driver synchronously. Do not hold the
    // lifecycle lock across its IOCTLs: cleanup observers only need memory.
    try
      try
        ConfigureReader;
      except
        FLock.Acquire;
        try Dec(FReaders);
        finally FLock.Release; end;
        raise;
      end;
    finally
      FLock.Acquire;
      try
        FConfiguring := False;
        StartClose;
      finally FLock.Release; end;
    end;
  end;
end;

procedure TSerialWritePort.StartClose;
var
  Worker: TSerialPortCloseWorker;
begin
  // Called under FLock. The worker owns the port even after transport teardown.
  if not FCloseRequested or FClosing or FClosed or FConfiguring or FRestoring or
    (FReaders <> 0) or (FWriters <> 0) then Exit;
  Worker := nil;
  FClosing := True;
  try
    Worker := TSerialPortCloseWorker.Create(Self);
    Worker.Start;
  except
    // No new I/O can enter. Keep the closing reservation, but never hold the
    // lifecycle lock across synchronous recovery from a worker startup error.
    FLock.Release;
    try
      try
        try
          if Worker <> nil then Worker.FreeOnTerminate := False;
          Worker.Free;
        finally RunClose; end;
      except
        // RunClose finalizes the state; report the original startup error.
      end;
    finally FLock.Acquire; end;
    raise;
  end;
end;

procedure TSerialWritePort.ReleaseIO(ARead: Boolean);
var NeedsRestore: Boolean;
begin
  FLock.Acquire;
  try
    if ARead then
    begin
      if FReaders = 0 then raise EInvalidOperation.Create('Unbalanced receive lease');
      Dec(FReaders);
    end
    else
    begin
      if FWriters = 0 then raise EInvalidOperation.Create('Unbalanced write lease');
      Dec(FWriters);
    end;
    NeedsRestore := (FReaders = 0) and (FWriters = 0) and FReadSettings;
    if NeedsRestore then FRestoring := True else StartClose;
  finally
    FLock.Release;
  end;
  if NeedsRestore then
    try
      // Restoring driver settings can itself wait in the driver. Close and
      // ClosePending must not contend on a lock held across those calls.
      RestoreReader;
    finally
      FLock.Acquire;
      try
        FRestoring := False;
        StartClose;
      finally FLock.Release; end;
    end;
end;

procedure TSerialWritePort.RequestClose;
begin
  FLock.Acquire;
  try
    FCloseRequested := True;
    StartClose;
  finally
    FLock.Release;
  end;
end;

function TSerialWritePort.GetClosePending: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCloseRequested and not FClosed;
  finally
    FLock.Release;
  end;
end;

procedure TSerialWritePort.RunClose;
begin
  try
    try
      FSerial.CloseSocket;
    except
      on E: ESynaSerError do ; // Preserve the operation's original error.
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
  FLock := SyncObjs.TCriticalSection.Create;
  FCancelEvent := TEvent.Create(nil, True, False, '');
  FPort := APort;
  if APort <> nil then FStatistics := APort.GetSerial.StatisticsState;
  Supports(FPort, ISerialPortLifecycle, FLifecycle);
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
  if FLifecycle <> nil then
  begin
    FLifecycle.AcquireIO(False);
    FReserved := True;
  end;
  try
    Worker := TSerialWriteWorker.Create(Self, False);
    try
      FStarted := True;
      Worker.Start;
    except
      Worker.Free;
      FStarted := False;
      raise;
    end;
  except
    if FReserved then
    begin
      FReserved := False;
      FLifecycle.ReleaseIO(False);
    end;
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
    Worker := nil;
    try
      Worker := TSerialWriteWorker.Create(Self, True);
      Worker.Start;
    except
      if Worker <> nil then
      begin
        Worker.OnTerminate := nil;
        Worker.FreeOnTerminate := False;
      end;
      Worker.Free;
      try
        try RunClose;
        except
          // Preserve the startup error after RunClose finalizes the state.
        end;
      finally WorkerFinished; end;
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
    on E: Exception do SetWriteFailure(WriteResult, E);
  end;
  if FReserved then
  begin
    FReserved := False;
    try
      FLifecycle.ReleaseIO(False);
    except
      on E: Exception do
        if WriteResult.Outcome = swoCompleted then
          SetWriteFailure(WriteResult, E);
    end;
  end;
  if (FStatistics <> nil) and
    (WriteResult.Outcome in [swoFailed, swoTimedOut]) then
    FStatistics.RecordError(WriteResult.ErrorCode, WriteResult.ErrorMessage);
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
      if FLifecycle <> nil then
      begin
        FLifecycle.RequestClose;
        while FLifecycle.GetClosePending do Sleep(1);
      end
      else if FPort <> nil then
        FPort.GetSerial.CloseSocket;
    except
      // CloseSocket releases the handle even on an I/O error. Preserve the
      // operation result rather than replacing it with a cleanup exception.
      on E: ESynaSerError do ;
      on E: Exception do
      begin
        FLock.Acquire;
        try
          if FResult.Outcome = swoCompleted then SetWriteFailure(FResult, E);
        finally FLock.Release; end;
      end;
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
