unit LazSerialNativeWrite;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, LazSerialCommon, LazSerialWrite, LazSynaSer
  {$IFDEF MSWINDOWS}, Windows{$ELSE}, BaseUnix, Termio{$ENDIF};

type
  { Uses captured port settings and operation-local errors. Never calls the
    shared TBlockSerial read/write methods from the worker thread. }
  TNativeSerialWriteOperation = class(TSerialWriteOperation)
  private
    FHandle: THandle;
    FToggleRTS, FTestDSR, FTestCTS: Boolean;
    FMaxBandwidth: Integer;
    function WriteChunk(ABuffer: Pointer; ACount: Integer;
      out ATransferred: Integer): Integer;
    function OutputPending(out ACount: Integer): Integer;
    function Drain(var AResult: TSerialWriteResult): Boolean;
    function SetRTSValue(AValue: Boolean): Integer;
    function CheckSignals: Integer;
    procedure SetError(var AResult: TSerialWriteResult; AError: Integer);
    procedure PurgeOutput;
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); override;
    {$IFDEF MSWINDOWS}
    function StartIO(ABuffer: Pointer; ACount: DWORD; out ATransferred: DWORD;
      var AOverlapped: TOverlapped): Boolean; virtual;
    function WaitIO(AEvent: THandle; ATimeout: DWORD): DWORD; virtual;
    function FinishIO(var AOverlapped: TOverlapped; out ATransferred: DWORD;
      AWait: Boolean): Boolean; virtual;
    function AbortIO: Boolean; virtual;
    function ReadTimeouts(out ATimeouts: TCommTimeouts): Boolean; virtual;
    function WriteTimeouts(const ATimeouts: TCommTimeouts): Boolean; virtual;
    {$ENDIF}
  public
    constructor Create(const APort: ISerialWritePort; const AData: AnsiString;
      const AId: QWord; const ATimeoutMs: Cardinal;
      const AOnFinished: TSerialWriteFinished);
  end;

implementation

type
  TSerialSettingsAccess = class(TBlockSerial);

constructor TNativeSerialWriteOperation.Create(const APort: ISerialWritePort;
  const AData: AnsiString; const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished);
var
  Serial: TBlockSerial;
begin
  inherited Create(APort, AData, AId, ATimeoutMs, AOnFinished);
  Serial := APort.GetSerial;
  FHandle := Serial.Handle;
  FToggleRTS := TSerialSettingsAccess(Serial).FRTSToggle;
  FTestDSR := Serial.TestDSR;
  FTestCTS := Serial.TestCTS;
  FMaxBandwidth := Serial.MaxSendBandwidth;
end;

procedure TNativeSerialWriteOperation.SetError(var AResult: TSerialWriteResult;
  AError: Integer);
begin
  AResult.Outcome := swoFailed;
  AResult.ErrorCode := AError;
  AResult.ErrorMessage := TBlockSerial.GetErrorDesc(AError);
end;

{$IFDEF MSWINDOWS}
function TNativeSerialWriteOperation.StartIO(ABuffer: Pointer; ACount: DWORD;
  out ATransferred: DWORD; var AOverlapped: TOverlapped): Boolean;
begin
  Result := Windows.WriteFile(FHandle, ABuffer^, ACount, ATransferred, @AOverlapped);
end;

function TNativeSerialWriteOperation.WaitIO(AEvent: THandle;
  ATimeout: DWORD): DWORD;
begin
  Result := Windows.WaitForSingleObject(AEvent, ATimeout);
end;

function TNativeSerialWriteOperation.FinishIO(var AOverlapped: TOverlapped;
  out ATransferred: DWORD; AWait: Boolean): Boolean;
begin
  Result := Windows.GetOverlappedResult(FHandle, AOverlapped, ATransferred, AWait);
end;

function TNativeSerialWriteOperation.AbortIO: Boolean;
begin
  Result := Windows.PurgeComm(FHandle, PURGE_TXABORT);
