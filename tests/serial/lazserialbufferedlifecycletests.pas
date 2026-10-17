unit LazSerialBufferedLifecycleTests;
{$mode ObjFPC}{$H+}
interface
uses Classes, SysUtils, SyncObjs, ExtCtrls, FpcUnit, TestRegistry,
  LazSerial, LazSerialCommon, LazSerialRead, LazSerialWrite, LazSerialTransportTests;
type
  TLazSerialBufferedLifecycleTests = class(TTestCase)
  private
    FSerial: TTestableLazSerial;
    FOwner: TComponent;
    FState: TObject;
    FReference: IInterface;
    FTicks: Integer;
    procedure Tick(Sender: TObject);
    procedure PumpTicks;
    procedure AwaitIdle;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure WaitingReadKeepsGuiResponsive;
    procedure CloseWaitsForBothOperationsOutsideGui;
    procedure DestroyOwnerRetainsPortUntilBothOperationsFinish;
    procedure ActiveReaderRejectsConfigurationChanges;
    procedure NewApiRejectsWorkerCalls;
  end;
implementation
uses Forms, LazSynaSer;
type
  TReceiveApiThread = class(TThread)
  public
    Serial: TLazSerial;
    Rejected: Integer;
    procedure Execute; override;
  end;
  TDuplexState = class(TInterfacedObject)
  public
    ReadStarted, ReadCancelling, ReadReleased: TEvent;
    WriteStarted, WriteCancelling, WriteReleased: TEvent;
    Closed: LongInt;
    constructor Create;
    destructor Destroy; override;
  end;
  TDuplexSerial = class(TBlockSerial)
  private
    FState: TDuplexState;
    FReference: IInterface;
  public
    constructor Create(AState: TDuplexState);
    procedure Attach;
    procedure CloseSocket; override;
  end;
  TDuplexRead = class(TSerialReadOperation)
  private FState: TDuplexState; FReference: IInterface;
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; override;
  public
    constructor Create(const APort: ISerialWritePort; AState: TDuplexState;
      ALimit: Integer; AOnChanged: TSerialReadChanged);
  end;
  TDuplexWrite = class(TSerialWriteOperation)
  private FState: TDuplexState; FReference: IInterface;
  protected
    procedure ExecuteWrite(var AResult: TSerialWriteResult); override;
  public
    constructor Create(const APort: ISerialWritePort; AState: TDuplexState;
      const AData: AnsiString; AId: QWord; ATimeout: Cardinal;
      AOnFinished: TSerialWriteFinished);
  end;
  TDuplexTransport = class(TFakeSerialTransport)
  private FPort: ISerialWritePort; FState: TDuplexState; FReference: IInterface;
  public
    constructor Create(AState: TDuplexState);
    procedure Connect(const ADevice: string); override;
    function IsOpen: Boolean; override;
    function NativeSerial: TBlockSerial; override;
    function CreateReadOperation(const ALimit: Integer;
      const AOnChanged: TSerialReadChanged): ISerialReadOperation; override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeout: Cardinal; const AOnFinished: TSerialWriteFinished): ISerialWriteOperation; override;
  end;
procedure TReceiveApiThread.Execute;
var I: Integer; Data: string; Pending: Boolean;
begin
  for I := 0 to 3 do
    try
      case I of
        0: Serial.BufferedRead := True;
        1: Serial.ReadBufferLimit := 128;
        2: Serial.TryReadData(Data);
        3: Pending := Serial.ClosePending;
      end;
    except on E: ELazSerialThreadError do Inc(Rejected); end;
end;
constructor TDuplexState.Create;
begin
  inherited Create;
  ReadStarted := TEvent.Create(nil, True, False, '');
  ReadCancelling := TEvent.Create(nil, True, False, '');
  ReadReleased := TEvent.Create(nil, True, False, '');
  WriteStarted := TEvent.Create(nil, True, False, '');
  WriteCancelling := TEvent.Create(nil, True, False, '');
  WriteReleased := TEvent.Create(nil, True, False, '');
end;
destructor TDuplexState.Destroy;
begin
  ReadStarted.Free; ReadCancelling.Free; ReadReleased.Free;
  WriteStarted.Free; WriteCancelling.Free; WriteReleased.Free;
  inherited Destroy;
