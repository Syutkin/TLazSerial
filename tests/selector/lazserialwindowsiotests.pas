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

initialization
  RegisterTest(TLazSerialWindowsIoTests);
{$ENDIF}

end.
