unit LazSerialStatisticsCoreTests;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSerialStatistics,
  LazSerialCommon, LazSynaSer, LazSerialRead, LazSerialWrite, LazSerialNativeWrite,
  LazSerialTransport;

type
  TLazSerialStatisticsCoreTests = class(TTestCase)
  published
    procedure SnapshotsOwnTheirValuesAndKeepFirstCloseReason;
    procedure BufferTracksIncompleteLinesAndRetainsPeak;
    procedure ParserRetainedPrefixAndRecoverableErrorAreCounted;
    procedure LegacyBufferMetricsRemainZero;
    procedure BufferedReceptionUpdatesBeforeNotifications;
    procedure ReadFailureCountsOnceAndIncludesReportedBytes;
    procedure CancelledReadStillCountsNativeProgress;
    procedure AsyncProgressSurvivesSuppressedDelivery;
    procedure SynchronousNativeBytesAreNotCountedTwice;
    procedure SynchronousFailuresCountOnceRegardlessOfExceptionPreference;
  end;

implementation

type
  TStatisticsRead = class(TSerialReadOperation)
  private
    FCalls: Integer;
  protected
    function ReadChunk(ABuffer: Pointer; ACount: Integer;
      out AReceived: Integer): Integer; override;
  public
    Entered, Continued: TEvent;
    Payload: AnsiString;
    ErrorCode: Integer;
    WaitForCancellation: Boolean;
    constructor Create(const APort: ISerialWritePort; ALimit: Integer);
    destructor Destroy; override;
  end;

  {$IFDEF MSWINDOWS}
  TStatisticsWrite = class(TNativeSerialWriteOperation)
  private
    FCalls: Integer;
  protected
    function StartIO(ABuffer: Pointer; ACount: DWORD; out ATransferred: DWORD;
      var AOverlapped: TOverlapped): Boolean; override;
    function ReadTimeouts(out ATimeouts: TCommTimeouts): Boolean; override;
    function WriteTimeouts(const ATimeouts: TCommTimeouts): Boolean; override;
  end;
  {$ENDIF}

  TStatisticsErrorSerial = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
  end;

  TStatisticsErrorTransport = class(TLazSynapseSerialTransport)
  protected
    function CreateSerial: TBlockSerial; override;
  end;

  TStatisticsSyncSerial = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
    {$IFDEF MSWINDOWS}
    function StartOverlappedIO(ARead: Boolean; ABuffer: Pointer;
      ALength: DWord; var ATransferred: DWord;
      AOverlapped: POverlapped): Boolean; override;
    function ClearOverlappedIOError(var AError: DWord): Boolean; override;
    {$ENDIF}
  end;

constructor TStatisticsRead.Create(const APort: ISerialWritePort; ALimit: Integer);
begin
  inherited Create(APort, ALimit, nil);
  Entered := TEvent.Create(nil, True, False, '');
  Continued := TEvent.Create(nil, True, False, '');
end;

destructor TStatisticsRead.Destroy;
begin
  Entered.Free;
  Continued.Free;
  inherited Destroy;
end;

function TStatisticsRead.ReadChunk(ABuffer: Pointer; ACount: Integer;
  out AReceived: Integer): Integer;
begin
  Inc(FCalls);
  AReceived := 0;
  Result := 0;
  Entered.SetEvent;
  if FCalls = 1 then
  begin
    if WaitForCancellation then
      while not StopRequested do WaitDelay(1);
    AReceived := Length(Payload);
    if AReceived > ACount then AReceived := ACount;
    if AReceived > 0 then Move(Payload[1], ABuffer^, AReceived);
    Result := ErrorCode;
  end
  else
  begin
    Continued.SetEvent;
    WaitDelay(1);
  end;
end;

{$IFDEF MSWINDOWS}
function TStatisticsWrite.StartIO(ABuffer: Pointer; ACount: DWORD;
  out ATransferred: DWORD; var AOverlapped: TOverlapped): Boolean;
begin
  Inc(FCalls);
  ATransferred := 0;
  Result := FCalls = 1;
  if Result then ATransferred := 3
  else Windows.SetLastError(ErrNoDeviceAnswer);
end;

function TStatisticsWrite.ReadTimeouts(out ATimeouts: TCommTimeouts): Boolean;
begin
  FillChar(ATimeouts, SizeOf(ATimeouts), 0);
  Result := True;
end;

function TStatisticsWrite.WriteTimeouts(const ATimeouts: TCommTimeouts): Boolean;
begin
  Result := True;
end;
{$ENDIF}

function TStatisticsSyncSerial.PreTestFailing: Boolean;
begin
  Result := False;
end;

{$IFDEF MSWINDOWS}
function TStatisticsSyncSerial.StartOverlappedIO(ARead: Boolean; ABuffer: Pointer;
  ALength: DWord; var ATransferred: DWord; AOverlapped: POverlapped): Boolean;
