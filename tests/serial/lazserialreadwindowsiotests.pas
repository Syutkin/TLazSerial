unit LazSerialReadWindowsIoTests;
{$mode ObjFPC}{$H+}
interface
{$IFDEF MSWINDOWS}
uses Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, Windows,
  LazSerialRead, LazSerialWrite, LazSerialNativeRead, LazSynaSer;
type
  TLazSerialReadWindowsIoTests = class(TTestCase)
  private
    procedure CheckDelayedCancel(AAbortFails, AIncomplete: Boolean);
  published
    procedure ImmediatePartialReadPreservesBytes;
    procedure NativeFailurePreservesErrorCode;
    procedure DelayedCancellationRetainsBufferAndOverlapped;
    procedure FailedCancellationRetainsBufferAndOverlapped;
    procedure IncompleteCompletionWaitsForTerminalResult;
    procedure FailedWaitPreservesOriginalError;
  end;
{$ENDIF}
implementation
{$IFDEF MSWINDOWS}
type
  TWindowsReadState = class(TInterfacedObject)
  public
    Entered, Cancelling, Released: SyncObjs.TEvent;
    Mode, AbortCalls, FinishCalls: Integer;
    BufferAlive, EventAlive: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;
  TWindowsRead = class(TNativeSerialReadOperation)
  private
    FState: TWindowsReadState;
    FReference: IInterface;
    FBuffer: PByte;
    FCalls: Integer;
  protected
    function StartIO(ABuffer: Pointer; ACount: DWORD; out AReceived: DWORD;
      var AOverlapped: TOverlapped): Boolean; override;
    function WaitIO(AEvent: THandle; ATimeout: DWORD): DWORD; override;
    function FinishIO(var AOverlapped: TOverlapped; out AReceived: DWORD;
      AWait: Boolean): Boolean; override;
    function AbortIO: Boolean; override;
  public
    constructor Create(const APort: ISerialWritePort; AState: TWindowsReadState);
  end;
constructor TWindowsReadState.Create;
begin
  inherited Create;
  Entered := SyncObjs.TEvent.Create(nil, True, False, '');
  Cancelling := SyncObjs.TEvent.Create(nil, True, False, '');
  Released := SyncObjs.TEvent.Create(nil, True, False, '');
end;
destructor TWindowsReadState.Destroy;
begin Entered.Free; Cancelling.Free; Released.Free; inherited Destroy; end;
constructor TWindowsRead.Create(const APort: ISerialWritePort; AState: TWindowsReadState);
begin inherited Create(APort, 32, nil); FState := AState; FReference := AState; end;
function TWindowsRead.StartIO(ABuffer: Pointer; ACount: DWORD;
  out AReceived: DWORD; var AOverlapped: TOverlapped): Boolean;
begin
  Inc(FCalls); AReceived := 0; FBuffer := ABuffer;
  if (FState.Mode = 1) then
  begin Windows.SetLastError(ERROR_GEN_FAILURE); Exit(False); end;
  if (FState.Mode = 0) and (FCalls = 1) then
  begin
    FBuffer[0] := Ord('a'); FBuffer[1] := Ord('b');
    AReceived := 2; Exit(True);
  end;
  FState.Entered.SetEvent;
  Windows.SetLastError(ERROR_IO_PENDING);
  Result := False;
end;
function TWindowsRead.WaitIO(AEvent: THandle; ATimeout: DWORD): DWORD;
begin
  if FState.Mode = 5 then
  begin Windows.SetLastError(ERROR_INVALID_HANDLE); Exit(WAIT_FAILED); end;
  if (FState.Mode = 4) and (FState.FinishCalls = 0) then Exit(WAIT_OBJECT_0);
  Result := WAIT_TIMEOUT;
end;
function TWindowsRead.AbortIO: Boolean;
begin
  Inc(FState.AbortCalls);
  FState.Cancelling.SetEvent;
  Result := FState.Mode <> 3;
  if not Result then Windows.SetLastError(ERROR_ACCESS_DENIED);
end;
function TWindowsRead.FinishIO(var AOverlapped: TOverlapped;
  out AReceived: DWORD; AWait: Boolean): Boolean;
begin
  Inc(FState.FinishCalls); AReceived := 0;
  if (FState.Mode = 4) and (FState.FinishCalls = 1) then
  begin Windows.SetLastError(ERROR_IO_INCOMPLETE); Exit(False); end;
  FState.Cancelling.SetEvent;
  if AWait then FState.Released.WaitFor(5000);
  FState.EventAlive := Windows.WaitForSingleObject(AOverlapped.hEvent, 0) <> WAIT_FAILED;
  // Simulate a driver still accessing storage after cancellation was requested.
  FBuffer[0] := Ord('z');
  FState.BufferAlive := FBuffer[0] = Ord('z');
  Windows.SetLastError(ERROR_OPERATION_ABORTED);
  Result := False;
