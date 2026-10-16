unit LazSerialWindowsIoTests;

{$mode ObjFPC}{$H+}

interface

{$IFDEF MSWINDOWS}
uses
  Windows, FpcUnit, TestRegistry, LazSynaSer;

type
  TIoScenario = (ioImmediate, ioPartial, ioCompletionError, ioTimeout,
    ioWaitFailed, ioIncomplete);

  TLazSerialWindowsIoTests = class(TTestCase)
  private
    procedure CheckIO(const ARead: Boolean; const AScenario: TIoScenario);
  published
    procedure ImmediateReadReturnsActualCount;
    procedure ImmediateWriteReturnsActualCount;
    procedure PendingReadReturnsPartialCount;
    procedure PendingWriteReturnsPartialCount;
    procedure ReadReportsCompletionError;
    procedure WriteReportsCompletionError;
    procedure ReadWaitsForDelayedCancellation;
    procedure WriteWaitsForDelayedCancellation;
    procedure ReadReportsFailedWait;
    procedure WriteReportsFailedWait;
    procedure ReadWaitsForIncompleteResult;
    procedure WriteWaitsForIncompleteResult;
    procedure ReadErrorPreservesPartialLine;
    procedure OperationsKeepDedicatedEventUntilCompletion;
    procedure FailedCancellationStillDrainsOperation;
    procedure ExceptionsPreserveFirstErrorAfterCompletion;
    procedure ImmediateFailureReturnsNoTransferredBytes;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
type
  { Only OS calls are simulated. SendBuffer/RecvBuffer are production code. }
  TScriptedWindowsSerial = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
    function StartOverlappedIO(ARead: Boolean; ABuffer: Pointer;
      ALength: DWord; var ATransferred: DWord;
      AOverlapped: POverlapped): Boolean; override;
    function WaitOverlappedIO(AHandle: THandle; ATimeout: DWord): DWord; override;
    function FinishOverlappedIO(var AOverlapped: TOverlapped;
      var ATransferred: DWord; AWait: Boolean): Boolean; override;
    function AbortOverlappedIO(AFlags: DWord): Boolean; override;
    function ClearOverlappedIOError(var AError: DWord): Boolean; override;
  public
    Scenario: TIoScenario;
    Pending: Boolean;
    Cancelled: Boolean;
    WasRead: Boolean;
    FinishCount: Integer;
  end;

  TReadErrorLineSerial = class(TScriptedWindowsSerial)
  protected
    function StartOverlappedIO(ARead: Boolean; ABuffer: Pointer;
      ALength: DWord; var ATransferred: DWord;
      AOverlapped: POverlapped): Boolean; override;
    function ClearOverlappedIOError(var AError: DWord): Boolean; override;
  public
    Incoming: AnsiString;
    FailRead: Boolean;
    function WaitingData: Integer; override;
    function CanRead(Timeout: Integer): Boolean; override;
  end;

function TReadErrorLineSerial.StartOverlappedIO(ARead: Boolean;
  ABuffer: Pointer; ALength: DWord; var ATransferred: DWord;
  AOverlapped: POverlapped): Boolean;
begin
  ATransferred := Length(Incoming);
  if ATransferred > ALength then
    ATransferred := ALength;
  if ATransferred > 0 then
    Move(Incoming[1], ABuffer^, ATransferred);
  Delete(Incoming, 1, ATransferred);
  Result := True;
end;

function TReadErrorLineSerial.ClearOverlappedIOError(var AError: DWord): Boolean;
begin
  AError := 0;
  if FailRead then
  begin
    AError := CE_FRAME;
    FailRead := False;
  end;
  Result := True;
end;

function TReadErrorLineSerial.WaitingData: Integer;
begin
  Result := Length(Incoming);
end;

function TReadErrorLineSerial.CanRead(Timeout: Integer): Boolean;
begin
  Result := WaitingData > 0;
  SetSynaError(0);
end;