begin
  ATransferred := ALength;
  if ARead then FillChar(ABuffer^, ALength, Ord('x'));
  Result := True;
end;

function TStatisticsSyncSerial.ClearOverlappedIOError(var AError: DWord): Boolean;
begin
  AError := 0;
  Result := True;
end;
{$ENDIF}

procedure AwaitReadClose(const AOperation: ISerialReadOperation);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 3000;
  while AOperation.GetClosePending and (GetTickCount64 < Deadline) do
    CheckSynchronize(1);
  TAssert.AssertFalse('Read cleanup completed', AOperation.GetClosePending);
  CheckSynchronize(1);
end;

procedure TLazSerialStatisticsCoreTests.SnapshotsOwnTheirValuesAndKeepFirstCloseReason;
var State: ISerialStatisticsState; First, Last: TSerialStatistics;
begin
  State := CreateSerialStatistics;
  State.AddReceived(High(Integer));
  State.AddReceived(High(Integer));
  State.AddSent(3);
  State.RecordError(7, 'first');
  State.MarkClosed(scrReadError);
  First := State.Snapshot;
  State.RecordError(8, 'second');
  State.AddSent(2);
  State.MarkClosed(scrUserRequest);
  Last := State.Snapshot;
  AssertEquals(QWord(4294967294), Last.BytesReceived);
  AssertEquals(QWord(3), First.BytesSent);
  AssertEquals(QWord(5), Last.BytesSent);
  AssertEquals('first', First.LastErrorMessage);
  AssertEquals('second', Last.LastErrorMessage);
  AssertEquals(QWord(2), Last.ErrorCount);
  AssertEquals(Ord(scrReadError), Ord(Last.CloseReason));
end;