end;
constructor TDuplexSerial.Create(AState: TDuplexState);
begin inherited Create; FState := AState; FReference := AState; end;
procedure TDuplexSerial.Attach;
begin FInstanceActive := True; end;
procedure TDuplexSerial.CloseSocket;
begin
  if FInstanceActive then begin FInstanceActive := False; InterlockedIncrement(FState.Closed); end;
end;
constructor TDuplexRead.Create(const APort: ISerialWritePort; AState: TDuplexState;
  ALimit: Integer; AOnChanged: TSerialReadChanged);
begin inherited Create(APort, ALimit, AOnChanged); FState := AState; FReference := AState; end;
function TDuplexRead.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
begin
  Result := 0; AReceived := 0;
  FState.ReadStarted.SetEvent;
  while not StopRequested do WaitDelay(1);
  FState.ReadCancelling.SetEvent;
  FState.ReadReleased.WaitFor(5000);
end;
constructor TDuplexWrite.Create(const APort: ISerialWritePort; AState: TDuplexState;
  const AData: AnsiString; AId: QWord; ATimeout: Cardinal; AOnFinished: TSerialWriteFinished);
begin inherited Create(APort, AData, AId, ATimeout, AOnFinished); FState := AState; FReference := AState; end;
procedure TDuplexWrite.ExecuteWrite(var AResult: TSerialWriteResult);
begin
  FState.WriteStarted.SetEvent;
  while not StopRequested do WaitDelay(1);
  FState.WriteCancelling.SetEvent;
  FState.WriteReleased.WaitFor(5000);
  SetStopped(AResult);
end;
constructor TDuplexTransport.Create(AState: TDuplexState);
begin
  inherited Create; FState := AState; FReference := AState;
  FPort := TSerialWritePort.Create(TDuplexSerial.Create(AState));
end;
procedure TDuplexTransport.Connect(const ADevice: string);
begin inherited Connect(ADevice); TDuplexSerial(NativeSerial).Attach; end;
function TDuplexTransport.IsOpen: Boolean;
begin Result := NativeSerial.InstanceActive; end;
function TDuplexTransport.NativeSerial: TBlockSerial;
begin Result := FPort.GetSerial; end;
function TDuplexTransport.CreateReadOperation(const ALimit: Integer;
  const AOnChanged: TSerialReadChanged): ISerialReadOperation;