procedure TLazSerialWindowsIoTests.ReadErrorPreservesPartialLine;
var
  Serial: TReadErrorLineSerial;
  RaiseNative, Raised: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Serial := TReadErrorLineSerial.Create;
    try
      Serial.RaiseExcept := RaiseNative;
      Serial.LineBuffer := 'prefix-';
      Serial.Incoming := 'abc' + #13;
      Serial.FailRead := True;
      Raised := False;
      try
        Serial.RecvString(0);
      except
        on E: ESynaSerError do
        begin
          Raised := True;
          AssertEquals(ErrFrame, E.ErrorCode);
        end;
      end;
      AssertEquals(RaiseNative, Raised);
      AssertEquals(ErrFrame, Serial.LastError);
      AssertEquals('Preserve old and newly read bytes before raising',
        'prefix-abc' + #13, Serial.LineBuffer);
      AssertEquals(RaiseNative, Serial.RaiseExcept);
      Serial.Incoming := #10 + 'next' + #13#10;
      AssertEquals('prefix-abc', Serial.RecvString(0));
      AssertEquals('next', Serial.RecvString(0));
      AssertEquals(0, Serial.LastError);
      AssertEquals('', Serial.LineBuffer);
    finally
      Serial.Free;
    end;
  end;
end;

function TScriptedWindowsSerial.PreTestFailing: Boolean;
begin
  Result := False;
end;

function TScriptedWindowsSerial.StartOverlappedIO(ARead: Boolean;
  ABuffer: Pointer; ALength: DWord; var ATransferred: DWord;
  AOverlapped: POverlapped): Boolean;
begin
  WasRead := ARead;
  ATransferred := 0;
  if ARead then
    FillChar(ABuffer^, ALength, Ord('x'));
  Pending := Scenario <> ioImmediate;
  Result := not Pending;
  if Result then
    ATransferred := ALength
  else
    Windows.SetLastError(ERROR_IO_PENDING);
end;

function TScriptedWindowsSerial.WaitOverlappedIO(AHandle: THandle;
  ATimeout: DWord): DWord;
begin
  case Scenario of
    ioTimeout: Result := WAIT_TIMEOUT;
    ioWaitFailed:
      begin
        Windows.SetLastError(ERROR_INVALID_HANDLE);
        Result := WAIT_FAILED;
      end;
  else
    Result := WAIT_OBJECT_0;
  end;
end;

function TScriptedWindowsSerial.FinishOverlappedIO(var AOverlapped: TOverlapped;
  var ATransferred: DWord; AWait: Boolean): Boolean;
begin
  Inc(FinishCount);
  ATransferred := 0;
  if Scenario = ioCompletionError then
  begin
    Pending := False;
    Windows.SetLastError(ERROR_ACCESS_DENIED);
    Exit(False);
  end;
  if Scenario in [ioTimeout, ioWaitFailed] then
  begin
    if AWait then
    begin
      Pending := False;
      Windows.SetLastError(ERROR_OPERATION_ABORTED);
    end
    else
      Windows.SetLastError(ERROR_IO_INCOMPLETE);
    Exit(False);
  end;
  if (Scenario = ioIncomplete) and (FinishCount = 1) and not AWait then
  begin
    Windows.SetLastError(ERROR_IO_INCOMPLETE);
    Exit(False);
  end;
  Pending := False;
  ATransferred := 2;
  Result := True;
end;

function TScriptedWindowsSerial.AbortOverlappedIO(AFlags: DWord): Boolean;
begin
  Cancelled := True;
  // Cancellation is requested, but completion has not arrived yet.
  Result := True;
end;

function TScriptedWindowsSerial.ClearOverlappedIOError(var AError: DWord): Boolean;
begin
  AError := 0;
  Result := True;
end;

procedure TLazSerialWindowsIoTests.CheckIO(const ARead: Boolean;
  const AScenario: TIoScenario);
var
  Serial: TScriptedWindowsSerial;
  Buffer: array[0..3] of Byte;
  Count: Integer;
begin
  Serial := TScriptedWindowsSerial.Create;
  try
    Serial.Scenario := AScenario;
    FillChar(Buffer, SizeOf(Buffer), 0);
    if ARead then
      Count := Serial.RecvBuffer(@Buffer[0], SizeOf(Buffer))
    else
      Count := Serial.SendBuffer(@Buffer[0], SizeOf(Buffer));
    AssertEquals(ARead, Serial.WasRead);
    AssertFalse('Returning must not leave an operation using local OVERLAPPED/buffer',
      Serial.Pending);
    case AScenario of
      ioImmediate: AssertEquals(4, Count);
      ioPartial, ioIncomplete:
        begin
          AssertEquals(2, Count);
          AssertEquals(0, Serial.LastError);
        end;
      ioCompletionError: AssertEquals(ERROR_ACCESS_DENIED, Serial.LastError);
      ioTimeout:
        begin
          AssertTrue('Timeout must request cancellation', Serial.Cancelled);
          AssertEquals(ErrTimeout, Serial.LastError);
        end;
      ioWaitFailed: AssertEquals(ERROR_INVALID_HANDLE, Serial.LastError);
    end;
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialWindowsIoTests.ImmediateReadReturnsActualCount;
begin CheckIO(True, ioImmediate); end;
procedure TLazSerialWindowsIoTests.ImmediateWriteReturnsActualCount;
begin CheckIO(False, ioImmediate); end;
procedure TLazSerialWindowsIoTests.PendingReadReturnsPartialCount;
begin CheckIO(True, ioPartial); end;
procedure TLazSerialWindowsIoTests.PendingWriteReturnsPartialCount;
begin CheckIO(False, ioPartial); end;
procedure TLazSerialWindowsIoTests.ReadReportsCompletionError;
begin CheckIO(True, ioCompletionError); end;
procedure TLazSerialWindowsIoTests.WriteReportsCompletionError;
begin CheckIO(False, ioCompletionError); end;
procedure TLazSerialWindowsIoTests.ReadWaitsForDelayedCancellation;
begin CheckIO(True, ioTimeout); end;
procedure TLazSerialWindowsIoTests.WriteWaitsForDelayedCancellation;
begin CheckIO(False, ioTimeout); end;
procedure TLazSerialWindowsIoTests.ReadReportsFailedWait;
begin CheckIO(True, ioWaitFailed); end;
procedure TLazSerialWindowsIoTests.WriteReportsFailedWait;
begin CheckIO(False, ioWaitFailed); end;
procedure TLazSerialWindowsIoTests.ReadWaitsForIncompleteResult;
begin CheckIO(True, ioIncomplete); end;
procedure TLazSerialWindowsIoTests.WriteWaitsForIncompleteResult;
begin CheckIO(False, ioIncomplete); end;

type
  TCheckedWindowsSerial = class(TScriptedWindowsSerial)
  protected
    function StartOverlappedIO(ARead: Boolean; ABuffer: Pointer;
      ALength: DWord; var ATransferred: DWord;
      AOverlapped: POverlapped): Boolean; override;
    function WaitOverlappedIO(AHandle: THandle; ATimeout: DWord): DWord; override;
    function FinishOverlappedIO(var AOverlapped: TOverlapped;
      var ATransferred: DWord; AWait: Boolean): Boolean; override;
    function AbortOverlappedIO(AFlags: DWord): Boolean; override;
    function ClearOverlappedIOError(var AError: DWord): Boolean; override;
  public
    OperationEvent: THandle;
    FailCancel, FailStart, ReportFrameError: Boolean;
  end;

function TCheckedWindowsSerial.StartOverlappedIO(ARead: Boolean;
  ABuffer: Pointer; ALength: DWord; var ATransferred: DWord;
  AOverlapped: POverlapped): Boolean;
var
  Flags: DWord;
begin
  OperationEvent := AOverlapped^.hEvent;
  TAssert.AssertTrue('Every transfer needs its own valid event',
    (OperationEvent <> 0) and GetHandleInformation(OperationEvent, Flags));
  TAssert.AssertTrue('The operation event must differ from the port handle',
    OperationEvent <> Handle);
  if FailStart then
  begin
    // A failed ReadFile/WriteFile need not initialize the byte count.
    ATransferred := High(DWord);
    Windows.SetLastError(ERROR_ACCESS_DENIED);
    Exit(False);
  end;
  Result := inherited StartOverlappedIO(ARead, ABuffer, ALength,
    ATransferred, AOverlapped);
end;

function TCheckedWindowsSerial.WaitOverlappedIO(AHandle: THandle;
  ATimeout: DWord): DWord;
begin
  TAssert.AssertTrue('Wait for this operation, not unrelated port readiness',
    AHandle = OperationEvent);
  Result := inherited WaitOverlappedIO(AHandle, ATimeout);
end;

function TCheckedWindowsSerial.FinishOverlappedIO(var AOverlapped: TOverlapped;
  var ATransferred: DWord; AWait: Boolean): Boolean;
var
  Flags: DWord;
begin
  TAssert.AssertTrue('Keep the event alive while completion/cancellation is pending',
    GetHandleInformation(AOverlapped.hEvent, Flags));
  Result := inherited FinishOverlappedIO(AOverlapped, ATransferred, AWait);
end;

function TCheckedWindowsSerial.AbortOverlappedIO(AFlags: DWord): Boolean;
begin
  Result := inherited AbortOverlappedIO(AFlags);
  if FailCancel then
  begin
    Windows.SetLastError(ERROR_ACCESS_DENIED);
    Result := False;
  end;
end;

function TCheckedWindowsSerial.ClearOverlappedIOError(var AError: DWord): Boolean;
begin
  Result := inherited ClearOverlappedIOError(AError);
  if ReportFrameError then
    AError := CE_FRAME;
end;

procedure TLazSerialWindowsIoTests.OperationsKeepDedicatedEventUntilCompletion;
var
  Serial: TCheckedWindowsSerial;
  Scenario: TIoScenario;
  ReadOperation: Boolean;
  Buffer: array[0..3] of Byte;
  Flags: DWord;
begin
  for ReadOperation := False to True do
    for Scenario := Low(TIoScenario) to High(TIoScenario) do
    begin
      Serial := TCheckedWindowsSerial.Create;
      try
        Serial.Scenario := Scenario;
        if ReadOperation then
          Serial.RecvBuffer(@Buffer[0], SizeOf(Buffer))
        else
          Serial.SendBuffer(@Buffer[0], SizeOf(Buffer));
        AssertFalse('The transfer must reach a terminal state', Serial.Pending);
        AssertFalse('Release the event after the transfer has finished',
          GetHandleInformation(Serial.OperationEvent, Flags));
        AssertEquals(ERROR_INVALID_HANDLE, Windows.GetLastError);
      finally
        Serial.Free;
      end;
    end;
end;

procedure TLazSerialWindowsIoTests.FailedCancellationStillDrainsOperation;
var
  Serial: TCheckedWindowsSerial;
  ReadOperation: Boolean;
  Buffer: array[0..3] of Byte;
begin
  for ReadOperation := False to True do
  begin
    Serial := TCheckedWindowsSerial.Create;
    try
      Serial.Scenario := ioTimeout;
      Serial.FailCancel := True;
      if ReadOperation then
        Serial.RecvBuffer(@Buffer[0], SizeOf(Buffer))
      else
        Serial.SendBuffer(@Buffer[0], SizeOf(Buffer));
      AssertTrue(Serial.Cancelled);
      AssertFalse('Even failed cancellation must not abandon live buffers',
        Serial.Pending);
      AssertEquals('Preserve the timeout rather than the cancellation error',
        ErrTimeout, Serial.LastError);
    finally
      Serial.Free;
    end;
  end;
end;

procedure TLazSerialWindowsIoTests.ExceptionsPreserveFirstErrorAfterCompletion;
var
  Serial: TCheckedWindowsSerial;
  Scenario: TIoScenario;
  ReadOperation, Raised: Boolean;
  Buffer: array[0..3] of Byte;
  ExpectedError: Integer;
  Flags: DWord;
begin
  for ReadOperation := False to True do
    for Scenario := ioCompletionError to ioWaitFailed do
    begin
      Serial := TCheckedWindowsSerial.Create;
      try
        Serial.Scenario := Scenario;
        Serial.RaiseExcept := True;
        Serial.ReportFrameError := True;
        case Scenario of
          ioCompletionError: ExpectedError := ERROR_ACCESS_DENIED;
          ioTimeout: ExpectedError := ErrTimeout;
          ioWaitFailed: ExpectedError := ERROR_INVALID_HANDLE;
        else
          Fail('Unexpected test scenario');
        end;
        Raised := False;
        try
          if ReadOperation then
            Serial.RecvBuffer(@Buffer[0], SizeOf(Buffer))
          else
            Serial.SendBuffer(@Buffer[0], SizeOf(Buffer));
        except
          on E: ESynaSerError do
          begin
            Raised := True;
            AssertEquals(ExpectedError, E.ErrorCode);
          end;
        end;
        AssertTrue('RaiseExcept must report the first transfer error', Raised);
        AssertFalse('Complete cancellation before raising', Serial.Pending);
        AssertEquals(ExpectedError, Serial.LastError);
        AssertFalse('Release the event before raising',
          GetHandleInformation(Serial.OperationEvent, Flags));
      finally
        Serial.Free;
      end;
    end;
end;

procedure TLazSerialWindowsIoTests.ImmediateFailureReturnsNoTransferredBytes;
var
  Serial: TCheckedWindowsSerial;
  ReadOperation: Boolean;
  Buffer: array[0..3] of Byte;
  Count: Integer;
begin
  for ReadOperation := False to True do
  begin
    Serial := TCheckedWindowsSerial.Create;
    try
      Serial.FailStart := True;
      if ReadOperation then
        Count := Serial.RecvBuffer(@Buffer[0], SizeOf(Buffer))
      else
        Count := Serial.SendBuffer(@Buffer[0], SizeOf(Buffer));
      AssertEquals(0, Count);
      AssertEquals(ERROR_ACCESS_DENIED, Serial.LastError);
      AssertEquals(0, Serial.FinishCount);
      AssertFalse(Serial.Cancelled);
    finally
      Serial.Free;
    end;
  end;
end;

initialization
  RegisterTest(TLazSerialWindowsIoTests);
{$ENDIF}

end.
