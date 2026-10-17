unit LazSerialNativeRead;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, LazSerialRead, LazSerialWrite, LazSynaSer
  {$IFDEF MSWINDOWS}, Windows{$ELSE}, BaseUnix{$ENDIF};

type
  TNativeSerialReadOperation = class(TSerialReadOperation)
  private
    FHandle: THandle;
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; override;
    {$IFDEF MSWINDOWS}
    function StartIO(ABuffer: Pointer; ACount: DWORD; out AReceived: DWORD;
      var AOverlapped: TOverlapped): Boolean; virtual;
    function WaitIO(AEvent: THandle; ATimeout: DWORD): DWORD; virtual;
    function FinishIO(var AOverlapped: TOverlapped; out AReceived: DWORD;
      AWait: Boolean): Boolean; virtual;
    function AbortIO: Boolean; virtual;
    {$ENDIF}
  public
    constructor Create(const APort: ISerialWritePort; ALimit: Integer;
      AOnChanged: TSerialReadChanged);
  end;

implementation

constructor TNativeSerialReadOperation.Create(const APort: ISerialWritePort;
  ALimit: Integer; AOnChanged: TSerialReadChanged);
begin
  inherited Create(APort, ALimit, AOnChanged);
  FHandle := APort.GetSerial.Handle;
end;

{$IFDEF MSWINDOWS}
function TNativeSerialReadOperation.StartIO(ABuffer: Pointer; ACount: DWORD;
  out AReceived: DWORD; var AOverlapped: TOverlapped): Boolean;
begin
  Result := Windows.ReadFile(FHandle, ABuffer^, ACount, AReceived, @AOverlapped);
end;

function TNativeSerialReadOperation.WaitIO(AEvent: THandle; ATimeout: DWORD): DWORD;
begin
  Result := Windows.WaitForSingleObject(AEvent, ATimeout);
end;

function TNativeSerialReadOperation.FinishIO(var AOverlapped: TOverlapped;
  out AReceived: DWORD; AWait: Boolean): Boolean;
begin
  Result := Windows.GetOverlappedResult(FHandle, AOverlapped, AReceived, AWait);
end;

function TNativeSerialReadOperation.AbortIO: Boolean;
begin
  Result := Windows.PurgeComm(FHandle, PURGE_RXABORT);
end;

function TNativeSerialReadOperation.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
var
  Overlapped: TOverlapped;
  Count, CompletionError, WaitResult: DWORD;
  WaitCompletion: Boolean;
begin
  Result := 0;
  AReceived := 0;
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  Overlapped.hEvent := Windows.CreateEvent(nil, True, False, nil);
  if Overlapped.hEvent = 0 then Exit(Windows.GetLastError);
  try
    Count := 0;
    if StartIO(ABuffer, ACount, Count, Overlapped) then
    begin
      AReceived := Count;
      Exit;
    end;
    Result := Windows.GetLastError;
    if Result <> ERROR_IO_PENDING then Exit;
    Result := 0;
    WaitCompletion := False;
    repeat
      WaitResult := WaitIO(Overlapped.hEvent, 0);
      if WaitResult = WAIT_OBJECT_0 then Break;
      if WaitResult <> WAIT_TIMEOUT then
      begin
        if WaitResult = WAIT_FAILED then Result := Windows.GetLastError
        else Result := ERROR_GEN_FAILURE;
        WaitCompletion := True;
        Break;
      end;
      if StopRequested then
      begin
        WaitCompletion := True;
        Break;
      end;
      WaitDelay(10);
    until False;
    if WaitCompletion then AbortIO;
    // Even unsuccessful cancellation must reach a terminal result before
    // releasing the event, OVERLAPPED or caller's temporary buffer.
    repeat
      Count := 0;
      if FinishIO(Overlapped, Count, WaitCompletion) then Break;
      CompletionError := Windows.GetLastError;
      if CompletionError <> ERROR_IO_INCOMPLETE then
      begin
        if Result = 0 then Result := CompletionError;
        Break;
      end;
      WaitCompletion := True;
    until False;
    AReceived := Count;
  finally Windows.CloseHandle(Overlapped.hEvent); end;
end;
{$ELSE}
function TNativeSerialReadOperation.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
var Descriptor: TPollFD; Ready: Integer;
begin
  Result := 0;
  AReceived := 0;
  FillChar(Descriptor, SizeOf(Descriptor), 0);
  Descriptor.fd := FHandle;
  Descriptor.events := POLLIN;
  repeat
    if StopRequested then Exit;
    Ready := fpPoll(@Descriptor, 1, 10);
    if Ready < 0 then
    begin
      Result := fpGetErrno;
      if Result = ESysEINTR then Continue;
      Exit;
    end;
    if Ready = 0 then Exit;
    // Drain readable bytes even if hangup was reported in the same poll.
    if (Descriptor.revents and POLLIN) = 0 then
      if (Descriptor.revents and (POLLERR or POLLHUP or POLLNVAL)) <> 0 then
        Exit(ErrNoDeviceAnswer);
    AReceived := fpRead(FHandle, ABuffer^, ACount);
    if AReceived > 0 then Exit;
    if AReceived = 0 then Exit(ErrNoDeviceAnswer);
    Result := fpGetErrno;
    AReceived := 0;
    if Result = ESysEINTR then Continue;
    if Result = ESysEAGAIN then Result := 0;
    Exit;
  until False;
end;
{$ENDIF}
end.
