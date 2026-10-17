unit LazSerialAsyncWriteTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerialCommon, LazSerialWrite;

type
  TLazSerialWriteOperationTests = class(TTestCase)
  private
    FCalls: Integer;
    FResult: TSerialWriteResult;
    procedure Completed(const AResult: TSerialWriteResult);
    procedure AwaitCompletion;
  published
    procedure ResultOwnsTheOriginalPayload;
    procedure CompletionIsQueuedToMainThread;
    procedure CancellationReturnsAResult;
    procedure TimeoutReturnsAResult;
    procedure DetachCancelsQueuedDelivery;
  end;

implementation

type
  TScriptedWriteOperation = class(TSerialWriteOperation)
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); override;
  public
    WaitForStop: Boolean;
  end;

procedure TScriptedWriteOperation.ExecuteWrite(var AResult: TSerialWriteResult);
begin
  if WaitForStop then
  begin
    while not StopRequested do
      WaitDelay(5);
    SetStopped(AResult);
  end
  else
  begin
    if Data <> 'A' + #0 + 'B' then
      raise Exception.Create('The accepted buffer changed');
    AResult.BytesWritten := Length(Data);
  end;
end;

procedure TLazSerialWriteOperationTests.Completed(const AResult: TSerialWriteResult);
begin
  AssertTrue('Delivery must run on the main thread',
    GetCurrentThreadID = MainThreadID);
  Inc(FCalls);
  FResult := AResult;
end;

procedure TLazSerialWriteOperationTests.AwaitCompletion;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (FCalls = 0) and (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  AssertEquals('Exactly one write result must be delivered', 1, FCalls);
end;

procedure TLazSerialWriteOperationTests.ResultOwnsTheOriginalPayload;
var
  Operation: ISerialWriteOperation;
  Payload: AnsiString;
begin
  Payload := 'A' + #0 + 'B';
  Operation := TScriptedWriteOperation.Create(nil, Payload, 42, 1000, @Completed);
  Payload[1] := 'X';
  Operation.Start;
  AwaitCompletion;
  AssertEquals(42, FResult.OperationId);
  AssertEquals(3, FResult.BytesRequested);
  AssertEquals(3, FResult.BytesWritten);
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
end;

procedure TLazSerialWriteOperationTests.CompletionIsQueuedToMainThread;
var
  Operation: ISerialWriteOperation;
begin
  Operation := TScriptedWriteOperation.Create(nil, 'A' + #0 + 'B', 1, 1000,
    @Completed);
  Operation.Start;
  AssertEquals('Start must not invoke a callback inline', 0, FCalls);
  AwaitCompletion;
end;

procedure TLazSerialWriteOperationTests.CancellationReturnsAResult;
var
  Operation: ISerialWriteOperation;
  Script: TScriptedWriteOperation;
begin
  Script := TScriptedWriteOperation.Create(nil, 'pending', 1, 1000, @Completed);
  Operation := Script;
  Script.WaitForStop := True;
  Operation.Start;
  Operation.Cancel;
  AwaitCompletion;
  AssertEquals(Ord(swoCancelled), Ord(FResult.Outcome));
  AssertEquals(0, FResult.ErrorCode);
end;

procedure TLazSerialWriteOperationTests.TimeoutReturnsAResult;
var
  Operation: ISerialWriteOperation;
  Script: TScriptedWriteOperation;
begin
  Script := TScriptedWriteOperation.Create(nil, 'pending', 1, 10, @Completed);
  Operation := Script;
  Script.WaitForStop := True;
  Operation.Start;
  AwaitCompletion;
  AssertEquals(Ord(swoTimedOut), Ord(FResult.Outcome));
  AssertTrue(FResult.ErrorCode <> 0);
end;

procedure TLazSerialWriteOperationTests.DetachCancelsQueuedDelivery;
var
  Operation: ISerialWriteOperation;
begin
  Operation := TScriptedWriteOperation.Create(nil, 'A' + #0 + 'B', 1, 1000,
    @Completed);
  Operation.Start;
  Operation.Detach;
  Operation.ClosePort;
  // Let the detached worker finish without delivering to this test instance.
  Sleep(20);
  CheckSynchronize;
  AssertEquals(0, FCalls);
end;

initialization
  RegisterTest(TLazSerialWriteOperationTests);

end.
