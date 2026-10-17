unit LazSerialUntilParserTests;

{$mode ObjFPC}{$H+}

interface

uses SysUtils, FpcUnit, TestRegistry, LazSynaSer, LazSerialStatistics;

type
  TLazSerialUntilParserTests = class(TTestCase)
  published
    procedure EmptyAndIncompleteReadsNeverPerformIO;
    procedure MultipleEmptyAndBinaryResultsPreserveTail;
    procedure MultibyteTerminatorWorksAtEverySplit;
    procedure CrLfMatchingIgnoresLineConversionAndLineLimit;
    procedure TerminatorAndPayloadPreserveCodePageBytes;
    procedure LimitIncludesTerminatorAndAcceptsExactBoundary;
    procedure OversizedResultRaisesWithoutConsumingBytes;
    procedure IncompleteOversizedResultCanBeRecovered;
    procedure FirstResultIsIndependentOfOversizedTail;
    procedure InvalidArgumentsLeaveBufferUnchanged;
    procedure ChangingTerminatorRestartsSearch;
    procedure ReplacingAndConsumingBytesRestartSearch;
    procedure IncrementalReadsSurviveWrapAndGrowth;
    procedure ExtractionUpdatesUsageWithoutCountingReceivedBytes;
  end;

implementation

type
  TUntilMemorySerial = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
  public
    PacketReads: Integer;
    function RecvPacket(Timeout: Integer): AnsiString; override;
    function CanRead(Timeout: Integer): Boolean; override;
    function WaitingData: Integer; override;
    function RecvBuffer(Buffer: Pointer; ALength: Integer): Integer; override;
  end;

function TUntilMemorySerial.PreTestFailing: Boolean;
begin raise Exception.Create('Unexpected native preflight'); end;
function TUntilMemorySerial.CanRead(Timeout: Integer): Boolean;
begin raise Exception.Create('Unexpected native readiness'); end;
function TUntilMemorySerial.WaitingData: Integer;
begin raise Exception.Create('Unexpected native queue query'); end;
function TUntilMemorySerial.RecvBuffer(Buffer: Pointer; ALength: Integer): Integer;
begin raise Exception.Create('Unexpected native read'); end;
function TUntilMemorySerial.RecvPacket(Timeout: Integer): AnsiString;
begin Inc(PacketReads); Result := inherited RecvPacket(Timeout); end;

procedure TLazSerialUntilParserTests.EmptyAndIncompleteReadsNeverPerformIO;
var S: TUntilMemorySerial; Data: RawByteString; I: Integer;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.RaiseExcept := True;
    Data := 'old';
    AssertFalse(S.TryReadBufferedUntil(';', Data));
    AssertEquals('', Data);
    S.AppendReadBuffer('partial');
    for I := 1 to 3 do
    begin
      AssertFalse(S.TryReadBufferedUntil(';', Data));
      AssertEquals('', Data);
      AssertEquals('partial', S.LineBuffer);
    end;
    AssertTrue(S.RaiseExcept);
    AssertEquals(0, S.PacketReads);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.MultipleEmptyAndBinaryResultsPreserveTail;
