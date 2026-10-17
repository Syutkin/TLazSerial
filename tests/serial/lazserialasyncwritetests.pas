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

  {$IFDEF UNIX}
  TLazSerialNativeWriteTests = class(TTestCase)
  private
    FSerial: TObject;
    FMaster, FNativeHandle: Integer;
    FCalls: Integer;
    FResult: TSerialWriteResult;
    procedure Completed(Sender: TObject; const AResult: TSerialWriteResult);
    procedure AwaitCompletion;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure EmptyWriteQueuesCompletion;
    procedure BinaryWriteUsesNativePort;
    procedure BackpressureReturnsPartialTimeout;
    procedure BackpressureCanBeCancelled;
    procedure RestoresDescriptorFlags;
  end;
  {$ENDIF}

implementation

{$IFDEF UNIX}
uses
  BaseUnix, ctypes, LazSerial;

function OpenWritePty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl;
  external 'util' name 'openpty';
{$ENDIF}

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

{$IFDEF UNIX}
procedure TLazSerialNativeWriteTests.SetUp;
var
  Slave: cint;
  Name: array[0..255] of Char;
  Serial: TLazSerial;
begin
  inherited SetUp;
  FMaster := -1;
  AssertEquals(0, OpenWritePty(@FMaster, @Slave, @Name[0], nil, nil));
  try
    Serial := TLazSerial.Create(nil);
    FSerial := Serial;
    Serial.Device := StrPas(Name);
    Serial.Open;
    FNativeHandle := Serial.SynSer.Handle;
    Serial.OnWriteCompleted := @Completed;
    fpFcntl(FMaster, F_SETFL, fpFcntl(FMaster, F_GETFL) or O_NONBLOCK);
  finally
    fpClose(Slave);
  end;
end;

procedure TLazSerialNativeWriteTests.TearDown;
var
  Started: QWord;
begin
  FreeAndNil(FSerial);
  Started := GetTickCount64;
  while (fpFcntl(FNativeHandle, F_GETFD) >= 0) and
    (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  CheckSynchronize;
  if FMaster >= 0 then
    fpClose(FMaster);
  inherited TearDown;
end;

procedure TLazSerialNativeWriteTests.Completed(Sender: TObject;
  const AResult: TSerialWriteResult);
begin
  AssertTrue(GetCurrentThreadID = MainThreadID);
  AssertFalse('Clear pending before calling user code', TLazSerial(Sender).WritePending);
  Inc(FCalls);
  FResult := AResult;
end;

procedure TLazSerialNativeWriteTests.AwaitCompletion;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (FCalls = 0) and (GetTickCount64 - Started < 2000) do
  begin
    CheckSynchronize(5);
    Sleep(1);
  end;
  AssertEquals(1, FCalls);
end;

procedure TLazSerialNativeWriteTests.EmptyWriteQueuesCompletion;
var
  Id: QWord;
begin
  Id := TLazSerial(FSerial).WriteDataAsync('', 1000);
  AssertTrue(TLazSerial(FSerial).WritePending);
  AssertEquals(0, FCalls);
  AwaitCompletion;
  AssertEquals(Id, FResult.OperationId);
  AssertEquals(0, FResult.BytesWritten);
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
end;

procedure TLazSerialNativeWriteTests.BinaryWriteUsesNativePort;
const
  Payload = 'A' + #0 + #255 + 'B';
var
  Buffer: array[0..3] of Byte;
begin
  TLazSerial(FSerial).WriteDataAsync(Payload, 1000);
  AwaitCompletion;
  AssertEquals(4, FResult.BytesWritten);
  AssertEquals(Ord(swoCompleted), Ord(FResult.Outcome));
  AssertEquals(4, fpRead(FMaster, Buffer[0], SizeOf(Buffer)));
  AssertEquals(Ord('A'), Buffer[0]);
  AssertEquals(0, Buffer[1]);
  AssertEquals(255, Buffer[2]);
  AssertEquals(Ord('B'), Buffer[3]);
end;

procedure TLazSerialNativeWriteTests.BackpressureReturnsPartialTimeout;
begin
  TLazSerial(FSerial).WriteDataAsync(StringOfChar('X', 2 * 1024 * 1024), 20);
  AwaitCompletion;
  AssertEquals(Ord(swoTimedOut), Ord(FResult.Outcome));
  AssertTrue('Preserve the count accepted before backpressure', FResult.BytesWritten > 0);
  AssertTrue(FResult.BytesWritten < FResult.BytesRequested);
  AssertTrue(FResult.ErrorCode <> 0);
end;

procedure TLazSerialNativeWriteTests.BackpressureCanBeCancelled;
begin
  TLazSerial(FSerial).WriteDataAsync(StringOfChar('X', 2 * 1024 * 1024), 1000);
  TLazSerial(FSerial).CancelWrite;
  AssertTrue(TLazSerial(FSerial).WritePending);
  AwaitCompletion;
  AssertEquals(Ord(swoCancelled), Ord(FResult.Outcome));
  AssertEquals(0, FResult.ErrorCode);
end;

procedure TLazSerialNativeWriteTests.RestoresDescriptorFlags;
var
  Flags: Integer;
begin
  Flags := fpFcntl(FNativeHandle, F_GETFL);
  TLazSerial(FSerial).WriteDataAsync(StringOfChar('X', 2 * 1024 * 1024), 20);
  AwaitCompletion;
  AssertEquals(Flags, fpFcntl(FNativeHandle, F_GETFL));
end;
{$ENDIF}

initialization
  RegisterTest(TLazSerialWriteOperationTests);
  {$IFDEF UNIX}
  RegisterTest(TLazSerialNativeWriteTests);
  {$ENDIF}

end.