end;
procedure AwaitReadClosed(const Operation: ISerialReadOperation);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while Operation.GetClosePending and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  TAssert.AssertFalse(Operation.GetClosePending);
  CheckSynchronize(1);
end;
procedure TLazSerialReadWindowsIoTests.CheckDelayedCancel(AAbortFails, AIncomplete: Boolean);
var State: TWindowsReadState; Reference: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation;
begin
  State := TWindowsReadState.Create; Reference := State;
  State.Mode := 2;
  if AAbortFails then State.Mode := 3;
  if AIncomplete then State.Mode := 4;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TWindowsRead.Create(Port, State);
  try
    Operation.Start;
    AssertEquals(Ord(wrSignaled), Ord(State.Entered.WaitFor(2000)));
    if not AIncomplete then Operation.ClosePort;
    AssertEquals(Ord(wrSignaled), Ord(State.Cancelling.WaitFor(2000)));
    Operation.ClosePort;
    AssertTrue('Cleanup waits outside the caller for driver completion', Operation.GetClosePending);
    State.Released.SetEvent;
    AwaitReadClosed(Operation);
    AssertTrue(State.BufferAlive); AssertTrue(State.EventAlive);
    if not AIncomplete then AssertEquals(1, State.AbortCalls)
    else AssertTrue(State.FinishCalls >= 2);
  finally
    State.Released.SetEvent; Operation.ClosePort;
    AwaitReadClosed(Operation); Operation.Detach;
    Operation := nil; Port := nil; Reference := nil;
  end;
end;
procedure TLazSerialReadWindowsIoTests.DelayedCancellationRetainsBufferAndOverlapped;
begin CheckDelayedCancel(False, False); end;
procedure TLazSerialReadWindowsIoTests.FailedCancellationRetainsBufferAndOverlapped;
begin CheckDelayedCancel(True, False); end;
procedure TLazSerialReadWindowsIoTests.IncompleteCompletionWaitsForTerminalResult;
begin CheckDelayedCancel(False, True); end;
procedure TLazSerialReadWindowsIoTests.ImmediatePartialReadPreservesBytes;
var State: TWindowsReadState; Reference: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation; Data: AnsiString; Deadline: QWord;
begin
  State := TWindowsReadState.Create; Reference := State;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TWindowsRead.Create(Port, State);
  try
    Operation.Start;
    Deadline := GetTickCount64 + 2000;
    while not Operation.DataAvailable(False) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertTrue(Operation.TryReadData(False, Data));
    AssertEquals('ab', Data);
  finally
    State.Released.SetEvent; Operation.ClosePort;
    AwaitReadClosed(Operation); Operation.Detach;
    Operation := nil; Port := nil; Reference := nil;
  end;
end;
procedure TLazSerialReadWindowsIoTests.NativeFailurePreservesErrorCode;
var State: TWindowsReadState; Reference: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation; Code: Integer; Message: string; Deadline: QWord;
begin
  State := TWindowsReadState.Create; Reference := State; State.Mode := 1;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TWindowsRead.Create(Port, State);
  try
    Operation.Start;
    Deadline := GetTickCount64 + 2000;
    while not Operation.GetFailure(Code, Message) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertTrue(Operation.GetFailure(Code, Message));
    AssertEquals(ERROR_GEN_FAILURE, Code);
  finally
    State.Released.SetEvent; Operation.ClosePort;
    AwaitReadClosed(Operation); Operation.Detach;
    Operation := nil; Port := nil; Reference := nil;
  end;
end;
procedure TLazSerialReadWindowsIoTests.FailedWaitPreservesOriginalError;
var State: TWindowsReadState; Reference: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation; Code: Integer; Message: string; Deadline: QWord;
begin
  State := TWindowsReadState.Create; Reference := State; State.Mode := 5;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TWindowsRead.Create(Port, State);
  try
    Operation.Start;
    AssertEquals(Ord(wrSignaled), Ord(State.Cancelling.WaitFor(2000)));
    State.Released.SetEvent;
    Deadline := GetTickCount64 + 2000;
    while not Operation.GetFailure(Code, Message) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertTrue(Operation.GetFailure(Code, Message));
    AssertEquals(ERROR_INVALID_HANDLE, Code);
    AssertTrue(State.BufferAlive); AssertTrue(State.EventAlive);
  finally
    State.Released.SetEvent; Operation.ClosePort;
    AwaitReadClosed(Operation); Operation.Detach;
    Operation := nil; Port := nil; Reference := nil;
  end;
end;
initialization RegisterTest(TLazSerialReadWindowsIoTests);
{$ENDIF}
end.
