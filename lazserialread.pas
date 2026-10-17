unit LazSerialRead;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, SyncObjs, LazSerialCommon, LazSerialStatistics, LazSynaSer, LazSerialWrite;

type
  TSerialReadChanged = procedure of object;

  ISerialReadOperation = interface
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    function DataAvailable(ALineMode: Boolean): Boolean;
    function TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
    function GetFailure(out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function GetClosePending: Boolean;
  end;

  // Optional capability: existing custom read operations remain compatible.
  ISerialReadUntilOperation = interface
    ['{F5E14AE8-748F-47E3-B30D-F9EFCD9BCF79}']
    function TryReadUntil(const ATerminator: RawByteString;
      out AData: RawByteString; AMaxLength: Integer): Boolean;
  end;

  { Owns receive state and delivery independently of the component. Storage
    and the parser belong to the retained Synaser instance, not to a queue. }
  TSerialReadOperation = class(TInterfacedObject, ISerialReadOperation,
    ISerialReadUntilOperation)
  private
    FPort: ISerialWritePort;
    FLifecycle: ISerialPortLifecycle;
    FLock: TCriticalSection;
    FCancel: TEvent;
    FStopping: LongInt;
    FStarted, FCompleted, FCloseRequested, FLineMode: Boolean;
    FLimit, FMaxBandwidth, FError: Integer;
    FErrorMessage: string;
    FReceivedForStatus: QWord;
    FStatistics: ISerialStatisticsState;
    FOnChanged: TSerialReadChanged;
    FQueuedReference: ISerialReadOperation;
    procedure Run;
    procedure Deliver;
    procedure QueueChanged;
    procedure WorkerFinished;
    procedure Fail(AError: Integer; const AMessage: string);
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; virtual; abstract;
    function StopRequested: Boolean;
    function WaitDelay(ADelay: Cardinal): Boolean;
    property Port: ISerialWritePort read FPort;
  public
    constructor Create(const APort: ISerialWritePort; ALimit: Integer;
      AOnChanged: TSerialReadChanged);
    destructor Destroy; override;
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    function DataAvailable(ALineMode: Boolean): Boolean;
    function TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
    function TryReadUntil(const ATerminator: RawByteString;
      out AData: RawByteString; AMaxLength: Integer): Boolean;
    function GetFailure(out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function GetClosePending: Boolean;
  end;

implementation

type
  TSerialReadWorker = class(TThread)
  private
    FOperation: ISerialReadOperation;
    FTarget: TSerialReadOperation;
    procedure FinishedOnMain(Sender: TObject);
  protected
    procedure Execute; override;
  public
    constructor Create(ATarget: TSerialReadOperation);
  end;

constructor TSerialReadWorker.Create(ATarget: TSerialReadOperation);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FTarget := ATarget;
  FOperation := ATarget;
  OnTerminate := @FinishedOnMain;
end;

procedure TSerialReadWorker.Execute;
begin
  FTarget.Run;
end;

procedure TSerialReadWorker.FinishedOnMain(Sender: TObject);
begin
  FTarget.WorkerFinished;
end;

constructor TSerialReadOperation.Create(const APort: ISerialWritePort;
  ALimit: Integer; AOnChanged: TSerialReadChanged);
begin
  inherited Create;
  if ALimit <= 0 then raise EArgumentException.Create('Receive limit must be positive');
  FLock := TCriticalSection.Create;
  FCancel := TEvent.Create(nil, True, False, '');
  FPort := APort;
  FStatistics := APort.GetSerial.StatisticsState;
  if not Supports(FPort, ISerialPortLifecycle, FLifecycle) then
    raise EInvalidOperation.Create('Port does not support shared receive lifetime');
  FLimit := ALimit;
  FMaxBandwidth := FPort.GetSerial.MaxRecvBandwidth;
  FPort.GetSerial.ConfigureReadBuffer(ALimit);
  FOnChanged := AOnChanged;
end;

destructor TSerialReadOperation.Destroy;
begin
  FCancel.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TSerialReadOperation.Start;
var Worker: TSerialReadWorker;
begin
  if FStarted then raise EInvalidOperation.Create('Reader has already started');
  FLifecycle.AcquireIO(True);
  try
    Worker := TSerialReadWorker.Create(Self);
    try
      FStarted := True;
      Worker.Start;
    except
      Worker.Free;
      FStarted := False;
      raise;
    end;
  except
    FLifecycle.ReleaseIO(True);
    raise;
  end;
end;

procedure TSerialReadOperation.Cancel;
begin
  InterlockedExchange(FStopping, 1);
  FCancel.SetEvent;
end;

function TSerialReadOperation.StopRequested: Boolean;
begin
  Result := InterlockedCompareExchange(FStopping, 0, 0) <> 0;
end;

function TSerialReadOperation.WaitDelay(ADelay: Cardinal): Boolean;
begin
  if not StopRequested then FCancel.WaitFor(ADelay);
  Result := not StopRequested;
end;

procedure TSerialReadOperation.QueueChanged;
begin
  // Caller holds FLock. One entry owns one reference, independent of component.
  if Assigned(FOnChanged) and (FQueuedReference = nil) then
  begin
    FQueuedReference := Self;
    TThread.ForceQueue(nil, @Deliver);
  end;
end;

procedure TSerialReadOperation.WorkerFinished;
begin
  FLock.Acquire;
  try
    // Replace any worker-associated entry before FPC removes that thread's
    // queued callbacks at destruction. The replacement belongs to main.
    TThread.RemoveQueuedEvents(nil, @Deliver);
    FQueuedReference := nil;
    QueueChanged;
  finally FLock.Release; end;
end;

procedure TSerialReadOperation.Deliver;
var
  KeepAlive: ISerialReadOperation;
  Callback: TSerialReadChanged;
  Status: THookSerialStatus;
  Received: QWord;
begin
  KeepAlive := Self;
  FLock.Acquire;
  try
    FQueuedReference := nil;
    Received := FReceivedForStatus;
    FReceivedForStatus := 0;
    Status := nil;
    if Assigned(FOnChanged) and not FCloseRequested then Status := FPort.GetSerial.OnStatus;
  finally FLock.Release; end;
  try
    if (Received > 0) and Assigned(Status) then
      Status(FPort.GetSerial, HR_ReadCount, UIntToStr(Received));
  except
    FLock.Acquire;
    try QueueChanged;
    finally FLock.Release; end;
    raise;
  end;
  FLock.Acquire;
  try Callback := FOnChanged;
  finally FLock.Release; end;
  // A status handler can destroy the component and detach this operation.
  if Assigned(Callback) then Callback;
end;

procedure TSerialReadOperation.Detach;
begin
  FLock.Acquire;
  try
    FOnChanged := nil;
    TThread.RemoveQueuedEvents(nil, @Deliver);
    FQueuedReference := nil;
  finally FLock.Release; end;
end;

procedure TSerialReadOperation.ClosePort;
begin
  Cancel;
  FLock.Acquire;
  try
    FCloseRequested := True;
    if not FStarted then FCompleted := True;
  finally FLock.Release; end;
  FLifecycle.RequestClose;
end;

function TSerialReadOperation.GetClosePending: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCloseRequested and (not FCompleted or FLifecycle.GetClosePending);
  finally FLock.Release; end;
end;

function TSerialReadOperation.DataAvailable(ALineMode: Boolean): Boolean;
begin
  FLock.Acquire;
  try
    if FLineMode <> ALineMode then
    begin
      FLineMode := ALineMode;
      QueueChanged;
    end;
    Result := not FCloseRequested and (FError = 0) and (FErrorMessage = '') and
      FPort.GetSerial.BufferedDataAvailable(ALineMode);
  finally FLock.Release; end;
end;

function TSerialReadOperation.TryReadData(ALineMode: Boolean;
  out AData: AnsiString): Boolean;
begin
  AData := '';
  FLock.Acquire;
  try
    if FCloseRequested or (FError <> 0) or (FErrorMessage <> '') then Exit(False);
    try
      try
        Result := FPort.GetSerial.TryReadBuffered(ALineMode, AData);
      except
        on E: ESynaSerError do
        begin
          if (FStatistics <> nil) and (E.ErrorCode = ErrMaxBuffer) then
            FStatistics.RecordError(E.ErrorCode, E.ErrorMessage);
          raise;
        end;
      end;
    finally
      // Reading one result constitutes progress; notify for any remaining one.
      if FPort.GetSerial.BufferedDataAvailable(ALineMode) then QueueChanged;
    end;
  finally FLock.Release; end;
end;

function TSerialReadOperation.TryReadUntil(const ATerminator: RawByteString;
  out AData: RawByteString; AMaxLength: Integer): Boolean;
begin
  AData := '';
  FLock.Acquire;
  try
    if FCloseRequested or (FError <> 0) or (FErrorMessage <> '') then Exit(False);
    try
      Result := FPort.GetSerial.TryReadBufferedUntil(ATerminator, AData, AMaxLength);
    except
      on E: ESynaSerError do
      begin
        if (FStatistics <> nil) and (E.ErrorCode = ErrMaxBuffer) then
          FStatistics.RecordError(E.ErrorCode, E.ErrorMessage);
        raise;
      end;
    end;
    // Only consuming a result is progress. A partial or oversized message must
    // wait for new input or an explicit retry, without a notification loop.
    if Result and FPort.GetSerial.BufferedDataAvailable(False) then QueueChanged;
  finally FLock.Release; end;
end;

function TSerialReadOperation.GetFailure(out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
begin
  FLock.Acquire;
  try
    AErrorCode := FError;
    AErrorMessage := FErrorMessage;
    Result := (FError <> 0) or (FErrorMessage <> '');
  finally FLock.Release; end;
end;

procedure TSerialReadOperation.Fail(AError: Integer; const AMessage: string);
begin
  FLock.Acquire;
  try
    if (FError = 0) and (FErrorMessage = '') then
    begin
      FError := AError;
      FErrorMessage := AMessage;
      if FStatistics <> nil then FStatistics.RecordError(AError, AMessage);
    end;
    QueueChanged;
  finally FLock.Release; end;
end;

procedure TSerialReadOperation.Run;
var
  Chunk: AnsiString;
  Available, Received, Error: Integer;
  Started, Total, Due, Elapsed: QWord;
begin
  Started := GetTickCount64;
  Total := 0;
  try
    try
      while not StopRequested do
      begin
        if FMaxBandwidth > 0 then
        begin
          Due := (Total * 1000) div Cardinal(FMaxBandwidth);
          Elapsed := GetTickCount64 - Started;
          if Due > Elapsed then
          begin
            if Due - Elapsed > 10 then WaitDelay(10)
            else WaitDelay(Due - Elapsed);
            Continue;
          end;
        end;
        FLock.Acquire;
        try Available := FLimit - FPort.GetSerial.WaitingDataEx;
        finally FLock.Release; end;
        if Available <= 0 then
        begin
          Fail(ErrReadBufferOverflow, 'Receive buffer limit exceeded');
          Break;
        end;
        if Available > cSerialChunk then Available := cSerialChunk;
        if (FMaxBandwidth > 0) and (Available > FMaxBandwidth div 100 + 1) then
          Available := FMaxBandwidth div 100 + 1;
        // Capacity is reserved by this sole producer before starting I/O.
        // The consumer can only increase the remaining space during this read.
        SetLength(Chunk, Available);
        Error := ReadChunk(Pointer(Chunk), Available, Received);
        if (Received < 0) or (Received > Available) then
          raise EInvalidOperation.Create('Invalid native receive count');
        if FStatistics <> nil then FStatistics.AddReceived(Received);
        if StopRequested then Break;
        if Error <> 0 then
        begin
          Fail(Error, TBlockSerial.GetErrorDesc(Error));
          Break;
        end;
        if Received = 0 then
        begin
          WaitDelay(1);
          Continue;
        end;
        SetLength(Chunk, Received);
        FLock.Acquire;
        try
          FPort.GetSerial.AppendReadBuffer(Chunk);
          Inc(FReceivedForStatus, Received);
          QueueChanged;
        finally FLock.Release; end;
        Inc(Total, Received);
      end;
    except
      on E: ESynaSerError do Fail(E.ErrorCode, E.ErrorMessage);
      on E: Exception do Fail(0, E.Message);
    end;
  finally
    try
      try
        FLifecycle.ReleaseIO(True);
      except
        on E: ESynaSerError do Fail(E.ErrorCode, E.ErrorMessage);
        on E: Exception do Fail(0, E.Message);
      end;
    finally
      FLock.Acquire;
      try FCompleted := True;
      finally FLock.Release; end;
    end;
  end;
end;

end.
