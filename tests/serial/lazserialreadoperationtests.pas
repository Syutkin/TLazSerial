unit LazSerialReadOperationTests;
{$mode ObjFPC}{$H+}
interface
uses Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry,
  LazSerialRead, LazSerialWrite, LazSynaSer, LazSerialCommon;
type
  TLazSerialReadOperationTests = class(TTestCase)
  private
    FNotifications: Integer;
    procedure Changed;
  published
    procedure WaitingInputDoesNotBlockMemoryReads;
    procedure CloseRetainsResourcesThroughDelayedCancellation;
    procedure FullBufferReportsDistinctFailure;
    procedure NotificationsStopWithoutConsumerProgress;
    {$IFDEF UNIX}
    procedure NativeReceivePreservesBinaryBytes;
    procedure CancelRestoresDescriptorFlags;
    {$ENDIF}
  end;
implementation
uses LazSerialNativeRead {$IFDEF UNIX}, BaseUnix, ctypes{$ENDIF};
{$IFDEF UNIX}
function OpenReadPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl; external 'util' name 'openpty';
{$ENDIF}
type
  TReadState = class(TInterfacedObject)
  public
    Entered, Released, Cancelling: TEvent;
    Payload: AnsiString;
    Calls, Largest: Integer;
    constructor Create;
    destructor Destroy; override;
  end;
  TControlledRead = class(TSerialReadOperation)
  private
    FState: TReadState;
    FReference: IInterface;
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; override;
  public
    constructor Create(const APort: ISerialWritePort; AState: TReadState;
      ALimit: Integer; AOnChanged: TSerialReadChanged);
  end;
constructor TReadState.Create;
begin
  inherited Create;
  Entered := TEvent.Create(nil, True, False, '');
  Released := TEvent.Create(nil, True, False, '');
  Cancelling := TEvent.Create(nil, True, False, '');
end;
destructor TReadState.Destroy;
begin Entered.Free; Released.Free; Cancelling.Free; inherited Destroy; end;
constructor TControlledRead.Create(const APort: ISerialWritePort;
  AState: TReadState; ALimit: Integer; AOnChanged: TSerialReadChanged);
begin
  inherited Create(APort, ALimit, AOnChanged);
  FState := AState;
  FReference := AState;
end;
function TControlledRead.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
begin
  Result := 0;
  AReceived := 0;
  Inc(FState.Calls);
  if ACount > FState.Largest then FState.Largest := ACount;
  FState.Entered.SetEvent;
  if FState.Calls = 1 then
  begin
    while not StopRequested and (FState.Released.WaitFor(1) <> wrSignaled) do ;
    if StopRequested then
    begin
      FState.Cancelling.SetEvent;
      FState.Released.WaitFor(2000);
      Exit;
    end;
    AReceived := Length(FState.Payload);
    if AReceived > ACount then AReceived := ACount;
    if AReceived > 0 then Move(FState.Payload[1], ABuffer^, AReceived);
  end
  else WaitDelay(10);
end;
procedure TLazSerialReadOperationTests.Changed;
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  Inc(FNotifications);
end;
procedure AwaitCleanup(const Operation: ISerialReadOperation);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while Operation.GetClosePending and (GetTickCount64 < Deadline) do
    CheckSynchronize(1);
  TAssert.AssertFalse(Operation.GetClosePending);
  CheckSynchronize(1);
end;
procedure TLazSerialReadOperationTests.WaitingInputDoesNotBlockMemoryReads;
var State: TReadState; Ref: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation; Data: AnsiString;
begin
  State := TReadState.Create; Ref := State;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TControlledRead.Create(Port, State, 32, @Changed);
  try
    Port.GetSerial.SetSynaError(1234);
    Operation.Start;
    AssertEquals(Ord(wrSignaled), Ord(State.Entered.WaitFor(2000)));
    AssertEquals('Worker does not mutate shared LastError', 1234, Port.GetSerial.LastError);
    AssertFalse(Operation.DataAvailable(False));
    AssertFalse(Operation.TryReadData(False, Data));
    AssertEquals('', Data);
    AssertEquals('Native operation remains held', Ord(wrTimeout), Ord(State.Released.WaitFor(0)));
  finally
    Operation.ClosePort; State.Released.SetEvent;
    AwaitCleanup(Operation); Operation.Detach;
    Operation := nil; Port := nil; Ref := nil;
  end;
end;
procedure TLazSerialReadOperationTests.CloseRetainsResourcesThroughDelayedCancellation;
var State: TReadState; Ref: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation;
begin
  State := TReadState.Create; Ref := State;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TControlledRead.Create(Port, State, 32, @Changed);
  try
    Operation.Start;
    AssertEquals(Ord(wrSignaled), Ord(State.Entered.WaitFor(2000)));
    Operation.ClosePort;
    AssertEquals(Ord(wrSignaled), Ord(State.Cancelling.WaitFor(2000)));
    AssertTrue(Operation.GetClosePending);
    Operation.Detach;
    State.Released.SetEvent;
    AwaitCleanup(Operation);
  finally
    State.Released.SetEvent; Operation.ClosePort;
    AwaitCleanup(Operation); Operation.Detach;
    Operation := nil; Port := nil; Ref := nil;
  end;
