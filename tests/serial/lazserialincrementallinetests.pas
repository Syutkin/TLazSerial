unit LazSerialIncrementalLineTests;

{$mode ObjFPC}{$H+}

interface

uses SysUtils, FpcUnit, TestRegistry, LazSynaSer;

type
  TLazSerialIncrementalLineTests = class(TTestCase)
  published
    procedure PartialReadsLeaveBytesInRing;
    procedure ReplacementAtSameLengthRestartsSearch;
    procedure PacketAndByteReadsRestartSearch;
    procedure GenericDelimiterReadRestartsSearch;
    procedure ChangedSettingsRestartSearch;
    procedure ConvertedComplementIsConsumedOnPartialRead;
    procedure ScanSurvivesRingWrapGrowthAndReconfiguration;
    procedure DiscardedLineCanEndAcrossAppends;
  end;

implementation

type
  TCountingSerial = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
  public
    PacketReads: Integer;
    function RecvPacket(Timeout: Integer): AnsiString; override;
    function RecvBuffer(Buffer: Pointer; ALength: Integer): Integer; override;
    function CanRead(Timeout: Integer): Boolean; override;
    function WaitingData: Integer; override;
  end;

function TCountingSerial.PreTestFailing: Boolean;
begin
  Result := False;
end;

function TCountingSerial.RecvPacket(Timeout: Integer): AnsiString;
begin
  Inc(PacketReads);
  Result := inherited RecvPacket(Timeout);
end;

function TCountingSerial.RecvBuffer(Buffer: Pointer; ALength: Integer): Integer;
begin
  raise Exception.Create('Unexpected native input');
end;

function TCountingSerial.CanRead(Timeout: Integer): Boolean;
begin
  raise Exception.Create('Unexpected native readiness');
end;

function TCountingSerial.WaitingData: Integer;
begin
  raise Exception.Create('Unexpected native queue query');
end;