procedure TLazSerialStatisticsCoreTests.BufferTracksIncompleteLinesAndRetainsPeak;
var Serial: TBlockSerial; State: ISerialStatisticsState; Data: AnsiString;
begin
  State := CreateSerialStatistics;
  Serial := TBlockSerial.Create;
  try
    Serial.StatisticsState := State;
    Serial.ConfigureReadBuffer(32);
    Serial.AppendReadBuffer('abc');
    AssertFalse(Serial.TryReadBuffered(True, Data));
    AssertEquals(QWord(0), State.Snapshot.ErrorCount);
    AssertEquals(3, State.Snapshot.ReadBufferUsed);
    Serial.AppendReadBuffer(#13#10 + 'next');
    AssertEquals(9, State.Snapshot.ReadBufferPeak);
    AssertTrue(Serial.TryReadBuffered(True, Data));
    AssertEquals('abc', Data);
    AssertEquals(4, State.Snapshot.ReadBufferUsed);
    Serial.Purge;
    AssertEquals(0, State.Snapshot.ReadBufferUsed);
    AssertEquals(9, State.Snapshot.ReadBufferPeak);
    AssertEquals('Memory injection is not native input', QWord(0), State.Snapshot.BytesReceived);
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsCoreTests.LegacyBufferMetricsRemainZero;
var Serial: TBlockSerial; State: ISerialStatisticsState;
begin
  State := CreateSerialStatistics;
  Serial := TBlockSerial.Create;
  try
    Serial.StatisticsState := State;
    Serial.LineBuffer := 'legacy';
    AssertEquals(0, State.Snapshot.ReadBufferUsed);
    AssertEquals(0, State.Snapshot.ReadBufferPeak);
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsCoreTests.BufferedReceptionUpdatesBeforeNotifications;
var Port: ISerialWritePort; Operation: ISerialReadOperation;
  Reader: TStatisticsRead; State: ISerialStatisticsState; Data: AnsiString;
begin
  State := CreateSerialStatistics;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Port.GetSerial.StatisticsState := State;
  Reader := TStatisticsRead.Create(Port, 32);
  Operation := Reader;
  Reader.Payload := 'abc' + #13#10;
  try
    Operation.Start;
    AssertEquals(Ord(wrSignaled), Ord(Reader.Continued.WaitFor(2000)));
    AssertEquals(QWord(5), State.Snapshot.BytesReceived);
    AssertEquals(5, State.Snapshot.ReadBufferUsed);
    AssertEquals(5, State.Snapshot.ReadBufferPeak);
    AssertTrue(Operation.TryReadData(True, Data));
    AssertEquals('abc', Data);
    AssertEquals(0, State.Snapshot.ReadBufferUsed);
    AssertEquals(QWord(5), State.Snapshot.BytesReceived);
    AssertEquals(5, State.Snapshot.ReadBufferPeak);
  finally
    Operation.ClosePort; AwaitReadClose(Operation); Operation.Detach;
    Operation := nil; Port := nil;
  end;
end;

procedure TLazSerialStatisticsCoreTests.ReadFailureCountsOnceAndIncludesReportedBytes;
var Port: ISerialWritePort; Operation: ISerialReadOperation;
  Reader: TStatisticsRead; State: ISerialStatisticsState;
  Deadline: QWord; Code: Integer; Message: string;
begin
  State := CreateSerialStatistics;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Port.GetSerial.StatisticsState := State;
  Reader := TStatisticsRead.Create(Port, 32);
  Operation := Reader;
  Reader.Payload := 'bad';
  Reader.ErrorCode := ErrNoDeviceAnswer;
  try
    Operation.Start;
    Deadline := GetTickCount64 + 2000;
    while not Operation.GetFailure(Code, Message) and (GetTickCount64 < Deadline) do Sleep(1);
    AssertEquals(ErrNoDeviceAnswer, Code);
    AssertEquals(QWord(3), State.Snapshot.BytesReceived);
    AssertEquals(QWord(1), State.Snapshot.ErrorCount);
    Operation.GetFailure(Code, Message);
    Operation.GetFailure(Code, Message);
    AssertEquals(QWord(1), State.Snapshot.ErrorCount);
  finally
    Operation.ClosePort; AwaitReadClose(Operation); Operation.Detach;
    Operation := nil; Port := nil;
  end;
end;

procedure TLazSerialStatisticsCoreTests.CancelledReadStillCountsNativeProgress;
var Port: ISerialWritePort; Operation: ISerialReadOperation;
  Reader: TStatisticsRead; State: ISerialStatisticsState;
begin
  State := CreateSerialStatistics;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Port.GetSerial.StatisticsState := State;
  Reader := TStatisticsRead.Create(Port, 32);
  Operation := Reader;
  Reader.Payload := 'end';
  Reader.WaitForCancellation := True;
  try
    Operation.Start;
    AssertEquals(Ord(wrSignaled), Ord(Reader.Entered.WaitFor(2000)));
    Operation.Detach;
    Operation.ClosePort;
    AwaitReadClose(Operation);
    AssertEquals(QWord(3), State.Snapshot.BytesReceived);
    AssertEquals(0, State.Snapshot.ReadBufferUsed);
    AssertEquals(QWord(0), State.Snapshot.ErrorCount);
  finally
    Operation.ClosePort; AwaitReadClose(Operation); Operation.Detach;
    Operation := nil; Port := nil;
  end;
end;

procedure TLazSerialStatisticsCoreTests.AsyncProgressSurvivesSuppressedDelivery;
var Port: ISerialWritePort; Operation: ISerialWriteOperation;
  State: ISerialStatisticsState; Path: string; Deadline: QWord;
begin
  State := CreateSerialStatistics;
  Path := GetTempFileName;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Port.GetSerial.Handle := FileCreate(Path);
  Port.GetSerial.StatisticsState := State;
  {$IFDEF MSWINDOWS}
  Operation := TStatisticsWrite.Create(Port, 'abcdef', 1, 2000, nil);
  {$ELSE}
  Port.GetSerial.MaxSendBandwidth := 1;
  Operation := TNativeSerialWriteOperation.Create(Port, StringOfChar('a', 65536),
    1, 10000, nil);
  {$ENDIF}
  try
    Operation.Start;
    Deadline := GetTickCount64 + 2000;
    {$IFDEF MSWINDOWS}
    while (State.Snapshot.ErrorCount = 0) and (GetTickCount64 < Deadline) do Sleep(1);
    AssertEquals(QWord(3), State.Snapshot.BytesSent);
    AssertEquals(QWord(1), State.Snapshot.ErrorCount);
    AssertEquals(ErrNoDeviceAnswer, State.Snapshot.LastErrorCode);
    {$ELSE}
    while (State.Snapshot.BytesSent = 0) and (GetTickCount64 < Deadline) do Sleep(1);
    AssertTrue(State.Snapshot.BytesSent > 0);
    AssertTrue(State.Snapshot.BytesSent < 65536);
    {$ENDIF}
    Operation.Detach;
    Operation.ClosePort;
    Deadline := GetTickCount64 + 3000;
    while (Port.GetSerial.Handle <> THandle(-1)) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    CheckSynchronize(1);
    {$IFDEF MSWINDOWS}
    AssertEquals(QWord(3), State.Snapshot.BytesSent);
    AssertEquals(QWord(1), State.Snapshot.ErrorCount);
    {$ELSE}
    AssertTrue(State.Snapshot.BytesSent > 0);
    AssertTrue(State.Snapshot.BytesSent < 65536);
    AssertEquals(QWord(0), State.Snapshot.ErrorCount);
    {$ENDIF}
  finally
    Operation.Detach; Operation.ClosePort;
    Deadline := GetTickCount64 + 3000;
    while (Port.GetSerial.Handle <> THandle(-1)) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    CheckSynchronize(1);
    Operation := nil; Port := nil;
    DeleteFile(Path);
  end;
end;

procedure TLazSerialStatisticsCoreTests.SynchronousNativeBytesAreNotCountedTwice;
var Serial: TStatisticsSyncSerial; State: ISerialStatisticsState;
  Data: AnsiString; Path: string;
begin
  State := CreateSerialStatistics;
  Path := GetTempFileName;
  Serial := TStatisticsSyncSerial.Create;
  try
    Serial.StatisticsState := State;
    Serial.Handle := FileCreate(Path);
    FileClose(Serial.Handle);
    Serial.Handle := FileOpen(Path, fmOpenReadWrite);
    AssertTrue('A read/write fixture descriptor is required', Serial.Handle <> THandle(-1));
    Data := 'abc' + #13#10;
    AssertEquals('Native send', 5, Serial.SendBuffer(Pointer(Data), Length(Data)));
    FileSeek(Serial.Handle, 0, fsFromBeginning);
    UniqueString(Data);
    AssertEquals('Native receive', 5, Serial.RecvBuffer(Pointer(Data), Length(Data)));
    AssertEquals(QWord(5), State.Snapshot.BytesSent);
    AssertEquals(QWord(5), State.Snapshot.BytesReceived);
  finally Serial.Free; DeleteFile(Path); end;
end;

procedure TLazSerialStatisticsCoreTests.ParserRetainedPrefixAndRecoverableErrorAreCounted;
var Port: ISerialWritePort; Reader: TStatisticsRead;
  Operation: ISerialReadOperation; State: ISerialStatisticsState;
  Data: AnsiString; Raised: Boolean;
begin
  State := CreateSerialStatistics;
  Port := TSerialWritePort.Create(TBlockSerial.Create);
  Port.GetSerial.StatisticsState := State;
  Reader := TStatisticsRead.Create(Port, 32);
  Operation := Reader;
  try
    Port.GetSerial.MaxLineLength := 4;
    Port.GetSerial.AppendReadBuffer('abc' + #13);
    Raised := False;
    try Operation.TryReadData(True, Data);
    except on E: ESynaSerError do
    begin Raised := True; AssertEquals(ErrMaxBuffer, E.ErrorCode); end; end;
    AssertTrue(Raised);
    AssertEquals(1, State.Snapshot.ReadBufferUsed);
    AssertEquals(4, State.Snapshot.ReadBufferPeak);
    AssertEquals(QWord(1), State.Snapshot.ErrorCount);
    AssertEquals(Ord(scrNone), Ord(State.Snapshot.CloseReason));
    Port.GetSerial.AppendReadBuffer(#10);
    Operation.TryReadData(True, Data);
    AssertEquals(0, State.Snapshot.ReadBufferUsed);
    AssertEquals(QWord(1), State.Snapshot.ErrorCount);
  finally
    Operation.ClosePort; AwaitReadClose(Operation); Operation.Detach;
    Operation := nil; Port := nil;
  end;
end;

function TStatisticsErrorSerial.PreTestFailing: Boolean;
begin
  Result := False;
end;

function TStatisticsErrorTransport.CreateSerial: TBlockSerial;
begin
  Result := TStatisticsErrorSerial.Create;
end;

procedure TLazSerialStatisticsCoreTests.SynchronousFailuresCountOnceRegardlessOfExceptionPreference;
var State: ISerialStatisticsState; Transport: TStatisticsErrorTransport;
  Path: string; Handle: THandle; RaiseNative, Raised: Boolean;
begin
  Path := GetTempFileName;
  Handle := FileCreate(Path);
  FileClose(Handle);
  try
    for RaiseNative := False to True do
    begin
      State := CreateSerialStatistics;
      Transport := TStatisticsErrorTransport.Create;
      try
        Transport.SetStatistics(State);
        Transport.NativeSerial.Handle := FileOpen(Path, fmOpenRead);
        AssertTrue(Transport.IsOpen);
        Transport.NativeSerial.RaiseExcept := RaiseNative;
        Raised := False;
        try Transport.SendString('x');
        except on E: ESynaSerError do Raised := True; end;
        AssertEquals(RaiseNative, Raised);
        AssertEquals(QWord(0), State.Snapshot.BytesSent);
        AssertEquals(QWord(1), State.Snapshot.ErrorCount);
        AssertTrue(State.Snapshot.LastErrorCode <> 0);
        Transport.NativeSerial.RaiseExcept := False;
        Transport.Close;
        AssertEquals('Closing must not recount the write failure', QWord(1), State.Snapshot.ErrorCount);
      finally
        Transport.NativeSerial.RaiseExcept := False;
        Transport.Free;
      end;
    end;
  finally DeleteFile(Path); end;
end;

initialization
  RegisterTest(TLazSerialStatisticsCoreTests);
end.