end;
procedure TLazSerialReadOperationTests.FullBufferReportsDistinctFailure;
var State: TReadState; Ref: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation; Code: Integer; Message: string; Deadline: QWord;
begin
  State := TReadState.Create; Ref := State;
  State.Payload := 'full'; State.Released.SetEvent;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TControlledRead.Create(Port, State, 4, @Changed);
  try
    Operation.Start;
    Deadline := GetTickCount64 + 2000;
    while not Operation.GetFailure(Code, Message) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertTrue(Operation.GetFailure(Code, Message));
    AssertEquals(LazSerialCommon.ErrReadBufferOverflow, Code);
    AssertEquals('Receive buffer limit exceeded', Message);
    AssertTrue(State.Largest <= 4);
  finally
    Operation.ClosePort; State.Released.SetEvent;
    AwaitCleanup(Operation); Operation.Detach;
    Operation := nil; Port := nil; Ref := nil;
  end;
end;
procedure TLazSerialReadOperationTests.NotificationsStopWithoutConsumerProgress;
var State: TReadState; Ref: IInterface; Port: ISerialWritePort;
  Operation: ISerialReadOperation; Deadline: QWord; Before: Integer;
begin
  State := TReadState.Create; Ref := State;
  State.Payload := 'ready'; State.Released.SetEvent;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Operation := TControlledRead.Create(Port, State, 32, @Changed);
  FNotifications := 0;
  try
    Operation.Start;
    Deadline := GetTickCount64 + 2000;
    while (FNotifications = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertEquals(1, FNotifications);
    Before := FNotifications;
    Deadline := GetTickCount64 + 50;
    while GetTickCount64 < Deadline do CheckSynchronize(1);
    AssertEquals(Before, FNotifications);
  finally
    Operation.ClosePort; State.Released.SetEvent;
    AwaitCleanup(Operation); Operation.Detach;
    Operation := nil; Port := nil; Ref := nil;
  end;
end;
{$IFDEF UNIX}
procedure TLazSerialReadOperationTests.NativeReceivePreservesBinaryBytes;
const Payload: AnsiString = 'bytes' + #0 + #255;
var Master, Slave: cint; Name: array[0..255] of Char;
  Port: ISerialWritePort; Operation: ISerialReadOperation;
  Serial: TBlockSerial; Data: AnsiString; Deadline: QWord;
begin
  AssertEquals(0, OpenReadPty(@Master, @Slave, @Name[0], nil, nil));
  Operation := nil;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  try
    Serial := Port.GetSerial;
    Serial.LinuxLock := False;
    Serial.Connect(StrPas(Name));
    Serial.Config(9600, 8, 'N', SB1, fcNone);
    AssertEquals(0, Serial.LastError);
    Operation := TNativeSerialReadOperation.Create(Port, 32, @Changed);
    Operation.Start;
    AssertEquals(Length(Payload), fpWrite(Master, Payload[1], Length(Payload)));
    Deadline := GetTickCount64 + 2000;
    while not Operation.DataAvailable(False) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertTrue(Operation.TryReadData(False, Data));
    AssertEquals(Payload, Data);
  finally
    if Operation <> nil then begin Operation.ClosePort; AwaitCleanup(Operation); Operation.Detach; end;
    Operation := nil; Port := nil; fpClose(Slave); fpClose(Master);
  end;
end;

procedure TLazSerialReadOperationTests.CancelRestoresDescriptorFlags;
var Master, Slave, Previous: cint; Name: array[0..255] of Char;
  Port: ISerialWritePort; Operation: ISerialReadOperation;
  Serial: TBlockSerial; Deadline: QWord;
begin
  AssertEquals(0, OpenReadPty(@Master, @Slave, @Name[0], nil, nil));
  Operation := nil;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  try
    Serial := Port.GetSerial;
    Serial.LinuxLock := False;
    Serial.Connect(StrPas(Name));
    Serial.Config(9600, 8, 'N', SB1, fcNone);
    Previous := fpFcntl(Serial.Handle, F_GETFL);
    Operation := TNativeSerialReadOperation.Create(Port, 32, @Changed);
    Operation.Start;
    AssertTrue((fpFcntl(Serial.Handle, F_GETFL) and O_NONBLOCK) <> 0);
    Operation.Cancel;
    Deadline := GetTickCount64 + 2000;
    while (fpFcntl(Serial.Handle, F_GETFL) <> Previous) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertEquals(Previous, fpFcntl(Serial.Handle, F_GETFL));
  finally
    if Operation <> nil then begin Operation.ClosePort; AwaitCleanup(Operation); Operation.Detach; end;
    Operation := nil; Port := nil; fpClose(Slave); fpClose(Master);
  end;
end;
{$ENDIF}
initialization RegisterTest(TLazSerialReadOperationTests);
end.