procedure TLazSerialIncrementalLineTests.PartialReadsLeaveBytesInRing;
var
  S: TCountingSerial;
  Data: AnsiString;
  I: Integer;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(16384);
    for I := 1 to 8192 do
    begin
      S.AppendReadBuffer('x');
      AssertFalse(S.BufferedDataAvailable(True));
      AssertFalse(S.TryReadBuffered(True, Data));
      AssertEquals('', Data);
      AssertEquals(ErrTimeout, S.LastError);
    end;
    // A partial read must not drain and reinsert the growing prefix.
    AssertEquals(0, S.PacketReads);
    AssertEquals(StringOfChar('x', 8192), S.LineBuffer);
    S.AppendReadBuffer(#13);
    AssertFalse(S.TryReadBuffered(True, Data));
    AssertEquals(0, S.PacketReads);
    S.AppendReadBuffer(#10);
    AssertTrue(S.BufferedDataAvailable(True));
    AssertTrue(S.BufferedDataAvailable(True));
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals(StringOfChar('x', 8192), Data);
    AssertFalse(S.BufferedDataAvailable(True));
  finally
    S.Free;
  end;
end;

procedure TLazSerialIncrementalLineTests.ReplacementAtSameLengthRestartsSearch;
var S: TCountingSerial; Data: AnsiString;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('abcd');
    AssertFalse(S.BufferedDataAvailable(True));
    S.LineBuffer := 'ab' + #13#10;
    AssertTrue(S.BufferedDataAvailable(True));
    S.LineBuffer := 'wxyz';
    AssertFalse(S.BufferedDataAvailable(True));
    S.AppendReadBuffer(#13#10);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('wxyz', Data);
  finally S.Free; end;
end;

procedure TLazSerialIncrementalLineTests.PacketAndByteReadsRestartSearch;
var S: TCountingSerial; Data: AnsiString;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('old' + #13);
    AssertFalse(S.BufferedDataAvailable(True));
    AssertEquals('old' + #13, S.RecvPacket(0));
    S.AppendReadBuffer(#10 + 'new' + #13#10);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals(#10 + 'new', Data);
    S.AppendReadBuffer(#13);
    AssertFalse(S.BufferedDataAvailable(True));
    AssertEquals(13, S.RecvByte(0));
    S.AppendReadBuffer(#10 + 'last');
    AssertFalse(S.BufferedDataAvailable(True));
    S.AppendReadBuffer(#13#10);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals(#10 + 'last', Data);
  finally S.Free; end;
end;

procedure TLazSerialIncrementalLineTests.GenericDelimiterReadRestartsSearch;
var S: TCountingSerial; Data: AnsiString;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('old|new' + #13);
    AssertFalse(S.BufferedDataAvailable(True));
    AssertEquals('old', S.RecvTerminated(0, '|'));
    S.AppendReadBuffer(#10);
    AssertTrue(S.BufferedDataAvailable(True));
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('new', Data);
  finally S.Free; end;
end;

procedure TLazSerialIncrementalLineTests.ChangedSettingsRestartSearch;
var S: TCountingSerial; Data: AnsiString;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer('abc' + #10);
    AssertFalse(S.BufferedDataAvailable(True));
    S.ConvertLineEnd := True;
    AssertTrue(S.BufferedDataAvailable(True));
    S.ConvertLineEnd := False;
    AssertFalse(S.BufferedDataAvailable(True));
    S.MaxLineLength := 4;
    AssertTrue(S.BufferedDataAvailable(True));
    S.MaxLineLength := 8;
    AssertFalse(S.BufferedDataAvailable(True));
    S.AppendReadBuffer(#13#10);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('abc' + #10, Data);
  finally S.Free; end;
end;

procedure TLazSerialIncrementalLineTests.ConvertedComplementIsConsumedOnPartialRead;
var S: TCountingSerial; Data: AnsiString;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.ConvertLineEnd := True;
    S.AppendReadBuffer('one' + #13);
    AssertTrue(S.TryReadBuffered(True, Data));
    S.AppendReadBuffer(#10 + 'partial');
    AssertFalse(S.BufferedDataAvailable(True));
    AssertFalse(S.TryReadBuffered(True, Data));
    AssertEquals('partial', S.LineBuffer);
    S.AppendReadBuffer(#13);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('partial', Data);
    S.AppendReadBuffer('last');
    AssertFalse(S.TryReadBuffered(True, Data));
    S.AppendReadBuffer(#10);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('last', Data);
  finally S.Free; end;
end;

procedure TLazSerialIncrementalLineTests.ScanSurvivesRingWrapGrowthAndReconfiguration;
var S: TCountingSerial; Data: AnsiString; Bytes: array[0..2] of Byte;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.AppendReadBuffer(StringOfChar('w', 40) + #13#10 + 'ab');
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertFalse(S.BufferedDataAvailable(True));
    // The short tail was prepended at the physical end of the ring.
    S.AppendReadBuffer('cd' + #13);
    AssertFalse(S.BufferedDataAvailable(True));
    S.AppendReadBuffer(#10);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('abcd', Data);
    S.ConfigureReadBuffer(16384);
    S.AppendReadBuffer('skip' + StringOfChar('x', 4000));
    AssertFalse(S.BufferedDataAvailable(True));
    AssertEquals(3, S.RecvBufferEx(@Bytes[0], 3, 0));
    AssertEquals(Ord('p'), S.RecvByte(0));
    AssertFalse(S.BufferedDataAvailable(True));
    S.AppendReadBuffer(StringOfChar('y', 4000) + #13);
    AssertFalse(S.BufferedDataAvailable(True));
    S.ConfigureReadBuffer(32768);
    S.AppendReadBuffer(#10);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals(StringOfChar('x', 4000) + StringOfChar('y', 4000), Data);
  finally S.Free; end;
end;

procedure TLazSerialIncrementalLineTests.DiscardedLineCanEndAcrossAppends;
var S: TCountingSerial; Data: AnsiString; Raised: Boolean;
begin
  S := TCountingSerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.MaxLineLength := 5;
    S.AppendReadBuffer('12345');
    Raised := False;
    try S.TryReadBuffered(True, Data);
    except on E: ESynaSerError do
      begin Raised := True; AssertEquals(ErrMaxBuffer, E.ErrorCode); end;
    end;
    AssertTrue(Raised);
    S.AppendReadBuffer('tail' + #13);
    AssertFalse(S.BufferedDataAvailable(True));
    S.AppendReadBuffer(#10 + 'ok' + #13);
    AssertFalse(S.BufferedDataAvailable(True));
    S.AppendReadBuffer(#10);
    AssertTrue(S.BufferedDataAvailable(True));
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('ok', Data);
  finally S.Free; end;
end;

initialization
  RegisterTest(TLazSerialIncrementalLineTests);
end.
