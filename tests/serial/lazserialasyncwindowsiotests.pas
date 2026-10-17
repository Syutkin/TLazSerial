unit LazSerialAsyncWindowsIoTests;

{$mode ObjFPC}{$H+}

interface

{$IFDEF MSWINDOWS}
uses
  Windows, Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSerialCommon,
  LazSerialWrite, LazSerialNativeWrite, LazSynaSer;

type
  TLazSerialAsyncWindowsIoTests = class(TTestCase)
  private
    FCalls: Integer;
    FResult: TSerialWriteResult;
    procedure Completed(const AResult: TSerialWriteResult);
    procedure CheckScenario(AMode: Integer; ACancel, AFailCancel: Boolean);
  published
    procedure ImmediateWriteUsesOwnedBuffer;
    procedure PendingPartialWritesCompleteThePayload;
    procedure TimeoutPreservesPartialCount;
    procedure FailedCancellationKeepsStorageUntilCompletion;
    procedure DelayedCancellationKeepsStorageUntilCompletion;
    procedure StartFailureReturnsNoBytes;
    procedure ZeroProgressReachesTheOverallDeadline;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
type
  TCheckedAsyncWrite = class(TNativeSerialWriteOperation)
  protected
    function StartIO(ABuffer: Pointer; ACount: DWORD; out ATransferred: DWORD;
      var AOverlapped: TOverlapped): Boolean; override;
    function WaitIO(AEvent: THandle; ATimeout: DWORD): DWORD; override;
    function FinishIO(var AOverlapped: TOverlapped; out ATransferred: DWORD;
      AWait: Boolean): Boolean; override;
    function AbortIO: Boolean; override;
    function ReadTimeouts(out ATimeouts: TCommTimeouts): Boolean; override;
    function WriteTimeouts(const ATimeouts: TCommTimeouts): Boolean; override;
  public
    Mode, Offset, Requested, TimeoutUpdates, AbortCount: Integer;
    FailCancel: Boolean;
    Buffer: Pointer;
    OperationEvent: THandle;
    Cancelling, Released, Started: TEvent;
    TimeoutBudget: Cardinal;
    constructor Create(const APort: ISerialWritePort;
      const AOnFinished: TSerialWriteFinished; ATimeoutMs: Cardinal);
    destructor Destroy; override;
  end;

constructor TCheckedAsyncWrite.Create(const APort: ISerialWritePort;
  const AOnFinished: TSerialWriteFinished; ATimeoutMs: Cardinal);
