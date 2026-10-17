unit LazSerialWriteQueueTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, TypInfo, FpcUnit, TestRegistry, LazSerial,
  LazSerialCommon, LazSerialTransport, LazSerialTransportTests, LazSerialWrite,
  LazSerialStatistics, SerialWatcher, SerialWatcherSupport,
  SerialWatcherComponentTests, LazSynaSer, LazSerialDevices, LazSerialReconnect;

type
  TLazSerialWriteQueueTests = class(TTestCase)
  private
    FSerial: TTestableLazSerial;
    FOwner: TComponent;
    FTransport: TFakeSerialTransport;
    FResults: array of TSerialWriteResult;
    FCounts: array of Integer;
    FAction: string;
    FAddedId: QWord;
    procedure Completed(Sender: TObject; const AResult: TSerialWriteResult);
    procedure Status(Sender: TObject; Reason: THookSerialReason; const Value: string);
    procedure Pump;
    procedure StartFirst;
    procedure CompleteCurrent(AOutcome: TSerialWriteOutcome = swoCompleted;
      AWritten: Integer = -1);
    procedure ThreeWrites;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DefaultsAndLegacyOverlapAreUnchanged;
    procedure QueueAcceptsIdsBeforeStartingAndSendsInOrder;
    procedure CallbackAppendCannotOvertakeExistingEntries;
    procedure ByteLimitRejectsWithoutConsumingId;
    procedure EmptyWritesAreBoundedByItemLimit;
    procedure TimeoutStartsWhenEntryIsLaunched;
    procedure FailureAndTimeoutCancelTheRemainingEntries;
    procedure CancelBeforeDispatchStartsNoNativeWrite;
    procedure CancelActivePreservesItsActualResult;
    procedure CancellationFromCompletionStopsRemainingWrites;
    procedure CloseFromCompletionDropsRemainingWrites;
    procedure CloseSuppressesDelayedResultsAndReopenStartsEmpty;
    procedure CompletionCanDestroyComponent;
    procedure CompletionCanDestroyOwner;
    procedure HandlerExceptionDoesNotStallQueue;
    procedure NestedSynchronizationCannotLaunchInsideHandler;
    procedure SettingsAndSyncWritesRejectQueuedWork;
    procedure QueueCanBeDisabledWhenIdleAndIdsStayUnique;
    procedure CreationAndStartupErrorsHaveResultsForAcceptedIds;
    procedure StatusCanDestroyOwnerDuringQueuedStartup;
    procedure StatusExceptionDoesNotBecomeWriteFailure;
    procedure ReadContinuesAndStatisticsCountOnlyNativeProgress;
    procedure ReopeningInHandlerDoesNotReplayOldEntries;
    procedure QueueApiRejectsWorkerThread;
    procedure ActiveCancellationReportsProgressAndCancelsTheTail;
    procedure AutoReconnectStartsWithAnEmptyQueue;
    {$IFDEF UNIX}
    procedure NativePtySendsQueuedBinaryAndEmptyWrites;
    {$ENDIF}
  end;

implementation

{$IFDEF UNIX}
uses BaseUnix, ctypes;
function OpenQueuePty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl; external 'util' name 'openpty';
{$ENDIF}

type
  TQueueTransport = class;
  TQueueOperation = class(TInterfacedObject, ISerialWriteOperation)
  public
    Owner: TQueueTransport;
    Payload: AnsiString;
    Id: QWord;
    Timeout: Cardinal;
    Handler: TSerialWriteFinished;
    Statistics: ISerialStatisticsState;
    Done, Cancelled: Boolean;
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    procedure DeferDelivery;
    procedure Finish(AOutcome: TSerialWriteOutcome; AWritten: Integer);
  end;
  TQueueTransport = class(TFakeSerialTransport)
  public
    Current: TQueueOperation;
    CurrentReference: ISerialWriteOperation;
    Starts: TStringList;
    Timeouts: array of Cardinal;
    CreateCount, FailCreateAt, FailStartAt: Integer;
    EmitStatus: Boolean;
    StatusHandler: THookSerialStatus;
    constructor Create;
    destructor Destroy; override;
    procedure SetStatusHandler(const AHandler: THookSerialStatus); override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeoutMs: Cardinal; const AOnFinished: TSerialWriteFinished): ISerialWriteOperation; override;
  end;
  TQueueWatcher = class(TSerialWatcher)
  public
    procedure Isolate;
    procedure Stop;
    procedure Publish(const ADevices: TSerialDeviceInfoArray);
  end;
  TQueueReconnectAccess = class(TSerialReconnect);
  TQueueApiThread = class(TThread)
  public
    Serial: TLazSerial;
    Rejected: Integer;
    procedure Execute; override;
  end;

