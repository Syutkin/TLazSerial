unit LazSerialWriteQueueCoreTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, FpcUnit, TestRegistry, LazSerialCommon, LazSerialWriteQueue;

type
  TLazSerialWriteQueueCoreTests = class(TTestCase)
  private
    FQueue: TSerialWriteQueue;
    function ResultFor(AId: QWord; ACount: Integer;
      AOutcome: TSerialWriteOutcome = swoCompleted): TSerialWriteResult;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DefaultsPreserveLegacyMode;
    procedure FifoOwnsBytesAndKeepsOnlyOneActiveRequest;
    procedure ByteLimitIncludesActiveAndUndeliveredResults;
    procedure ItemLimitIncludesEmptyWritesAndCancelledResults;
    procedure CancelPreservesActiveAndPreviouslyCompletedResults;
    procedure FailureCancelsWaitingInFifoOrder;
    procedure ClearReleasesAllReservations;
    procedure SettingsRequireIdleAndPositiveLimits;
    procedure InvalidRequestsDoNotMutateQueue;
    procedure WrongCompletionDoesNotReplaceActiveRequest;
    procedure AdmissionRollbackPreservesEarlierRequests;
  end;

implementation

procedure TLazSerialWriteQueueCoreTests.SetUp;
begin inherited SetUp; FQueue := TSerialWriteQueue.Create; end;
procedure TLazSerialWriteQueueCoreTests.TearDown;
begin FQueue.Free; inherited TearDown; end;
function TLazSerialWriteQueueCoreTests.ResultFor(AId: QWord; ACount: Integer;
  AOutcome: TSerialWriteOutcome): TSerialWriteResult;
begin
  Result := Default(TSerialWriteResult);
  Result.OperationId := AId;
  Result.BytesRequested := ACount;
  Result.BytesWritten := ACount;
  Result.Outcome := AOutcome;
end;
procedure TLazSerialWriteQueueCoreTests.DefaultsPreserveLegacyMode;
begin
  AssertFalse(FQueue.Enabled);
  AssertEquals(65536, FQueue.ByteLimit);
  AssertEquals(64, FQueue.ItemLimit);
  AssertEquals(0, FQueue.Count);
  AssertEquals(0, FQueue.Bytes);