end;

function TNativeSerialWriteOperation.ReadTimeouts(
  out ATimeouts: TCommTimeouts): Boolean;
begin
  Result := Windows.GetCommTimeouts(FHandle, ATimeouts);
end;

function TNativeSerialWriteOperation.WriteTimeouts(
  const ATimeouts: TCommTimeouts): Boolean;
begin
  Result := Windows.SetCommTimeouts(FHandle, ATimeouts);
end;

function TNativeSerialWriteOperation.WriteChunk(ABuffer: Pointer;
  ACount: Integer; out ATransferred: Integer): Integer;
var
  Overlapped: TOverlapped;
  Count, CompletionError, WaitResult, Delay: DWORD;
  WaitCompletion: Boolean;
begin
  Result := 0;
  ATransferred := 0;
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  Overlapped.hEvent := Windows.CreateEvent(nil, True, False, nil);
  if Overlapped.hEvent = 0 then
    Exit(Windows.GetLastError);
  try
    Count := 0;
    if StartIO(ABuffer, ACount, Count, Overlapped) then
    begin
      ATransferred := Count;
      Exit;
    end;
    Result := Windows.GetLastError;
    if Result <> ERROR_IO_PENDING then
      Exit;
    Result := 0;
    WaitCompletion := False;
    repeat
      // Observe an already completed operation before requesting cancellation.
      WaitResult := WaitIO(Overlapped.hEvent, 0);
      if WaitResult = WAIT_OBJECT_0 then
        Break;
      if WaitResult <> WAIT_TIMEOUT then
      begin
        if WaitResult = WAIT_FAILED then
          Result := Windows.GetLastError
        else
          Result := ERROR_GEN_FAILURE;
        WaitCompletion := True;
        Break;
      end;
      if StopRequested then
      begin
        Result := ErrTimeout;
        WaitCompletion := True;
        Break;
      end;
      Delay := RemainingMs;
      if Delay > 10 then
        Delay := 10;
      WaitDelay(Delay);
    until False;
    if WaitCompletion then
      AbortIO;
    // Even failed cancellation must reach a terminal result before releasing
    // OVERLAPPED, its event or the buffer. This wait is confined to the worker.
    repeat
      Count := 0;
      if FinishIO(Overlapped, Count, WaitCompletion) then
        Break;
      CompletionError := Windows.GetLastError;
      if CompletionError <> ERROR_IO_INCOMPLETE then
      begin
        if Result = 0 then
          Result := CompletionError;
        Break;
      end;
      WaitCompletion := True;
    until False;
    ATransferred := Count;
  finally
    Windows.CloseHandle(Overlapped.hEvent);
  end;
end;
{$ELSE}
function TNativeSerialWriteOperation.WriteChunk(ABuffer: Pointer;
  ACount: Integer; out ATransferred: Integer): Integer;
var
  PollDescriptor: TPollFD;
  Ready: Integer;
  Delay: Cardinal;
begin
  Result := 0;
  ATransferred := 0;
  FillChar(PollDescriptor, SizeOf(PollDescriptor), 0);
  PollDescriptor.fd := FHandle;
  PollDescriptor.events := POLLOUT;
  repeat
    Result := 0;
    if StopRequested then
      Exit;
    Delay := RemainingMs;
    if Delay > 10 then
      Delay := 10;
    Ready := fpPoll(@PollDescriptor, 1, Delay);
    if Ready < 0 then
    begin
      Result := fpGetErrno;
      if Result = ESysEINTR then
        Continue;
      Exit;
    end;
    if Ready = 0 then
      Continue;
    if (PollDescriptor.revents and (POLLERR or POLLHUP or POLLNVAL)) <> 0 then
      Exit(ErrNoDeviceAnswer);
    ATransferred := fpWrite(FHandle, ABuffer^, ACount);
    if ATransferred >= 0 then
      Exit;
    ATransferred := 0;
    Result := fpGetErrno;
    if (Result <> ESysEINTR) and (Result <> ESysEAGAIN) then
      Exit;
    Result := 0;
  until False;