var S: TUntilMemorySerial; Data: RawByteString;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('ab' + #0#255 + ';;last;tail');
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals('ab' + #0#255, Data);
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals('', Data);
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals('last', Data);
    AssertFalse(S.TryReadBufferedUntil(';', Data));
    AssertEquals('tail', S.LineBuffer);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.MultibyteTerminatorWorksAtEverySplit;
const Wire = 'xABAABABrest';
var S: TUntilMemorySerial; Data: RawByteString; I: Integer;
begin
  for I := 0 to Length(Wire) do
  begin
    S := TUntilMemorySerial.Create;
    try
      S.ConfigureReadBuffer(64);
      S.AppendReadBuffer(Copy(Wire, 1, I));
      if I < 8 then AssertFalse(S.TryReadBufferedUntil('ABAB', Data));
      S.AppendReadBuffer(Copy(Wire, I + 1, MaxInt));
      AssertTrue(S.TryReadBufferedUntil('ABAB', Data));
      AssertEquals('xABA', Data);
      AssertEquals('rest', S.LineBuffer);
    finally S.Free; end;
  end;
end;

procedure TLazSerialUntilParserTests.CrLfMatchingIgnoresLineConversionAndLineLimit;
var S: TUntilMemorySerial; Data: RawByteString;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.ConvertLineEnd := True;
    S.MaxLineLength := 1;
    S.AppendReadBuffer('one' + #13 + 'two' + #10 + 'three' + #13);
    AssertFalse(S.TryReadBufferedUntil(#13#10, Data));
    S.AppendReadBuffer(#10);
    AssertTrue(S.TryReadBufferedUntil(#13#10, Data));
    AssertEquals('one' + #13 + 'two' + #10 + 'three', Data);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.TerminatorAndPayloadPreserveCodePageBytes;
var S: TUntilMemorySerial; Data, Terminator: RawByteString;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    Terminator := #233#0;
    SetCodePage(Terminator, 1251, False);
    S.AppendReadBuffer(#255#128#233#0 + 'tail');
    AssertTrue(S.TryReadBufferedUntil(Terminator, Data));
    AssertEquals(2, Length(Data));
    AssertEquals(255, Ord(Data[1]));
    AssertEquals(128, Ord(Data[2]));
    AssertEquals('tail', S.LineBuffer);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.LimitIncludesTerminatorAndAcceptsExactBoundary;
var S: TUntilMemorySerial; Data: RawByteString;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('abcd');
    AssertFalse(S.TryReadBufferedUntil(';', Data, 5));
    S.AppendReadBuffer(';');
    AssertTrue(S.TryReadBufferedUntil(';', Data, 5));
    AssertEquals('abcd', Data);
    S.AppendReadBuffer('abcdEND');
    AssertTrue(S.TryReadBufferedUntil('END', Data, 7));
    AssertEquals('abcd', Data);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.OversizedResultRaisesWithoutConsumingBytes;
var S: TUntilMemorySerial; Data: RawByteString; I: Integer; Raised: Boolean;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('12345;ok;');
    for I := 0 to 1 do
    begin
      S.RaiseExcept := I = 1;
      Data := 'old';
      Raised := False;
      try S.TryReadBufferedUntil(';', Data, 5);
      except on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrMaxBuffer, E.ErrorCode);
      end; end;
      AssertTrue(Raised);
      AssertEquals('', Data);
      AssertEquals('12345;ok;', S.LineBuffer);
    end;
    AssertTrue(S.TryReadBufferedUntil(';', Data, 6));
    AssertEquals('12345', Data);
    AssertTrue(S.TryReadBufferedUntil(';', Data, 3));
    AssertEquals('ok', Data);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.IncompleteOversizedResultCanBeRecovered;
var S: TUntilMemorySerial; Data: RawByteString; Raw: AnsiString; Raised: Boolean;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('12345');
    Raised := False;
    try S.TryReadBufferedUntil(';', Data, 5);
    except on E: ESynaSerError do begin Raised := True; AssertEquals(ErrMaxBuffer, E.ErrorCode); end; end;
    AssertTrue(Raised);
    AssertEquals('12345', S.LineBuffer);
    AssertTrue(S.TryReadBuffered(False, Raw));
    AssertEquals('12345', Raw);
    S.AppendReadBuffer('ok;');
    AssertTrue(S.TryReadBufferedUntil(';', Data, 5));
    AssertEquals('ok', Data);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.FirstResultIsIndependentOfOversizedTail;
var S: TUntilMemorySerial; Data: RawByteString;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('ok;' + StringOfChar('x', 30));
    AssertTrue(S.TryReadBufferedUntil(';', Data, 3));
    AssertEquals('ok', Data);
    AssertEquals(StringOfChar('x', 30), S.LineBuffer);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.InvalidArgumentsLeaveBufferUnchanged;
var S: TUntilMemorySerial; Data: RawByteString; I: Integer; Raised: Boolean;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('data;');
    for I := 0 to 3 do
    begin
      Raised := False;
      try
        case I of
          0: S.TryReadBufferedUntil('', Data);
          1: S.TryReadBufferedUntil(';', Data, 0);
          2: S.TryReadBufferedUntil(';', Data, -1);
          3: S.TryReadBufferedUntil('END', Data, 2);
        end;
      except on E: EArgumentException do Raised := True; end;
      AssertTrue(Raised);
      AssertEquals('data;', S.LineBuffer);
    end;
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.ChangingTerminatorRestartsSearch;
var S: TUntilMemorySerial; Data: RawByteString;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('first|second;');
    AssertFalse(S.TryReadBufferedUntil('END', Data));
    AssertTrue(S.TryReadBufferedUntil('|', Data));
    AssertEquals('first', Data);
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals('second', Data);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.ReplacingAndConsumingBytesRestartSearch;
var S: TUntilMemorySerial; Data: RawByteString; Raw: AnsiString;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.LineBuffer := 'xxxx';
    AssertFalse(S.TryReadBufferedUntil(';', Data));
    S.LineBuffer := 'new;';
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals('new', Data);
    S.AppendReadBuffer('old');
    AssertFalse(S.TryReadBufferedUntil(';', Data));
    AssertTrue(S.TryReadBuffered(False, Raw));
    S.AppendReadBuffer('a;');
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals('a', Data);
    S.AppendReadBuffer('line' + #13#10 + 'tail;');
    AssertTrue(S.BufferedDataAvailable(True));
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals('line' + #13#10 + 'tail', Data);
    AssertFalse(S.BufferedDataAvailable(True));
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.IncrementalReadsSurviveWrapAndGrowth;
var S: TUntilMemorySerial; Data: RawByteString; I: Integer;
begin
  S := TUntilMemorySerial.Create;
  try
    S.ConfigureReadBuffer(32768);
    S.AppendReadBuffer(StringOfChar('a', 4000) + '|tail');
    AssertTrue(S.TryReadBufferedUntil('|', Data));
    AssertEquals(4000, Length(Data));
    for I := 1 to 8192 do
    begin
      S.AppendReadBuffer('x');
      AssertFalse(S.TryReadBufferedUntil('END', Data, 16384));
    end;
    AssertEquals(0, S.PacketReads);
    S.AppendReadBuffer('EN');
    AssertFalse(S.TryReadBufferedUntil('END', Data, 16384));
    S.ConfigureReadBuffer(65536);
    S.AppendReadBuffer('D');
    AssertTrue(S.TryReadBufferedUntil('END', Data, 16384));
    AssertEquals('tail' + StringOfChar('x', 8192), Data);
  finally S.Free; end;
end;

procedure TLazSerialUntilParserTests.ExtractionUpdatesUsageWithoutCountingReceivedBytes;
var S: TUntilMemorySerial; Data: RawByteString; State: ISerialStatisticsState;
begin
  S := TUntilMemorySerial.Create;
  try
    State := CreateSerialStatistics;
    S.StatisticsState := State;
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('one;tail');
    AssertEquals(8, State.Snapshot.ReadBufferUsed);
    AssertTrue(S.TryReadBufferedUntil(';', Data));
    AssertEquals(4, State.Snapshot.ReadBufferUsed);
    AssertEquals(QWord(0), State.Snapshot.BytesReceived);
    AssertEquals(8, State.Snapshot.ReadBufferPeak);
  finally S.Free; end;
end;

initialization
  RegisterTest(TLazSerialUntilParserTests);

end.