begin
  inherited Create(APort, 'A' + #0 + #255 + 'B', 7, ATimeoutMs, AOnFinished);
  TimeoutBudget := ATimeoutMs;
  Started := TEvent.Create(nil, True, False, '');
  Cancelling := TEvent.Create(nil, True, False, '');
  Released := TEvent.Create(nil, True, False, '');
end;

destructor TCheckedAsyncWrite.Destroy;
begin
  Started.Free;
  Released.Free;
  Cancelling.Free;
  inherited Destroy;
end;

function TCheckedAsyncWrite.StartIO(ABuffer: Pointer; ACount: DWORD;
  out ATransferred: DWORD; var AOverlapped: TOverlapped): Boolean;
var
  Flags: DWORD;
begin
  OperationEvent := AOverlapped.hEvent;
  TAssert.AssertTrue('The operation needs a live event',
    GetHandleInformation(OperationEvent, Flags));
  Buffer := ABuffer;
  Requested := ACount;
  Started.SetEvent;
  TAssert.AssertEquals('Write the retained payload',
    Ord(Data[Offset + 1]), PByte(Buffer)^);
  ATransferred := 0;
  case Mode of
    0:
      begin
        ATransferred := ACount;
        Exit(True);
      end;
    3:
      begin
        ATransferred := High(DWORD);
        Windows.SetLastError(ERROR_ACCESS_DENIED);
        Exit(False);
      end;
    4: Exit(True); // Simulate a driver making no progress.
  end;
  Windows.SetLastError(ERROR_IO_PENDING);
  Result := False;
end;

function TCheckedAsyncWrite.WaitIO(AEvent: THandle; ATimeout: DWORD): DWORD;
begin
  TAssert.AssertTrue(AEvent = OperationEvent);
  if Mode = 1 then
    Result := WAIT_OBJECT_0
  else
    Result := WAIT_TIMEOUT;
end;

function TCheckedAsyncWrite.FinishIO(var AOverlapped: TOverlapped;
  out ATransferred: DWORD; AWait: Boolean): Boolean;
var
  Flags: DWORD;
begin
  if Mode = 2 then
  begin
    TAssert.AssertTrue('Cancellation must drain the operation in the worker', AWait);
    Cancelling.SetEvent;
    Released.WaitFor(INFINITE);
  end;
  TAssert.AssertTrue('Retain the event through delayed or failed cancellation',
    GetHandleInformation(AOverlapped.hEvent, Flags));
  TAssert.AssertEquals('Retain the actual native buffer until completion',
    Ord(Data[Offset + 1]), PByte(Buffer)^);
  ATransferred := 1;
  if Mode = 1 then
  begin
    if Requested > 1 then
      ATransferred := 2;
    Inc(Offset, ATransferred);
    Exit(True);
  end;
  Windows.SetLastError(ERROR_OPERATION_ABORTED);
  Result := False;
end;

function TCheckedAsyncWrite.AbortIO: Boolean;
begin
  Inc(AbortCount);
  Result := not FailCancel;
  if not Result then
    Windows.SetLastError(ERROR_ACCESS_DENIED);
end;

function TCheckedAsyncWrite.ReadTimeouts(out ATimeouts: TCommTimeouts): Boolean;
begin
  FillChar(ATimeouts, SizeOf(ATimeouts), 0);
  ATimeouts.ReadIntervalTimeout := 17;
  ATimeouts.ReadTotalTimeoutConstant := 23;
  ATimeouts.WriteTotalTimeoutMultiplier := 7;
  ATimeouts.WriteTotalTimeoutConstant := 99;
  Result := True;
end;

function TCheckedAsyncWrite.WriteTimeouts(const ATimeouts: TCommTimeouts): Boolean;
begin
  Inc(TimeoutUpdates);
  TAssert.AssertEquals('Do not alter the reader timeout', 17,
    ATimeouts.ReadIntervalTimeout);
  TAssert.AssertEquals(23, ATimeouts.ReadTotalTimeoutConstant);
  if TimeoutUpdates = 1 then
  begin
    TAssert.AssertEquals(0, ATimeouts.WriteTotalTimeoutMultiplier);
    TAssert.AssertTrue('Bound the driver wait by the operation deadline',
      (ATimeouts.WriteTotalTimeoutConstant > 0) and
      (ATimeouts.WriteTotalTimeoutConstant <= TimeoutBudget));
  end
  else
  begin
    TAssert.AssertEquals('Restore the original driver timeouts', 7,
      ATimeouts.WriteTotalTimeoutMultiplier);
    TAssert.AssertEquals(99, ATimeouts.WriteTotalTimeoutConstant);
  end;
  Result := True;
end;

procedure TLazSerialAsyncWindowsIoTests.Completed(const AResult: TSerialWriteResult);
begin
  AssertTrue(GetCurrentThreadID = MainThreadID);
  Inc(FCalls);
  FResult := AResult;
end;

procedure TLazSerialAsyncWindowsIoTests.CheckScenario(AMode: Integer;
  ACancel, AFailCancel: Boolean);
var
  Port: ISerialWritePort;
  Operation: ISerialWriteOperation;
  Checked: TCheckedAsyncWrite;
  StartedAt: QWord;
  Flags: DWORD;
  TimeoutBudget: Cardinal;
begin
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  if ACancel then
    TimeoutBudget := 5000
  else
    TimeoutBudget := 30;
  Checked := TCheckedAsyncWrite.Create(Port, @Completed, TimeoutBudget);
  Operation := Checked;
  Checked.Mode := AMode;
  Checked.FailCancel := AFailCancel;
  try
    Operation.Start;
    AssertEquals(0, FCalls);
    if (AMode = 2) and ACancel then
    begin
      // Let native I/O start so this checks cancellation of a pending transfer.
      AssertEquals(Ord(wrSignaled), Ord(Checked.Started.WaitFor(1000)));
      Operation.Cancel;
    end;
    if AMode = 2 then
    begin
      AssertEquals(Ord(wrSignaled), Ord(Checked.Cancelling.WaitFor(1000)));
      AssertEquals('No result until cancellation actually finishes', 0, FCalls);
      AssertTrue(GetHandleInformation(Checked.OperationEvent, Flags));
      Checked.Released.SetEvent;
    end;
    StartedAt := GetTickCount64;
    while (FCalls = 0) and (GetTickCount64 - StartedAt < 2000) do
    begin
      CheckSynchronize(5);
      Sleep(1);
    end;
    AssertEquals(1, FCalls);
    AssertEquals(7, FResult.OperationId);
    AssertEquals(2, Checked.TimeoutUpdates);
    AssertFalse('Release the event only after completion',
      GetHandleInformation(Checked.OperationEvent, Flags));
    case AMode of
      0, 1:
        begin
          AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
          AssertEquals(4, FResult.BytesWritten);
        end;
      2:
        begin
          AssertEquals(1, Checked.AbortCount);
          AssertEquals(1, FResult.BytesWritten);
          if ACancel then
          begin
            AssertEquals(Ord(swoCancelled), Ord(FResult.Outcome));
            AssertEquals(0, FResult.ErrorCode);
          end
          else
          begin
            AssertEquals(Ord(swoTimedOut), Ord(FResult.Outcome));
            AssertEquals(ErrTimeout, FResult.ErrorCode);
          end;
        end;
      3:
        begin
          AssertEquals(Ord(swoFailed), Ord(FResult.Outcome));
          AssertEquals(0, FResult.BytesWritten);
          AssertEquals(ERROR_ACCESS_DENIED, FResult.ErrorCode);
        end;
      4:
        begin
          AssertEquals(Ord(swoTimedOut), Ord(FResult.Outcome));
          AssertEquals(0, FResult.BytesWritten);
        end;
    end;
  finally
    Checked.Released.SetEvent;
    Operation.Detach;
  end;
end;

procedure TLazSerialAsyncWindowsIoTests.ImmediateWriteUsesOwnedBuffer;
begin CheckScenario(0, False, False); end;
procedure TLazSerialAsyncWindowsIoTests.PendingPartialWritesCompleteThePayload;
begin CheckScenario(1, False, False); end;
procedure TLazSerialAsyncWindowsIoTests.TimeoutPreservesPartialCount;
begin CheckScenario(2, False, False); end;
procedure TLazSerialAsyncWindowsIoTests.FailedCancellationKeepsStorageUntilCompletion;
begin CheckScenario(2, True, True); end;
procedure TLazSerialAsyncWindowsIoTests.DelayedCancellationKeepsStorageUntilCompletion;
begin CheckScenario(2, True, False); end;
procedure TLazSerialAsyncWindowsIoTests.StartFailureReturnsNoBytes;
begin CheckScenario(3, False, False); end;
procedure TLazSerialAsyncWindowsIoTests.ZeroProgressReachesTheOverallDeadline;
begin CheckScenario(4, False, False); end;

initialization
  RegisterTest(TLazSerialAsyncWindowsIoTests);
{$ENDIF}

end.