end;
{$ENDIF}

function TNativeSerialWriteOperation.OutputPending(out ACount: Integer): Integer;
{$IFDEF MSWINDOWS}
var
  Stat: TComStat;
  Errors: DWORD;
{$ENDIF}
begin
  Result := 0;
  ACount := 0;
  {$IFDEF MSWINDOWS}
  if not Windows.ClearCommError(FHandle, Errors, @Stat) then
    Result := Windows.GetLastError
  else
    ACount := Stat.cbOutQue;
  {$ELSE}
  if fpIoctl(FHandle, TIOCOUTQ, @ACount) < 0 then
    Result := fpGetErrno;
  {$ENDIF}
end;

function TNativeSerialWriteOperation.Drain(var AResult: TSerialWriteResult): Boolean;
var
  Count, Error: Integer;
begin
  Result := False;
  repeat
    if StopRequested then
    begin
      SetStopped(AResult);
      Exit;
    end;
    Error := OutputPending(Count);
    if Error <> 0 then
    begin
      SetError(AResult, Error);
      Exit;
    end;
    if Count = 0 then
      Exit(True);
    WaitDelay(1);
  until False;
end;

function TNativeSerialWriteOperation.SetRTSValue(AValue: Boolean): Integer;
{$IFNDEF MSWINDOWS}
var
  Flag: Integer;
{$ENDIF}
begin
  Result := 0;
  {$IFDEF MSWINDOWS}
  if AValue then
  begin
    if not Windows.EscapeCommFunction(FHandle, SETRTS) then
      Result := Windows.GetLastError;
  end
  else if not Windows.EscapeCommFunction(FHandle, CLRRTS) then
    Result := Windows.GetLastError;
  {$ELSE}
  Flag := TIOCM_RTS;
  if AValue then
  begin
    if fpIoctl(FHandle, TIOCMBIS, @Flag) < 0 then
      Result := fpGetErrno;
  end
  else if fpIoctl(FHandle, TIOCMBIC, @Flag) < 0 then
    Result := fpGetErrno;
  {$ENDIF}
end;

function TNativeSerialWriteOperation.CheckSignals: Integer;
var
  Signals: {$IFDEF MSWINDOWS}DWORD{$ELSE}Integer{$ENDIF};
begin
  Result := 0;
  if not FTestDSR and not FTestCTS then
    Exit;
  {$IFDEF MSWINDOWS}
  if not Windows.GetCommModemStatus(FHandle, Signals) then
    Exit(Windows.GetLastError);
  if (FTestDSR and ((Signals and MS_DSR_ON) = 0)) or
    (FTestCTS and ((Signals and MS_CTS_ON) = 0)) then
    Result := ErrNoDeviceAnswer;
  {$ELSE}
  if fpIoctl(FHandle, TIOCMGET, @Signals) < 0 then
    Exit(fpGetErrno);
  if (FTestDSR and ((Signals and TIOCM_DSR) = 0)) or
    (FTestCTS and ((Signals and TIOCM_CTS) = 0)) then
    Result := ErrNoDeviceAnswer;
  {$ENDIF}
end;

procedure TNativeSerialWriteOperation.PurgeOutput;
begin
  {$IFDEF MSWINDOWS}
  Windows.PurgeComm(FHandle, PURGE_TXABORT or PURGE_TXCLEAR);
  {$ELSE}
  TCFlush(FHandle, TCOFLUSH);
  {$ENDIF}
end;

procedure TNativeSerialWriteOperation.ExecuteWrite(var AResult: TSerialWriteResult);
var
  Count, Chunk, Error: Integer;
  Started, Due, Elapsed: QWord;
  Payload: AnsiString;
  RTSSet: Boolean;
  {$IFDEF MSWINDOWS}
  PreviousTimeouts, Timeouts: TCommTimeouts;
  HaveTimeouts: Boolean;
  {$ELSE}
  PreviousFlags: Integer;
  {$ENDIF}