procedure RaiseQueueStartupError;
var Error: ESynaSerError;
begin
  Error := ESynaSerError.Create('Scripted queued startup failure');
  Error.ErrorCode := ErrAlreadyInUse;
  Error.ErrorMessage := Error.Message;
  raise Error;
end;
procedure TQueueOperation.Start;
begin
  Owner.Starts.Add(Payload);
  SetLength(Owner.Timeouts, Owner.Starts.Count);
  Owner.Timeouts[Owner.Starts.Count - 1] := Timeout;
  if Owner.FailStartAt = Owner.Starts.Count then RaiseQueueStartupError;
  if Owner.EmitStatus and Assigned(Owner.StatusHandler) then
    Owner.StatusHandler(Owner, HR_WriteCount, '0');
end;
procedure TQueueOperation.Cancel;
begin Cancelled := True; end;
procedure TQueueOperation.ClosePort;
begin Cancelled := True; Owner.OpenValue := False; end;
procedure TQueueOperation.Detach;
begin Handler := nil; end;
procedure TQueueOperation.DeferDelivery;
begin end;
procedure TQueueOperation.Finish(AOutcome: TSerialWriteOutcome; AWritten: Integer);
var Result: TSerialWriteResult; Callback: TSerialWriteFinished;
begin
  if Done then Exit;
  Done := True;
  Result := Default(TSerialWriteResult);
  Result.OperationId := Id;
  Result.BytesRequested := Length(Payload);
  Result.Outcome := AOutcome;
  if AWritten < 0 then AWritten := Length(Payload);
  Result.BytesWritten := AWritten;
  if AOutcome = swoTimedOut then Result.ErrorCode := ErrTimeout
  else if AOutcome = swoFailed then Result.ErrorCode := ErrNotRead;
  if Statistics <> nil then
  begin
    Statistics.AddSent(AWritten);
    if AOutcome in [swoFailed, swoTimedOut] then
      Statistics.RecordError(Result.ErrorCode, 'Scripted native write error');
  end;
  Callback := Handler;
  if Assigned(Callback) then Callback(Result);
