unit LazSerialLineTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSynaSer,
  LazSerialTransportTests, LazSerialIoLifecycleTests;

type
  { Only the device I/O is simulated; buffering and line parsing use SynaSer. }
  TLineTestSerial = class(TBlockSerial)
  private
    FIncoming: AnsiString;
    FLock: TCriticalSection;
  protected
    function PreTestFailing: Boolean; override;
  public
    constructor Create;
    destructor Destroy; override;
    function CanRead(Timeout: Integer): Boolean; override;
    function RecvBuffer(Buffer: Pointer; ALength: Integer): Integer; override;
    function WaitingData: Integer; override;
    procedure QueueIncoming(const AData: AnsiString);
  end;

  TLineTestTransport = class(TFakeSerialTransport)
  private
    FSerial: TLineTestSerial;
  public
    constructor Create;
    destructor Destroy; override;
    function CanRead(const ATimeout: Integer): Boolean; override;
    function CanReadLine(const ATimeout: Integer): Boolean; override;
    function NativeSerial: TBlockSerial; override;
    function ReadPacket(const ATimeout: Integer): AnsiString; override;
    function ReadString(const ATimeout: Integer): AnsiString; override;
    property Serial: TLineTestSerial read FSerial;
  end;

  TLazSerialLineTests = class(TTestCase)
  private
    procedure PumpFor(const ADurationMs: Cardinal);
    procedure WaitForReceive(AProbe: TSerialIoProbe;
      const AExpectedCount: Integer);
  published
    procedure PartialBufferWaitsForNewBytes;
    procedure TotalTimeoutReassemblesEverySplit;
    procedure CompleteBufferedLinesRemainReadable;
    procedure RawReadinessIncludesPartialBuffer;
    procedure ConvertedLineEndsRemainReadable;
    procedure ReaderDoesNotRepeatPartialLineCallbacks;
    procedure ChangingToPacketModeMakesPartialBufferReadable;
  end;

implementation

constructor TLineTestSerial.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TLineTestSerial.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TLineTestSerial.PreTestFailing: Boolean;
begin
  Result := False;
end;

function TLineTestSerial.CanRead(Timeout: Integer): Boolean;
begin
  Result := WaitingData > 0;
  if not Result and (Timeout > 0) then
  begin
    Sleep(Timeout);
    Result := WaitingData > 0;
  end;
  FLastError := 0;
end;

function TLineTestSerial.RecvBuffer(Buffer: Pointer;
  ALength: Integer): Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FIncoming);
    if Result > ALength then
      Result := ALength;
    if Result > 0 then
      Move(FIncoming[1], Buffer^, Result);
    Delete(FIncoming, 1, Result);
    FLastError := 0;
  finally
    FLock.Release;
  end;
end;

function TLineTestSerial.WaitingData: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FIncoming);
  finally
    FLock.Release;
  end;
end;

procedure TLineTestSerial.QueueIncoming(const AData: AnsiString);
begin
  FLock.Acquire;
  try
    FIncoming := FIncoming + AData;
  finally
    FLock.Release;
  end;
end;

constructor TLineTestTransport.Create;
begin
  inherited Create;
  FSerial := TLineTestSerial.Create;
end;

destructor TLineTestTransport.Destroy;
begin
  FSerial.Free;
  inherited Destroy;
end;

function TLineTestTransport.CanRead(const ATimeout: Integer): Boolean;
begin
  Result := FSerial.CanReadEx(ATimeout);
end;

function TLineTestTransport.CanReadLine(const ATimeout: Integer): Boolean;
begin
  Result := FSerial.CanReadLine(ATimeout);
end;

function TLineTestTransport.NativeSerial: TBlockSerial;
begin
  Result := FSerial;
end;

function TLineTestTransport.ReadPacket(const ATimeout: Integer): AnsiString;
begin
  Result := FSerial.RecvPacket(ATimeout);
end;

function TLineTestTransport.ReadString(const ATimeout: Integer): AnsiString;
begin
  Result := FSerial.RecvString(ATimeout);
end;

procedure TLazSerialLineTests.PumpFor(const ADurationMs: Cardinal);
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ADurationMs;
  repeat
    CheckSynchronize(1);
  until GetTickCount64 >= Deadline;
end;

procedure TLazSerialLineTests.WaitForReceive(AProbe: TSerialIoProbe;
  const AExpectedCount: Integer);
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 1000;
  repeat
    CheckSynchronize(1);
  until (AProbe.ReceiveCount >= AExpectedCount) or
    (GetTickCount64 >= Deadline);
  AssertEquals(AExpectedCount, AProbe.ReceiveCount);
end;

procedure TLazSerialLineTests.PartialBufferWaitsForNewBytes;
var
  Serial: TLineTestSerial;