begin Result := TDuplexRead.Create(FPort, FState, ALimit, AOnChanged); end;
function TDuplexTransport.CreateWriteOperation(const AData: AnsiString; const AId: QWord;
  const ATimeout: Cardinal; const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
begin Result := TDuplexWrite.Create(FPort, FState, AData, AId, ATimeout, AOnFinished); end;
procedure TLazSerialBufferedLifecycleTests.SetUp;
var State: TDuplexState;
begin
  State := TDuplexState.Create; FState := State; FReference := State;
  FOwner := TComponent.Create(nil);
  FSerial := TTestableLazSerial.Create(FOwner);
  FSerial.InstallTransport(TDuplexTransport.Create(State));
  FSerial.BufferedRead := True;
  FSerial.Open;
  AssertEquals(Ord(wrSignaled), Ord(State.ReadStarted.WaitFor(2000)));
end;
procedure TLazSerialBufferedLifecycleTests.TearDown;
begin
  TDuplexState(FState).ReadReleased.SetEvent;
  TDuplexState(FState).WriteReleased.SetEvent;
  if FSerial <> nil then begin FSerial.Close; AwaitIdle; end;
  FreeAndNil(FOwner); FSerial := nil;
  CheckSynchronize(1);
  FReference := nil;
end;
procedure TLazSerialBufferedLifecycleTests.Tick(Sender: TObject);
begin Inc(FTicks); end;
procedure TLazSerialBufferedLifecycleTests.PumpTicks;
var Timer: TTimer; Deadline: QWord;
begin
  FTicks := 0;
  Timer := TTimer.Create(nil);
  try
    Timer.Interval := 1; Timer.OnTimer := @Tick; Timer.Enabled := True;
    Deadline := GetTickCount64 + 2000;
    while (FTicks < 3) and (GetTickCount64 < Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(1); end;
    AssertTrue('LCL timer must execute while native I/O is held', FTicks >= 3);
  finally Timer.Free; end;
end;
procedure TLazSerialBufferedLifecycleTests.AwaitIdle;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while (FSerial.ClosePending or FSerial.WritePending) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertFalse(FSerial.ClosePending); AssertFalse(FSerial.WritePending);
end;
procedure TLazSerialBufferedLifecycleTests.WaitingReadKeepsGuiResponsive;
var Data: string;
begin
  AssertFalse(FSerial.DataAvailable);
  AssertFalse(FSerial.TryReadData(Data));
  AssertEquals('', FSerial.ReadData);
  PumpTicks;
  AssertEquals(0, TDuplexState(FState).Closed);
end;
procedure TLazSerialBufferedLifecycleTests.CloseWaitsForBothOperationsOutsideGui;
var State: TDuplexState; Rejected: Boolean;
begin
  State := TDuplexState(FState);
  FSerial.WriteDataAsync('pending', 3000);
  AssertEquals(Ord(wrSignaled), Ord(State.WriteStarted.WaitFor(2000)));
  FSerial.Close;
  AssertFalse(FSerial.Active);
  AssertEquals(Ord(wrSignaled), Ord(State.ReadCancelling.WaitFor(2000)));
  AssertEquals(Ord(wrSignaled), Ord(State.WriteCancelling.WaitFor(2000)));
  AssertTrue(FSerial.ClosePending); AssertTrue(FSerial.WritePending);
  PumpTicks;
  Rejected := False;
  try FSerial.Open; except on E: EInvalidOperation do Rejected := True; end;
  AssertTrue(Rejected);
  State.ReadReleased.SetEvent;
  PumpTicks;
  AssertTrue(FSerial.ClosePending); AssertEquals(0, State.Closed);
  State.WriteReleased.SetEvent;
  AwaitIdle;
  AssertEquals(1, State.Closed);
  FSerial.Open;
  AssertTrue(FSerial.Active); AssertFalse(FSerial.DataAvailable);
end;
procedure TLazSerialBufferedLifecycleTests.DestroyOwnerRetainsPortUntilBothOperationsFinish;
var State: TDuplexState; Deadline: QWord;
begin
  State := TDuplexState(FState);
  FSerial.WriteDataAsync('pending', 3000);
  AssertEquals(Ord(wrSignaled), Ord(State.WriteStarted.WaitFor(2000)));
  FreeAndNil(FOwner); FSerial := nil;
  AssertEquals(Ord(wrSignaled), Ord(State.ReadCancelling.WaitFor(2000)));
  AssertEquals(Ord(wrSignaled), Ord(State.WriteCancelling.WaitFor(2000)));
  PumpTicks; AssertEquals(0, State.Closed);
  State.WriteReleased.SetEvent;
  PumpTicks; AssertEquals(0, State.Closed);
  State.ReadReleased.SetEvent;
  Deadline := GetTickCount64 + 2000;
  while (State.Closed = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(1, State.Closed);
  CheckSynchronize(1);
end;
procedure TLazSerialBufferedLifecycleTests.ActiveReaderRejectsConfigurationChanges;
var I: Integer; Rejected: Boolean;
begin
  for I := 0 to 6 do
  begin
    Rejected := False;
    try
      case I of
        0: FSerial.ReadBufferLimit := 12;
        1: FSerial.BufferedRead := False;
        2: FSerial.SynSer.MaxLineLength := 12;
        3: FSerial.BaudRate := br__9600;
        4: FSerial.SetDTR(True);
        5: FSerial.SetRTS(True);
        6: FSerial.Device := 'changed';
      end;
    except on E: EInvalidOperation do Rejected := True; end;
    AssertTrue('Configuration operation ' + IntToStr(I), Rejected);
  end;
  FSerial.RcvLineCRLF := True;
  AssertTrue(FSerial.Active);
end;
procedure TLazSerialBufferedLifecycleTests.NewApiRejectsWorkerCalls;
var Worker: TReceiveApiThread;
begin
  Worker := TReceiveApiThread.Create(True);
  try
    Worker.Serial := FSerial;
    Worker.Start;
    Worker.WaitFor;
    AssertEquals(4, Worker.Rejected);
  finally Worker.Free; end;
end;
initialization RegisterTest(TLazSerialBufferedLifecycleTests);
end.