end;
constructor TQueueTransport.Create;
begin inherited Create; Starts := TStringList.Create; end;
destructor TQueueTransport.Destroy;
begin Starts.Free; inherited Destroy; end;
procedure TQueueTransport.SetStatusHandler(const AHandler: THookSerialStatus);
begin inherited SetStatusHandler(AHandler); StatusHandler := AHandler; end;
function TQueueTransport.CreateWriteOperation(const AData: AnsiString; const AId: QWord;
  const ATimeoutMs: Cardinal; const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
begin
  Inc(CreateCount);
  if CreateCount = FailCreateAt then RaiseQueueStartupError;
  Current := TQueueOperation.Create;
  Current.Owner := Self;
  Current.Payload := Copy(AData, 1, Length(AData));
  Current.Id := AId;
  Current.Timeout := ATimeoutMs;
  Current.Handler := AOnFinished;
  Current.Statistics := FStatisticsState;
  CurrentReference := Current;
  Result := CurrentReference;
end;
procedure TQueueWatcher.Isolate;
begin
  SetInfrastructure(TSerialManualChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;
procedure TQueueWatcher.Stop;
begin StopWatching; end;
procedure TQueueWatcher.Publish(const ADevices: TSerialDeviceInfoArray);
begin ApplyDevices(ADevices); end;
procedure TQueueApiThread.Execute;
var I, Number: Integer; Flag: Boolean; Bytes: SizeInt;
begin
  for I := 0 to 7 do
    try
      case I of
        0: Flag := Serial.WriteQueueEnabled;
        1: Serial.WriteQueueEnabled := True;
        2: Number := Serial.WriteQueueByteLimit;
        3: Serial.WriteQueueByteLimit := 10;
        4: Number := Serial.WriteQueueItemLimit;
        5: Serial.WriteQueueItemLimit := 2;
        6: Number := Serial.PendingWriteCount;
        7: Bytes := Serial.PendingWriteBytes;
      end;
    except on E: ELazSerialThreadError do Inc(Rejected); end;
end;

procedure TLazSerialWriteQueueTests.SetUp;
var I: Integer;
begin
  inherited SetUp;
  FOwner := TComponent.Create(nil);
  FSerial := TTestableLazSerial.Create(FOwner);
  FTransport := TQueueTransport.Create;
  FSerial.InstallTransport(FTransport);
  FSerial.OnWriteCompleted := @Completed;
  FResults := nil; FCounts := nil; FAction := ''; FAddedId := 0;
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialWatcher then
      TQueueWatcher(FSerial.Components[I]).Isolate;
  FSerial.Open;
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialWatcher then
      TQueueWatcher(FSerial.Components[I]).Stop;
end;
procedure TLazSerialWriteQueueTests.TearDown;
var Deadline: QWord;
begin
  if FSerial <> nil then
  begin
    FSerial.OnWriteCompleted := nil;
    FSerial.OnStatus := nil;
    if (FTransport <> nil) and (TQueueTransport(FTransport).Current <> nil) then
      TQueueTransport(FTransport).Current.Finish(swoCancelled, 0);
    FSerial.Close;
    Deadline := GetTickCount64 + 2000;
    while (FSerial.WritePending or FSerial.ClosePending) and
      (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertFalse(FSerial.WritePending);
  end;
  FreeAndNil(FOwner);
  FSerial := nil;
  CheckSynchronize(1);
  inherited TearDown;
end;
procedure TLazSerialWriteQueueTests.Completed(Sender: TObject; const AResult: TSerialWriteResult);
var Action: string;
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  SetLength(FResults, Length(FResults) + 1);
  FResults[High(FResults)] := AResult;
  SetLength(FCounts, Length(FResults));
  FCounts[High(FCounts)] := FSerial.PendingWriteCount;
  Action := FAction;
  FAction := '';
  if Action = 'append' then FAddedId := FSerial.WriteDataAsync('added', 123)
  else if Action = 'cancel' then FSerial.CancelWrite
  else if Action = 'close' then FSerial.Close
  else if Action = 'destroy' then FreeAndNil(FSerial)
  else if Action = 'owner' then begin FSerial := nil; FreeAndNil(FOwner); end
  else if Action = 'raise' then raise EInvalidOperation.Create('completion handler')
  else if Action = 'nested' then
  begin
    FAddedId := FSerial.WriteDataAsync('added', 123);
    CheckSynchronize(1);
    AssertEquals('No startup inside the completion handler', 1, TQueueTransport(FTransport).Starts.Count);
  end
  else if Action = 'reopen' then
  begin
    FSerial.Close;
    FSerial.Open;
    FAddedId := FSerial.WriteDataAsync('new session', 1000);
  end;
end;
procedure TLazSerialWriteQueueTests.Status(Sender: TObject; Reason: THookSerialReason;
  const Value: string);
begin
  if FAction = 'owner' then begin FSerial := nil; FreeAndNil(FOwner); end
  else if FAction = 'raise' then
  begin FAction := ''; raise EInvalidOperation.Create('status handler'); end;
end;
procedure TLazSerialWriteQueueTests.Pump;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 20;
  repeat CheckSynchronize(1); until GetTickCount64 >= Deadline;
end;
procedure TLazSerialWriteQueueTests.StartFirst;
begin Pump; AssertEquals(1, TQueueTransport(FTransport).Starts.Count); end;
procedure TLazSerialWriteQueueTests.CompleteCurrent(AOutcome: TSerialWriteOutcome; AWritten: Integer);
begin TQueueTransport(FTransport).Current.Finish(AOutcome, AWritten); Pump; end;
procedure TLazSerialWriteQueueTests.ThreeWrites;
begin
  FSerial.WriteQueueEnabled := True;
  AssertEquals(QWord(1), FSerial.WriteDataAsync('one', 1000));
  AssertEquals(QWord(2), FSerial.WriteDataAsync('two', 1000));
  AssertEquals(QWord(3), FSerial.WriteDataAsync('three', 1000));
end;
procedure TLazSerialWriteQueueTests.DefaultsAndLegacyOverlapAreUnchanged;
var Raised: Boolean; Prop: PPropInfo;
begin
  AssertFalse(FSerial.WriteQueueEnabled);
  AssertEquals(65536, FSerial.WriteQueueByteLimit);
  AssertEquals(64, FSerial.WriteQueueItemLimit);
  Prop := GetPropInfo(FSerial, 'WriteQueueByteLimit'); AssertNotNull(Prop);
  AssertEquals(65536, Prop^.Default);
  Prop := GetPropInfo(FSerial, 'WriteQueueItemLimit'); AssertNotNull(Prop);
  AssertEquals(64, Prop^.Default);
  FSerial.WriteDataAsync('legacy', 1000);
  Raised := False;
  try FSerial.WriteDataAsync('overlap', 1000);
  except on E: EInvalidOperation do Raised := True; end;
  AssertTrue(Raised);
  AssertEquals(1, FSerial.PendingWriteCount);
  AssertEquals(6, FSerial.PendingWriteBytes);
end;
procedure TLazSerialWriteQueueTests.QueueAcceptsIdsBeforeStartingAndSendsInOrder;
var Data: string;
begin
  FSerial.WriteQueueEnabled := True;
  Data := 'a' + #0#255;
  AssertEquals(QWord(1), FSerial.WriteDataAsync(Data, 1000));
  Data[1] := 'z';
  FSerial.WriteDataAsync('two', 2000);
  AssertEquals(0, TQueueTransport(FTransport).Starts.Count);
  AssertTrue(FSerial.WritePending);
  AssertEquals(2, FSerial.PendingWriteCount);
  AssertEquals(6, FSerial.PendingWriteBytes);
  StartFirst;
  AssertEquals('a' + #0#255, TQueueTransport(FTransport).Starts[0]);
  CompleteCurrent;
  AssertEquals(1, Length(FResults));
  AssertEquals(1, FCounts[0]);
  AssertTrue(FSerial.WritePending);
  AssertEquals('two', TQueueTransport(FTransport).Starts[1]);
  CompleteCurrent;
  AssertEquals(QWord(2), FResults[1].OperationId);
  AssertFalse(FSerial.WritePending);
  AssertEquals(0, FSerial.PendingWriteCount);
end;
procedure TLazSerialWriteQueueTests.CallbackAppendCannotOvertakeExistingEntries;
begin
  ThreeWrites; StartFirst; FAction := 'append'; CompleteCurrent;
  AssertEquals(QWord(4), FAddedId);
  CompleteCurrent; CompleteCurrent; CompleteCurrent;
  AssertEquals('one,two,three,added', TQueueTransport(FTransport).Starts.CommaText);
  AssertEquals(4, Length(FResults));
end;
procedure TLazSerialWriteQueueTests.ByteLimitRejectsWithoutConsumingId;
var Raised: Boolean;
begin
  FSerial.WriteQueueEnabled := True;
  FSerial.WriteQueueByteLimit := 4;
  AssertEquals(QWord(1), FSerial.WriteDataAsync('1234', 1000));
  Raised := False;
  try FSerial.WriteDataAsync('x', 1000);
  except on E: EInvalidOperation do begin Raised := True; AssertTrue(Pos('byte limit', E.Message) > 0); end; end;
  AssertTrue(Raised);
  AssertEquals(4, FSerial.PendingWriteBytes);
  StartFirst; CompleteCurrent;
  AssertEquals(QWord(2), FSerial.WriteDataAsync('x', 1000));
end;
procedure TLazSerialWriteQueueTests.EmptyWritesAreBoundedByItemLimit;
var Raised: Boolean;
begin
  FSerial.WriteQueueEnabled := True;
  FSerial.WriteQueueItemLimit := 2;
  FSerial.WriteDataAsync('', 1000); FSerial.WriteDataAsync('', 1000);
  Raised := False;
  try FSerial.WriteDataAsync('', 1000);
  except on E: EInvalidOperation do begin Raised := True; AssertTrue(Pos('item limit', E.Message) > 0); end; end;
  AssertTrue(Raised);
  FSerial.CancelWrite;
  AssertEquals(2, FSerial.PendingWriteCount);
  Pump;
  AssertEquals(0, TQueueTransport(FTransport).Starts.Count);
  AssertEquals(2, Length(FResults));
end;
procedure TLazSerialWriteQueueTests.TimeoutStartsWhenEntryIsLaunched;
begin
  FSerial.WriteQueueEnabled := True;
  FSerial.WriteDataAsync('held', 1000);
  FSerial.WriteDataAsync('next', 1);
  StartFirst; Pump;
  AssertEquals(1, TQueueTransport(FTransport).CreateCount);
  CompleteCurrent;
  AssertEquals(2, TQueueTransport(FTransport).CreateCount);
  AssertEquals(1, TQueueTransport(FTransport).Timeouts[1]);
  CompleteCurrent;
  AssertEquals(Ord(swoCompleted), Ord(FResults[1].Outcome));
end;
procedure TLazSerialWriteQueueTests.FailureAndTimeoutCancelTheRemainingEntries;
begin
  ThreeWrites; StartFirst; CompleteCurrent(swoTimedOut, 1);
  AssertEquals(3, Length(FResults));
  AssertEquals(Ord(swoTimedOut), Ord(FResults[0].Outcome));
  AssertEquals(1, FResults[0].BytesWritten);
  AssertEquals(ErrTimeout, FResults[0].ErrorCode);
  AssertEquals(Ord(swoCancelled), Ord(FResults[1].Outcome));
  AssertEquals(0, FResults[2].BytesWritten);
  AssertEquals(1, TQueueTransport(FTransport).Starts.Count);
  AssertFalse(FSerial.WritePending);
end;
procedure TLazSerialWriteQueueTests.CancelBeforeDispatchStartsNoNativeWrite;
begin
  ThreeWrites; FSerial.CancelWrite; Pump;
  AssertEquals(0, TQueueTransport(FTransport).CreateCount);
  AssertEquals(3, Length(FResults));
  AssertEquals(Ord(swoCancelled), Ord(FResults[0].Outcome));
  AssertFalse(FSerial.WritePending);
end;
procedure TLazSerialWriteQueueTests.CancelActivePreservesItsActualResult;
begin
  ThreeWrites; StartFirst; FSerial.CancelWrite;
  AssertTrue(TQueueTransport(FTransport).Current.Cancelled);
  AssertEquals(0, Length(FResults));
  AssertTrue(FSerial.WritePending);
  CompleteCurrent;
  AssertEquals(Ord(swoCompleted), Ord(FResults[0].Outcome));
  AssertEquals(Ord(swoCancelled), Ord(FResults[1].Outcome));
  AssertEquals(1, TQueueTransport(FTransport).Starts.Count);
end;
procedure TLazSerialWriteQueueTests.CancellationFromCompletionStopsRemainingWrites;
begin
  ThreeWrites; StartFirst; FAction := 'cancel'; CompleteCurrent;
  AssertEquals(3, Length(FResults));
  AssertEquals(1, TQueueTransport(FTransport).Starts.Count);
end;
procedure TLazSerialWriteQueueTests.CloseFromCompletionDropsRemainingWrites;
begin
  ThreeWrites; StartFirst; FAction := 'close'; CompleteCurrent;
  AssertEquals(1, Length(FResults));
  AssertFalse(FSerial.Active);
  AssertFalse(FSerial.WritePending);
  AssertEquals(1, TQueueTransport(FTransport).Starts.Count);
end;
procedure TLazSerialWriteQueueTests.CloseSuppressesDelayedResultsAndReopenStartsEmpty;
begin
  ThreeWrites; StartFirst; FSerial.Close;
  AssertTrue(FSerial.WritePending);
  CompleteCurrent(swoCancelled, 1);
  AssertEquals(0, Length(FResults));
  AssertFalse(FSerial.WritePending);
  FSerial.Open; FSerial.WriteDataAsync('new', 1000); Pump;
  AssertEquals(2, TQueueTransport(FTransport).Starts.Count);
  AssertEquals('new', TQueueTransport(FTransport).Starts[1]);
end;
procedure TLazSerialWriteQueueTests.CompletionCanDestroyComponent;
begin
  ThreeWrites; StartFirst; FAction := 'destroy'; CompleteCurrent;
  AssertNull(FSerial); AssertEquals(1, Length(FResults));
end;
procedure TLazSerialWriteQueueTests.CompletionCanDestroyOwner;
begin
  ThreeWrites; StartFirst; FAction := 'owner'; CompleteCurrent;
  AssertNull(FSerial); AssertNull(FOwner); AssertEquals(1, Length(FResults));
end;
procedure TLazSerialWriteQueueTests.HandlerExceptionDoesNotStallQueue;
var Raised: Boolean;
begin
  ThreeWrites; StartFirst; FAction := 'raise'; Raised := False;
  try CompleteCurrent;
  except on E: EInvalidOperation do begin Raised := True; AssertEquals('completion handler', E.Message); end; end;
  AssertTrue(Raised);
  Pump;
  AssertEquals(2, TQueueTransport(FTransport).Starts.Count);
  CompleteCurrent; CompleteCurrent;
  AssertEquals(3, Length(FResults));
end;
procedure TLazSerialWriteQueueTests.NestedSynchronizationCannotLaunchInsideHandler;
begin
  ThreeWrites; StartFirst; FAction := 'nested'; CompleteCurrent;
  AssertEquals('two', TQueueTransport(FTransport).Starts[1]);
  AssertEquals(QWord(4), FAddedId);
end;
procedure TLazSerialWriteQueueTests.SettingsAndSyncWritesRejectQueuedWork;
var I: Integer; Raised: Boolean; Value: Byte;
begin
  ThreeWrites; Value := 0;
  for I := 0 to 6 do
  begin
    Raised := False;
    try
      case I of
        0: FSerial.WriteData('sync');
        1: FSerial.WriteBuffer(Value, 1);
        2: FSerial.WriteQueueEnabled := False;
        3: FSerial.WriteQueueByteLimit := 10;
        4: FSerial.WriteQueueItemLimit := 10;
        5: FSerial.Device := 'another';
        6: FSerial.SynSer.SetSynaError(0);
      end;
    except on E: EInvalidOperation do Raised := True; end;
    AssertTrue(IntToStr(I), Raised);
  end;
end;
procedure TLazSerialWriteQueueTests.QueueCanBeDisabledWhenIdleAndIdsStayUnique;
begin
  FSerial.WriteQueueEnabled := True;
  FSerial.WriteDataAsync('one', 1000); StartFirst; CompleteCurrent;
  FSerial.WriteQueueEnabled := False;
  AssertEquals(QWord(2), FSerial.WriteDataAsync('legacy', 1000));
  CompleteCurrent;
  FSerial.WriteQueueEnabled := True;
  AssertEquals(QWord(3), FSerial.WriteDataAsync('queued', 1000));
end;
procedure TLazSerialWriteQueueTests.CreationAndStartupErrorsHaveResultsForAcceptedIds;
begin
  TQueueTransport(FTransport).FailCreateAt := 1;
  ThreeWrites; Pump;
  AssertEquals(3, Length(FResults));
  AssertEquals(Ord(swoFailed), Ord(FResults[0].Outcome));
  AssertEquals(ErrAlreadyInUse, FResults[0].ErrorCode);
  AssertEquals(QWord(1), FResults[0].OperationId);
  AssertEquals(Ord(swoCancelled), Ord(FResults[1].Outcome));
  AssertEquals(QWord(1), FSerial.Statistics.ErrorCount);
  TQueueTransport(FTransport).FailCreateAt := 0;
  TQueueTransport(FTransport).FailStartAt := 1;
  AssertEquals(QWord(4), FSerial.WriteDataAsync('start fail', 1000));
  Pump;
  AssertEquals(4, Length(FResults));
  AssertEquals(Ord(swoFailed), Ord(FResults[3].Outcome));
end;
procedure TLazSerialWriteQueueTests.StatusCanDestroyOwnerDuringQueuedStartup;
begin
  TQueueTransport(FTransport).EmitStatus := True;
  ThreeWrites; FSerial.OnStatus := @Status; FAction := 'owner'; Pump;
  AssertNull(FSerial); AssertEquals(0, Length(FResults));
end;
procedure TLazSerialWriteQueueTests.StatusExceptionDoesNotBecomeWriteFailure;
var Raised: Boolean;
begin
  TQueueTransport(FTransport).EmitStatus := True;
  ThreeWrites; FSerial.OnStatus := @Status; FAction := 'raise'; Raised := False;
  try Pump;
  except on E: EInvalidOperation do begin Raised := True; AssertEquals('status handler', E.Message); end; end;
  AssertTrue(Raised);
  AssertEquals(0, Length(FResults));
  AssertEquals(3, FSerial.PendingWriteCount);
  AssertTrue(FSerial.WritePending);
  CompleteCurrent;
  AssertEquals(Ord(swoCompleted), Ord(FResults[0].Outcome));
end;
procedure TLazSerialWriteQueueTests.ReadContinuesAndStatisticsCountOnlyNativeProgress;
begin
  ThreeWrites; StartFirst;
  AssertEquals('', FSerial.ReadData);
  AssertEquals(QWord(0), FSerial.Statistics.BytesSent);
  CompleteCurrent(swoFailed, 1);
  AssertEquals(QWord(1), FSerial.Statistics.BytesSent);
  AssertEquals(3, Length(FResults));
end;
procedure TLazSerialWriteQueueTests.ReopeningInHandlerDoesNotReplayOldEntries;
begin
  ThreeWrites; StartFirst; FAction := 'reopen'; CompleteCurrent;
  AssertTrue(FSerial.Active);
  AssertEquals(2, TQueueTransport(FTransport).Starts.Count);
  AssertEquals('new session', TQueueTransport(FTransport).Starts[1]);
  AssertEquals(QWord(4), FAddedId);
  CompleteCurrent;
  AssertEquals(2, Length(FResults));
  AssertEquals(FAddedId, FResults[1].OperationId);
end;
procedure TLazSerialWriteQueueTests.QueueApiRejectsWorkerThread;
var Worker: TQueueApiThread;
begin
  Worker := TQueueApiThread.Create(True);
  try Worker.Serial := FSerial; Worker.Start; Worker.WaitFor; AssertEquals(8, Worker.Rejected);
  finally Worker.Free; end;
end;
procedure TLazSerialWriteQueueTests.ActiveCancellationReportsProgressAndCancelsTheTail;
begin
  ThreeWrites; StartFirst; FSerial.CancelWrite;
  CompleteCurrent(swoCancelled, 1);
  AssertEquals(3, Length(FResults));
  AssertEquals(Ord(swoCancelled), Ord(FResults[0].Outcome));
  AssertEquals(1, FResults[0].BytesWritten);
  AssertEquals(0, FResults[1].BytesWritten);
  AssertEquals(QWord(1), FSerial.Statistics.BytesSent);
  AssertEquals(1, TQueueTransport(FTransport).Starts.Count);
end;
procedure TLazSerialWriteQueueTests.AutoReconnectStartsWithAnEmptyQueue;
var Watcher: TQueueWatcher; Scheduler: TFakeSerialRefreshScheduler;
  Device: TSerialDeviceInfo; I: Integer;
begin
  Watcher := nil;
  Scheduler := TFakeSerialRefreshScheduler.Create;
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialWatcher then
      Watcher := TQueueWatcher(FSerial.Components[I])
    else if FSerial.Components[I] is TSerialReconnect then
      TQueueReconnectAccess(FSerial.Components[I]).ReplaceScheduler(Scheduler);
  AssertNotNull(Watcher);
  Device := Default(TSerialDeviceInfo);
  Device.Device := FSerial.Device;
  Device.PersistentId := 'queue-device';
  FSerial.AutoReconnect := True;
  Watcher.Publish([Device]);
  ThreeWrites; StartFirst;
  Watcher.Publish([]);
  AssertFalse(FSerial.Active);
  AssertTrue(FSerial.ReconnectPending);
  CompleteCurrent(swoCancelled, 1);
  Device.Device := 'returned-port';
  Watcher.Publish([Device]);
  Scheduler.Fire;
  Watcher.Stop;
  AssertTrue(FSerial.Active);
  Pump;
  AssertFalse(FSerial.WritePending);
  AssertEquals(0, FSerial.PendingWriteCount);
  AssertEquals(1, TQueueTransport(FTransport).Starts.Count);
  AssertEquals(0, Length(FResults));
end;
{$IFDEF UNIX}
procedure TLazSerialWriteQueueTests.NativePtySendsQueuedBinaryAndEmptyWrites;
var Master, Slave: cint; Name: array[0..255] of Char; Received: AnsiString;
  Buffer: array[0..31] of Byte; Count: Integer; Deadline: QWord;
begin
  AssertEquals(0, OpenQueuePty(@Master, @Slave, @Name[0], nil, nil));
  try
    FSerial.Close;
    FSerial.InstallTransport(TLazSynapseSerialTransport.Create);
    FTransport := nil;
    FSerial.Device := StrPas(Name);
    FSerial.SynSer.LinuxLock := False;
    FSerial.Open;
    FSerial.WriteQueueEnabled := True;
    FSerial.WriteDataAsync('a' + #0#255, 1000);
    FSerial.WriteDataAsync('', 1000);
    FSerial.WriteDataAsync('end', 1000);
    fpFcntl(Master, F_SETFL, fpFcntl(Master, F_GETFL) or O_NONBLOCK);
    Received := '';
    Deadline := GetTickCount64 + 2000;
    while ((Length(FResults) < 3) or (Length(Received) < 6)) and
      (GetTickCount64 < Deadline) do
    begin
      CheckSynchronize(1);
      Count := fpRead(Master, Buffer, SizeOf(Buffer));
      if Count > 0 then
      begin
        SetLength(Received, Length(Received) + Count);
        Move(Buffer[0], Received[Length(Received) - Count + 1], Count);
      end;
    end;
    AssertEquals('a' + #0#255 + 'end', Received);
    AssertEquals(3, Length(FResults));
    AssertFalse(FSerial.WritePending);
    AssertEquals(QWord(6), FSerial.Statistics.BytesSent);
  finally
    FSerial.Close;
    Deadline := GetTickCount64 + 2000;
    while FSerial.ClosePending and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    fpClose(Slave); fpClose(Master);
  end;
end;
{$ENDIF}

initialization
  RegisterTest(TLazSerialWriteQueueTests);
end.