begin
  Serial := TLineTestSerial.Create;
  try
    Serial.QueueIncoming('abc' + #13);
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals('', Serial.RecvString(0));
    AssertEquals('abc' + #13, Serial.LineBuffer);
    AssertEquals(ErrTimeout, Serial.LastError);
    AssertFalse('An incomplete line must wait for new bytes',
      Serial.CanReadLine(0));
    Serial.QueueIncoming(#10);
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals('abc', Serial.RecvString(0));
    AssertEquals(0, Serial.LastError);
    AssertFalse(Serial.CanReadLine(0));
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialLineTests.TotalTimeoutReassemblesEverySplit;
const
  WireValue = 'fragmented line' + #13#10;
var
  Serial: TLineTestSerial;
  SplitPosition: Integer;
begin
  for SplitPosition := 1 to Length(WireValue) - 1 do
  begin
    Serial := TLineTestSerial.Create;
    try
      Serial.InterPacketTimeout := False;
      Serial.QueueIncoming(Copy(WireValue, 1, SplitPosition));
      AssertEquals('', Serial.RecvString(0));
      AssertEquals(ErrTimeout, Serial.LastError);
      Serial.QueueIncoming(Copy(WireValue, SplitPosition + 1, MaxInt));
      AssertEquals('Split position ' + IntToStr(SplitPosition),
        'fragmented line', Serial.RecvString(0));
      AssertEquals(0, Serial.LastError);
      AssertEquals('', Serial.LineBuffer);
      AssertEquals(0, Serial.WaitingData);
    finally
      Serial.Free;
    end;
  end;
end;

procedure TLazSerialLineTests.CompleteBufferedLinesRemainReadable;
var
  Serial: TLineTestSerial;
begin
  Serial := TLineTestSerial.Create;
  try
    Serial.QueueIncoming('first' + #13#10 + #13#10 + 'second' +
      #13#10 + 'tail');
    AssertEquals('first', Serial.RecvString(0));
    AssertEquals(0, Serial.WaitingData);
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals('', Serial.RecvString(0));
    AssertEquals('An empty complete line is not a timeout', 0, Serial.LastError);
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals('second', Serial.RecvString(0));
    AssertFalse(Serial.CanReadLine(0));
    AssertEquals('tail', Serial.LineBuffer);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialLineTests.RawReadinessIncludesPartialBuffer;
var
  Serial: TLineTestSerial;
begin
  Serial := TLineTestSerial.Create;
  try
    Serial.LineBuffer := 'partial' + #13;
    AssertTrue(Serial.CanReadEx(0));
    AssertEquals('partial' + #13, Serial.RecvPacket(0));
    AssertFalse(Serial.CanReadEx(0));
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialLineTests.ConvertedLineEndsRemainReadable;
var
  Serial: TLineTestSerial;
begin
  Serial := TLineTestSerial.Create;
  try
    Serial.ConvertLineEnd := True;
    Serial.QueueIncoming('first' + #13);
    AssertEquals('first', Serial.RecvString(0));
    Serial.LineBuffer := #10;
    AssertFalse('The LF completing the previous CR is not another line',
      Serial.CanReadLine(0));
    Serial.QueueIncoming('second' + #10 + 'third' + #13#10);
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals('second', Serial.RecvString(0));
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals('third', Serial.RecvString(0));
    AssertFalse(Serial.CanReadLine(0));
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialLineTests.ReaderDoesNotRepeatPartialLineCallbacks;
var
  Serial: TTestableLazSerial;
  Transport: TLineTestTransport;
  Probe: TSerialIoProbe;
begin
  Serial := TTestableLazSerial.Create(nil);
  Probe := TSerialIoProbe.Create;
  try
    Transport := TLineTestTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.RcvLineCRLF := True;
    Probe.Serial := Serial;
    Serial.OnRxData := @Probe.DataReceived;
    Serial.Open;
    Transport.Serial.QueueIncoming('first' + #13);
    WaitForReceive(Probe, 1);
    PumpFor(150);
    AssertEquals('No repeated callbacks while the line is incomplete',
      1, Probe.ReceiveCount);
    AssertFalse(Serial.DataAvailable);
    Transport.Serial.QueueIncoming(#10 + 'second' + #13#10 + 'tail');
    WaitForReceive(Probe, 3);
    PumpFor(150);
    AssertEquals(3, Probe.ReceiveCount);
    AssertEquals('firstsecond', Probe.ReceivedData);
    AssertFalse(Serial.DataAvailable);
  finally
    Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialLineTests.ChangingToPacketModeMakesPartialBufferReadable;
var
  Serial: TTestableLazSerial;
  Transport: TLineTestTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TLineTestTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.RcvLineCRLF := True;
    Serial.Open;
    Transport.Serial.QueueIncoming('partial' + #13);
    AssertEquals('', Serial.ReadData);
    AssertFalse(Serial.DataAvailable);
    Serial.RcvLineCRLF := False;
    AssertTrue(Serial.DataAvailable);
    AssertEquals('partial' + #13, Serial.ReadData);
    AssertFalse(Serial.DataAvailable);
  finally
    Serial.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialLineTests);

end.