begin
  if StopRequested then
  begin
    SetStopped(AResult);
    Exit;
  end;
  if Data = '' then
    Exit;
  Error := CheckSignals;
  if Error <> 0 then
  begin
    SetError(AResult, Error);
    Exit;
  end;
  RTSSet := False;
  {$IFDEF MSWINDOWS}
  HaveTimeouts := ReadTimeouts(PreviousTimeouts);
  if not HaveTimeouts then
  begin
    SetError(AResult, Windows.GetLastError);
    Exit;
  end;
  Timeouts := PreviousTimeouts;
  Timeouts.WriteTotalTimeoutMultiplier := 0;
  Timeouts.WriteTotalTimeoutConstant := RemainingMs;
  if not WriteTimeouts(Timeouts) then
  begin
    SetError(AResult, Windows.GetLastError);
    Exit;
  end;
  {$ELSE}
  PreviousFlags := fpFcntl(FHandle, F_GETFL);
  if (PreviousFlags < 0) or
    (fpFcntl(FHandle, F_SETFL, PreviousFlags or O_NONBLOCK) < 0) then
  begin
    SetError(AResult, fpGetErrno);
    Exit;
  end;
  {$ENDIF}
  try
    if FToggleRTS then
    begin
      if not Drain(AResult) then
        Exit;
      Error := SetRTSValue(True);
      if Error <> 0 then
      begin
        SetError(AResult, Error);
        Exit;
      end;
      RTSSet := True;
    end;
    Payload := Data;
    Started := GetTickCount64;
    while AResult.BytesWritten < Length(Payload) do
    begin
      if StopRequested then
      begin
        SetStopped(AResult);
        Break;
      end;
      if FMaxBandwidth > 0 then
      begin
        Due := (QWord(AResult.BytesWritten) * 1000) div Cardinal(FMaxBandwidth);
        Elapsed := GetTickCount64 - Started;
        if Due > Elapsed then
        begin
          if Due - Elapsed > 10 then
            WaitDelay(10)
          else
            WaitDelay(Due - Elapsed);
          Continue;
        end;
      end;
      Chunk := Length(Payload) - AResult.BytesWritten;
      if Chunk > cSerialChunk then
        Chunk := cSerialChunk;
      if (FMaxBandwidth > 0) and (Chunk > FMaxBandwidth div 100 + 1) then
        Chunk := FMaxBandwidth div 100 + 1;
      Error := WriteChunk(PByte(Pointer(Payload)) + AResult.BytesWritten, Chunk, Count);
      if (Count < 0) or (Count > Chunk) then
      begin
        SetError(AResult, ErrWrongParameter);
        Break;
      end;
      Inc(AResult.BytesWritten, Count);
      if Statistics <> nil then Statistics.AddSent(Count);
      if Error <> 0 then
      begin
        if StopRequested then
          SetStopped(AResult)
        else
          SetError(AResult, Error);
        Break;
      end;
      if Count = 0 then
        WaitDelay(1);
    end;
    if (AResult.Outcome = swoCompleted) and FToggleRTS then
      Drain(AResult);
  finally
    if AResult.Outcome <> swoCompleted then
      PurgeOutput;
    if RTSSet then
    begin
      Error := SetRTSValue(False);
      if (Error <> 0) and (AResult.Outcome = swoCompleted) then
        SetError(AResult, Error);
    end;
    {$IFDEF MSWINDOWS}
    if not WriteTimeouts(PreviousTimeouts) and (AResult.Outcome = swoCompleted) then
      SetError(AResult, Windows.GetLastError);
    {$ELSE}
    if (fpFcntl(FHandle, F_SETFL, PreviousFlags) < 0) and
      (AResult.Outcome = swoCompleted) then
      SetError(AResult, fpGetErrno);
    {$ENDIF}
  end;
end;

end.