end;
procedure TLazSerialWriteQueueCoreTests.FifoOwnsBytesAndKeepsOnlyOneActiveRequest;
var Request: TSerialQueuedWrite; Value: TSerialWriteResult; Data: AnsiString;
begin
  FQueue.Enabled := True;
  Data := 'a' + #0#255;
  FQueue.Push(1, Data, 101);
  Data[1] := 'z';
  FQueue.Push(2, 'two', 202);
  AssertEquals(2, FQueue.Count);
  AssertEquals(6, FQueue.Bytes);
  AssertTrue(FQueue.BeginNext(Request));
  AssertEquals(QWord(1), Request.OperationId);
  AssertEquals('a' + #0#255, Request.Data);
  AssertEquals(101, Request.TimeoutMs);
  AssertEquals(QWord(1), FQueue.ActiveId);
  AssertFalse(FQueue.BeginNext(Request));
  AssertFalse(FQueue.PopResult(Value));
  FQueue.Complete(ResultFor(1, 3));
  AssertTrue(FQueue.PopResult(Value));
  AssertEquals(QWord(1), Value.OperationId);
  AssertTrue(FQueue.BeginNext(Request));
  AssertEquals(QWord(2), Request.OperationId);
  AssertEquals('two', Request.Data);
  AssertEquals(202, Request.TimeoutMs);
end;
procedure TLazSerialWriteQueueCoreTests.ByteLimitIncludesActiveAndUndeliveredResults;
var Request: TSerialQueuedWrite; Value: TSerialWriteResult; Raised: Boolean;
begin
  FQueue.Enabled := True;
  FQueue.ByteLimit := 4;
  FQueue.Push(1, '1234', 100);
  AssertTrue(FQueue.BeginNext(Request));
  FQueue.Complete(ResultFor(1, 4));
  Raised := False;
  try FQueue.Push(2, 'x', 100);
  except on E: EInvalidOperation do begin Raised := True; AssertTrue(Pos('byte limit', E.Message) > 0); end; end;
  AssertTrue(Raised);
  AssertEquals(4, FQueue.Bytes);
  AssertTrue(FQueue.PopResult(Value));
  FQueue.Push(2, 'x', 100);
  AssertEquals(1, FQueue.Bytes);
end;
procedure TLazSerialWriteQueueCoreTests.ItemLimitIncludesEmptyWritesAndCancelledResults;
var Raised: Boolean; Value: TSerialWriteResult;
begin
  FQueue.Enabled := True;
  FQueue.ItemLimit := 2;
  FQueue.Push(1, '', 100);
  FQueue.Push(2, '', 100);
  FQueue.CancelWaiting;
  Raised := False;
  try FQueue.Push(3, '', 100);
  except on E: EInvalidOperation do begin Raised := True; AssertTrue(Pos('item limit', E.Message) > 0); end; end;
  AssertTrue(Raised);
  AssertEquals(2, FQueue.Count);
  AssertTrue(FQueue.PopResult(Value));
  AssertEquals(Ord(swoCancelled), Ord(Value.Outcome));
  AssertEquals(0, Value.BytesWritten);
  FQueue.Push(3, '', 100);
  AssertEquals(2, FQueue.Count);
end;
procedure TLazSerialWriteQueueCoreTests.CancelPreservesActiveAndPreviouslyCompletedResults;
var Request: TSerialQueuedWrite; Value: TSerialWriteResult;
begin
  FQueue.Enabled := True;
  FQueue.Push(1, 'active', 100);
  FQueue.Push(2, 'waiting', 100);
  AssertTrue(FQueue.BeginNext(Request));
  FQueue.CancelWaiting;
  AssertEquals(QWord(1), FQueue.ActiveId);
  AssertFalse(FQueue.PopResult(Value));
  FQueue.Complete(ResultFor(1, 6));
  FQueue.CancelWaiting;
  AssertTrue(FQueue.PopResult(Value));
  AssertEquals(Ord(swoCompleted), Ord(Value.Outcome));
  AssertTrue(FQueue.PopResult(Value));
  AssertEquals(QWord(2), Value.OperationId);
  AssertEquals(7, Value.BytesRequested);
  AssertEquals(Ord(swoCancelled), Ord(Value.Outcome));
  AssertEquals(0, FQueue.Count);
end;
procedure TLazSerialWriteQueueCoreTests.FailureCancelsWaitingInFifoOrder;
var Request: TSerialQueuedWrite; Value: TSerialWriteResult; I: Integer;
begin
  FQueue.Enabled := True;
  for I := 1 to 3 do FQueue.Push(I, 'data', 100);
  AssertTrue(FQueue.BeginNext(Request));
  Value := ResultFor(1, 4, swoTimedOut);
  Value.BytesWritten := 2;
  Value.ErrorCode := 9997;
  FQueue.Complete(Value);
  for I := 1 to 3 do
  begin
    AssertTrue(FQueue.PopResult(Value));
    AssertEquals(QWord(I), Value.OperationId);
    if I = 1 then
    begin AssertEquals(2, Value.BytesWritten); AssertEquals(9997, Value.ErrorCode); end
    else
    begin
      AssertEquals(Ord(swoCancelled), Ord(Value.Outcome));
      AssertEquals(0, Value.BytesWritten);
    end;
  end;
  AssertEquals(0, FQueue.Bytes);
end;
procedure TLazSerialWriteQueueCoreTests.ClearReleasesAllReservations;
var Request: TSerialQueuedWrite; Value: TSerialWriteResult;
begin
  FQueue.Enabled := True;
  FQueue.Push(1, 'data', 100);
  AssertTrue(FQueue.BeginNext(Request));
  FQueue.Push(2, 'more', 100);
  FQueue.Clear;
  AssertEquals(0, FQueue.Count);
  AssertEquals(0, FQueue.Bytes);
  AssertEquals(QWord(0), FQueue.ActiveId);
  AssertFalse(FQueue.PopResult(Value));
  FQueue.Push(3, '', 100);
  AssertTrue(FQueue.BeginNext(Request));
end;
procedure TLazSerialWriteQueueCoreTests.SettingsRequireIdleAndPositiveLimits;
var I: Integer; Raised: Boolean;
begin
  FQueue.Enabled := True;
  for I := 0 to 3 do
  begin
    Raised := False;
    try
      case I of
        0: FQueue.ByteLimit := 0;
        1: FQueue.ItemLimit := 0;
        2: FQueue.ByteLimit := -1;
        3: FQueue.ItemLimit := -1;
      end;
    except on E: EArgumentException do Raised := True; end;
    AssertTrue(Raised);
  end;
  FQueue.Push(1, '', 100);
  for I := 0 to 2 do
  begin
    Raised := False;
    try
      case I of
        0: FQueue.Enabled := False;
        1: FQueue.ByteLimit := 1;
        2: FQueue.ItemLimit := 1;
      end;
    except on E: EInvalidOperation do Raised := True; end;
    AssertTrue(Raised);
  end;
  AssertTrue(FQueue.Enabled);
end;
procedure TLazSerialWriteQueueCoreTests.InvalidRequestsDoNotMutateQueue;
var I: Integer; Raised: Boolean;
begin
  FQueue.Enabled := True;
  for I := 0 to 1 do
  begin
    Raised := False;
    try
      if I = 0 then FQueue.Push(0, 'x', 100)
      else FQueue.Push(1, 'x', 0);
    except on E: EArgumentException do Raised := True; end;
    AssertTrue(Raised);
    AssertEquals(0, FQueue.Count);
  end;
end;
procedure TLazSerialWriteQueueCoreTests.WrongCompletionDoesNotReplaceActiveRequest;
var Request: TSerialQueuedWrite; Raised: Boolean;
begin
  FQueue.Enabled := True;
  FQueue.Push(1, 'one', 100);
  AssertTrue(FQueue.BeginNext(Request));
  Raised := False;
  try FQueue.Complete(ResultFor(2, 3));
  except on E: EInvalidOperation do Raised := True; end;
  AssertTrue(Raised);
  AssertEquals(QWord(1), FQueue.ActiveId);
end;

procedure TLazSerialWriteQueueCoreTests.AdmissionRollbackPreservesEarlierRequests;
var Request: TSerialQueuedWrite;
begin
  FQueue.Enabled := True;
  FQueue.Push(1, 'one', 100);
  FQueue.Push(2, 'rejected', 200);
  FQueue.RollbackPush(2);
  AssertEquals(1, FQueue.Count);
  AssertEquals(3, FQueue.Bytes);
  AssertTrue(FQueue.BeginNext(Request));
  AssertEquals(QWord(1), Request.OperationId);
  AssertEquals('one', Request.Data);
end;

initialization
  RegisterTest(TLazSerialWriteQueueCoreTests);
end.
