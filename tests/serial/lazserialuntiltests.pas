unit LazSerialUntilTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSerial,
  LazSerialCommon, LazSerialRead, LazSerialWrite, LazSerialTransport,
  LazSerialStatistics,
  LazSerialTransportTests, LazSynaSer, SerialWatcher, SerialWatcherSupport,
  SerialWatcherComponentTests;

type
  TLazSerialUntilTests = class(TTestCase)
  private
    FOwner: TComponent;
    FSerial: TTestableLazSerial;
    FTransport: TFakeSerialTransport;
    FState: TObject;
    FStateReference: IInterface;
    FValues: TStringList;
    FTerminator: RawByteString;
    FMaxLength, FCalls, FParseErrors, FTerminalError: Integer;
    FOnePerCall, FDestroyOwner, FRaiseOnce: Boolean;
    procedure OpenSerial;
    procedure AwaitIdle;
    procedure Send(const AData: AnsiString);
    procedure Pump(AMilliseconds: Cardinal);
    procedure AwaitCalls(ACount: Integer);
    procedure AwaitValues(ACount: Integer);
    procedure Received(Sender: TObject);
    procedure Failed(Sender: TObject; ACode: Integer; const AMessage: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure WrongModesExplainRequiredSettingsWithoutChangingThem;
    procedure ClosedPortIsRejected;
    procedure PartialReadPreservesBytesAndClearsOutput;
    procedure MultipleEmptyAndBinaryMessagesReachMainThread;
    procedure DefaultLimitAllows4096BytesIncludingTerminator;
    procedure FailedTryDoesNotRepeatNotifications;
    procedure ConsumingOneMessageSchedulesTheRemainder;
    procedure LengthErrorPreservesDataAndDoesNotRepeatNotifications;
    procedure ReceiveHandlerCanDestroyOwner;
    procedure ReceiveExceptionDoesNotStopInput;
    procedure ModeChangeRejectsUntilWithoutLosingBytes;
    procedure ReopenDropsPartialMessage;
    procedure WorkerAccessIsRejected;
    procedure OldCustomReadersRemainCompatibleAndReportUnsupportedUntil;
    {$IFDEF UNIX}
    procedure NativePtySupportsSplitBinaryTerminator;
    {$ENDIF}
  end;

implementation

{$IFDEF UNIX}
uses BaseUnix, ctypes;
function OpenUntilPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl; external 'util' name 'openpty';
{$ENDIF}

type
  TUntilState = class(TInterfacedObject)
  public
    Lock: TCriticalSection;
    Ready: TEvent;
    Data: AnsiString;
    constructor Create;
    destructor Destroy; override;
    procedure Push(const AData: AnsiString);
  end;
  TUntilSerial = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
  public
    procedure Activate;
    procedure CloseSocket; override;
    function CanRead(Timeout: Integer): Boolean; override;
    function WaitingData: Integer; override;
    function RecvBuffer(Buffer: Pointer; ALength: Integer): Integer; override;
  end;
  TUntilRead = class(TSerialReadOperation)
  private
    FState: TUntilState;
    FReference: IInterface;
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; override;
  public
    constructor Create(const APort: ISerialWritePort; AState: TUntilState;
      ALimit: Integer; AChanged: TSerialReadChanged);
  end;
  TLegacyUntilRead = class(TInterfacedObject, ISerialReadOperation)
  public
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    function DataAvailable(ALineMode: Boolean): Boolean;
    function TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
    function GetFailure(out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function GetClosePending: Boolean;
  end;
  TUntilTransport = class(TFakeSerialTransport)
  private
    FPort: ISerialWritePort;
    FState: TUntilState;
    FReference: IInterface;
  public
    LegacyReader: Boolean;
    constructor Create(AState: TUntilState);
    procedure Connect(const ADevice: string); override;
    procedure SetStatistics(const AStatistics: ISerialStatisticsState); override;
    function NativeSerial: TBlockSerial; override;
    procedure SetStatusHandler(const AHandler: THookSerialStatus); override;
    function CreateReadOperation(const ALimit: Integer;
      const AOnChanged: TSerialReadChanged): ISerialReadOperation; override;
  end;
  TUntilWatcher = class(TSerialWatcher)
  public
    procedure Isolate;
    procedure Stop;
  end;
  TUntilApiThread = class(TThread)
  public
    Serial: TLazSerial;
    Rejected: Boolean;
    procedure Execute; override;
  end;

constructor TUntilState.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  Ready := TEvent.Create(nil, True, False, '');
end;
destructor TUntilState.Destroy;
begin Ready.Free; Lock.Free; inherited Destroy; end;
procedure TUntilState.Push(const AData: AnsiString);
begin
  Lock.Acquire;
  try Data := Data + AData; Ready.SetEvent;
  finally Lock.Release; end;
end;
function TUntilSerial.PreTestFailing: Boolean;
begin raise Exception.Create('TryReadUntil consulted native preflight'); end;
function TUntilSerial.CanRead(Timeout: Integer): Boolean;
begin raise Exception.Create('TryReadUntil consulted native readiness'); end;
function TUntilSerial.WaitingData: Integer;
begin raise Exception.Create('TryReadUntil consulted native queue'); end;
function TUntilSerial.RecvBuffer(Buffer: Pointer; ALength: Integer): Integer;
begin raise Exception.Create('TryReadUntil performed native input'); end;
procedure TUntilSerial.Activate;
begin FInstanceActive := True; LineBuffer := ''; end;
procedure TUntilSerial.CloseSocket;
begin FInstanceActive := False; end;
constructor TUntilRead.Create(const APort: ISerialWritePort; AState: TUntilState;
  ALimit: Integer; AChanged: TSerialReadChanged);
begin
  inherited Create(APort, ALimit, AChanged);
  FState := AState;
  FReference := AState;
end;
function TUntilRead.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
begin
  AReceived := 0;
  Result := 0;
  while not StopRequested and (FState.Ready.WaitFor(1) <> wrSignaled) do ;
  if StopRequested then Exit;
  FState.Lock.Acquire;
  try
    AReceived := Length(FState.Data);
    if AReceived > ACount then AReceived := ACount;
    if AReceived > 0 then Move(FState.Data[1], ABuffer^, AReceived);
    Delete(FState.Data, 1, AReceived);
    if FState.Data = '' then FState.Ready.ResetEvent;
  finally FState.Lock.Release; end;
end;
procedure TLegacyUntilRead.Start;
begin end;
procedure TLegacyUntilRead.Cancel;
begin end;
procedure TLegacyUntilRead.ClosePort;
begin end;
procedure TLegacyUntilRead.Detach;
begin end;
function TLegacyUntilRead.DataAvailable(ALineMode: Boolean): Boolean;
begin Result := False; end;
function TLegacyUntilRead.TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
begin AData := ''; Result := False; end;
function TLegacyUntilRead.GetFailure(out AErrorCode: Integer; out AErrorMessage: string): Boolean;
begin AErrorCode := 0; AErrorMessage := ''; Result := False; end;
function TLegacyUntilRead.GetClosePending: Boolean;
begin Result := False; end;
constructor TUntilTransport.Create(AState: TUntilState);
begin
  inherited Create;
  FPort := TSerialWritePort.Create(TUntilSerial.Create);
  FState := AState;
  FReference := AState;
end;
procedure TUntilTransport.Connect(const ADevice: string);
begin inherited Connect(ADevice); TUntilSerial(NativeSerial).Activate; end;
procedure TUntilTransport.SetStatistics(const AStatistics: ISerialStatisticsState);
begin inherited SetStatistics(AStatistics); NativeSerial.StatisticsState := AStatistics; end;
function TUntilTransport.NativeSerial: TBlockSerial;
begin Result := FPort.GetSerial; end;
procedure TUntilTransport.SetStatusHandler(const AHandler: THookSerialStatus);
begin inherited SetStatusHandler(AHandler); NativeSerial.OnStatus := AHandler; end;
function TUntilTransport.CreateReadOperation(const ALimit: Integer;
  const AOnChanged: TSerialReadChanged): ISerialReadOperation;
begin
  if LegacyReader then Result := TLegacyUntilRead.Create
  else Result := TUntilRead.Create(FPort, FState, ALimit, AOnChanged);
end;
procedure TUntilWatcher.Isolate;
begin
  SetInfrastructure(TSerialManualChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;
procedure TUntilWatcher.Stop;
begin StopWatching; end;
procedure TUntilApiThread.Execute;
var Data: RawByteString;
begin
  try Serial.TryReadUntil(';', Data);
  except on E: ELazSerialThreadError do Rejected := True; end;
end;

procedure TLazSerialUntilTests.SetUp;
var State: TUntilState; I: Integer;
begin
  inherited SetUp;
  State := TUntilState.Create;
  FState := State;
  FStateReference := State;
  FOwner := TComponent.Create(nil);
  FSerial := TTestableLazSerial.Create(FOwner);
  FTransport := TUntilTransport.Create(State);
  FSerial.InstallTransport(FTransport);
  FSerial.OnRxData := @Received;
  FSerial.OnError := @Failed;
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialWatcher then
      TUntilWatcher(FSerial.Components[I]).Isolate;
  FValues := TStringList.Create;
  FTerminator := ';';
  FMaxLength := 4096;
  FCalls := 0; FParseErrors := 0; FTerminalError := 0;
  FOnePerCall := False; FDestroyOwner := False; FRaiseOnce := False;
end;
procedure TLazSerialUntilTests.TearDown;
begin
  if FSerial <> nil then begin FSerial.Close; AwaitIdle; end;
  FreeAndNil(FOwner);
  FSerial := nil;
  Pump(10);
  FStateReference := nil;
  FValues.Free;
  inherited TearDown;
end;
procedure TLazSerialUntilTests.OpenSerial;
var I: Integer;
begin
  FSerial.BufferedRead := True;
  FSerial.Open;
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialWatcher then
      TUntilWatcher(FSerial.Components[I]).Stop;
end;
procedure TLazSerialUntilTests.AwaitIdle;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while (FSerial.ClosePending or FSerial.WritePending) and
    (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertFalse(FSerial.ClosePending);
  AssertFalse(FSerial.WritePending);
end;
procedure TLazSerialUntilTests.Send(const AData: AnsiString);
begin TUntilState(FState).Push(AData); end;
procedure TLazSerialUntilTests.Pump(AMilliseconds: Cardinal);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + AMilliseconds;
  repeat CheckSynchronize(1); until GetTickCount64 >= Deadline;
end;
procedure TLazSerialUntilTests.AwaitCalls(ACount: Integer);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while (FCalls < ACount) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(ACount, FCalls);
end;
procedure TLazSerialUntilTests.AwaitValues(ACount: Integer);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while (FValues.Count < ACount) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(ACount, FValues.Count);
  AssertEquals(0, FTerminalError);
end;
procedure TLazSerialUntilTests.Received(Sender: TObject);
var Data: RawByteString;
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  Inc(FCalls);
  if FRaiseOnce then
  begin FRaiseOnce := False; raise EInvalidOperation.Create('receive handler'); end;
  try
    while FSerial.TryReadUntil(FTerminator, Data, FMaxLength) do
    begin
      FValues.Add(Data);
      if FDestroyOwner then
      begin FSerial := nil; FreeAndNil(FOwner); Exit; end;
      if FOnePerCall then Break;
    end;
  except on E: ESynaSerError do
    begin AssertEquals(ErrMaxBuffer, E.ErrorCode); Inc(FParseErrors); end;
  end;
end;
procedure TLazSerialUntilTests.Failed(Sender: TObject; ACode: Integer; const AMessage: string);
begin FTerminalError := ACode; end;

procedure TLazSerialUntilTests.WrongModesExplainRequiredSettingsWithoutChangingThem;
var Data: RawByteString; Raised: Boolean;
begin
  Raised := False;
  try FSerial.TryReadUntil(';', Data);
  except on E: EInvalidOperation do
    begin
      Raised := True;
      AssertEquals('TryReadUntil requires BufferedRead=True; set it before opening the port', E.Message);
    end;
  end;
  AssertTrue(Raised);
  AssertFalse(FSerial.BufferedRead);
  FSerial.BufferedRead := True;
  FSerial.RcvLineCRLF := True;
  Raised := False;
  try FSerial.TryReadUntil(';', Data);
  except on E: EInvalidOperation do
    begin Raised := True; AssertEquals('TryReadUntil requires RcvLineCRLF=False', E.Message); end;
  end;
  AssertTrue(Raised);
  AssertTrue(FSerial.RcvLineCRLF);
end;
procedure TLazSerialUntilTests.ClosedPortIsRejected;
var Data: RawByteString; Raised: Boolean;
begin
  FSerial.BufferedRead := True;
  Raised := False;
  try FSerial.TryReadUntil(';', Data);
  except on E: Exception do
    begin Raised := True; AssertTrue(Pos('closed port', E.Message) > 0); end;
  end;
  AssertTrue(Raised);
end;
procedure TLazSerialUntilTests.PartialReadPreservesBytesAndClearsOutput;
var Data: RawByteString; Raw: string;
begin
  OpenSerial;
  Send('partial');
  AwaitCalls(1);
  Data := 'old';
  AssertFalse(FSerial.TryReadUntil(';', Data));
  AssertEquals('', Data);
  AssertEquals(7, FSerial.Statistics.ReadBufferUsed);
  AssertTrue(FSerial.TryReadData(Raw));
  AssertEquals('partial', Raw);
end;
procedure TLazSerialUntilTests.MultipleEmptyAndBinaryMessagesReachMainThread;
begin
  OpenSerial;
  Send('one;;' + #0#255 + ';tail');
  AwaitValues(3);
  AssertEquals('one', FValues[0]);
  AssertEquals('', FValues[1]);
  AssertEquals(#0#255, FValues[2]);
  AssertEquals(4, FSerial.Statistics.ReadBufferUsed);
end;
procedure TLazSerialUntilTests.DefaultLimitAllows4096BytesIncludingTerminator;
begin
  OpenSerial;
  Send(StringOfChar('x', 4095) + ';');
  AwaitValues(1);
  AssertEquals(4095, Length(FValues[0]));
  AssertEquals(0, FParseErrors);
end;
procedure TLazSerialUntilTests.FailedTryDoesNotRepeatNotifications;
var Before: Integer;
begin
  OpenSerial;
  Send('partial');
  AwaitCalls(1);
  Before := FCalls;
  Pump(40);
  AssertEquals(Before, FCalls);
  Send(';');
  AwaitValues(1);
  AssertEquals('partial', FValues[0]);
end;
procedure TLazSerialUntilTests.ConsumingOneMessageSchedulesTheRemainder;
begin
  FOnePerCall := True;
  OpenSerial;
  Send('one;two;three;');
  AwaitValues(3);
  AssertEquals(3, FCalls);
end;
procedure TLazSerialUntilTests.LengthErrorPreservesDataAndDoesNotRepeatNotifications;
var Before: Integer; Data: RawByteString;
begin
  FMaxLength := 5;
  OpenSerial;
  Send('12345;');
  AwaitCalls(1);
  AssertEquals(1, FParseErrors);
  Before := FCalls;
  Pump(40);
  AssertEquals(Before, FCalls);
  AssertTrue(FSerial.Active);
  AssertEquals(0, FTerminalError);
  AssertEquals(6, FSerial.Statistics.ReadBufferUsed);
  AssertEquals(QWord(1), FSerial.Statistics.ErrorCount);
  AssertEquals(ErrMaxBuffer, FSerial.Statistics.LastErrorCode);
  AssertTrue(FSerial.TryReadUntil(';', Data, 6));
  AssertEquals('12345', Data);
end;
procedure TLazSerialUntilTests.ReceiveHandlerCanDestroyOwner;
begin
  FDestroyOwner := True;
  OpenSerial;
  Send('one;tail;');
  AwaitValues(1);
  AssertNull(FSerial);
  AssertNull(FOwner);
  Pump(20);
  AssertEquals(1, FCalls);
end;
procedure TLazSerialUntilTests.ReceiveExceptionDoesNotStopInput;
var Raised: Boolean; Deadline: QWord;
begin
  OpenSerial;
  FRaiseOnce := True;
  Send('first;');
  Raised := False;
  Deadline := GetTickCount64 + 2000;
  repeat
    try CheckSynchronize(1);
    except on E: EInvalidOperation do begin Raised := True; AssertEquals('receive handler', E.Message); end; end;
  until Raised or (GetTickCount64 >= Deadline);
  AssertTrue(Raised);
  Send('second;');
  AwaitValues(2);
  AssertEquals('first', FValues[0]);
  AssertEquals('second', FValues[1]);
end;
procedure TLazSerialUntilTests.ModeChangeRejectsUntilWithoutLosingBytes;
var Data: RawByteString; Raised: Boolean;
begin
  OpenSerial;
  Send('partial');
  AwaitCalls(1);
  FSerial.RcvLineCRLF := True;
  Raised := False;
  try FSerial.TryReadUntil(';', Data);
  except on E: EInvalidOperation do begin Raised := True; AssertEquals('TryReadUntil requires RcvLineCRLF=False', E.Message); end; end;
  AssertTrue(Raised);
  FSerial.RcvLineCRLF := False;
  Send(';');
  AwaitValues(1);
  AssertEquals('partial', FValues[0]);
end;
procedure TLazSerialUntilTests.ReopenDropsPartialMessage;
begin
  OpenSerial;
  Send('old-partial');
  AwaitCalls(1);
  FSerial.Close;
  AwaitIdle;
  OpenSerial;
  Send('new;');
  AwaitValues(1);
  AssertEquals('new', FValues[0]);
end;
procedure TLazSerialUntilTests.WorkerAccessIsRejected;
var Worker: TUntilApiThread;
begin
  Worker := TUntilApiThread.Create(True);
  try
    Worker.Serial := FSerial;
    Worker.Start;
    Worker.WaitFor;
    AssertTrue(Worker.Rejected);
  finally Worker.Free; end;
end;
procedure TLazSerialUntilTests.OldCustomReadersRemainCompatibleAndReportUnsupportedUntil;
var Data: RawByteString; Raised: Boolean;
begin
  TUntilTransport(FTransport).LegacyReader := True;
  OpenSerial;
  Raised := False;
  try FSerial.TryReadUntil(';', Data);
  except on E: EInvalidOperation do
    begin Raised := True; AssertEquals('The active custom reader does not support TryReadUntil', E.Message); end;
  end;
  AssertTrue(Raised);
end;
{$IFDEF UNIX}
procedure TLazSerialUntilTests.NativePtySupportsSplitBinaryTerminator;
var Master, Slave: cint; Name: array[0..255] of Char; Wire: AnsiString;
  Deadline: QWord;
begin
  AssertEquals(0, OpenUntilPty(@Master, @Slave, @Name[0], nil, nil));
  try
    FSerial.InstallTransport(TLazSynapseSerialTransport.Create);
    FSerial.Device := StrPas(Name);
    FSerial.SynSer.LinuxLock := False;
    FTerminator := #0#255;
    OpenSerial;
    Wire := 'first' + #0;
    AssertEquals(Length(Wire), fpWrite(Master, Wire[1], Length(Wire)));
    Deadline := GetTickCount64 + 2000;
    while ((FCalls = 0) or (FSerial.Statistics.ReadBufferUsed < Length(Wire))) and
      (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertTrue(FCalls > 0);
    AssertEquals(Length(Wire), FSerial.Statistics.ReadBufferUsed);
    AssertEquals(0, FValues.Count);
    Wire := #255#0#255 + 'tail';
    AssertEquals(Length(Wire), fpWrite(Master, Wire[1], Length(Wire)));
    AwaitValues(2);
    AssertEquals('first', FValues[0]);
    AssertEquals('', FValues[1]);
    Deadline := GetTickCount64 + 2000;
    while (FSerial.Statistics.ReadBufferUsed < 4) and
      (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertEquals(4, FSerial.Statistics.ReadBufferUsed);
  finally
    FSerial.Close; AwaitIdle;
    fpClose(Slave); fpClose(Master);
  end;
end;
{$ENDIF}

initialization
  RegisterTest(TLazSerialUntilTests);

end.
