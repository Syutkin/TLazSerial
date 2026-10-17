unit LazSerialMemoryReadTests;
{$mode ObjFPC}{$H+}
interface
uses Classes, SysUtils, FpcUnit, TestRegistry, LazSynaSer;
type
  TLazSerialMemoryReadTests = class(TTestCase)
  published
    procedure EmptyAndPartialResultsNeverUseIO;
    procedure SplitLinesAndEmptyLinesPreserveOrder;
    procedure ConvertedEndsIgnoreComplementaryByte;
    procedure OverflowReportsOnceAndRecovers;
    procedure ReadinessDoesNotConsumeDiscardedLine;
    procedure BufferLimitRejectsWithoutLosingBytes;
    procedure SwitchingToPacketModeKeepsPartialBytes;
  end;
implementation
type
  TMemoryOnlySerial = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
  public
    function CanRead(Timeout: Integer): Boolean; override;
    function WaitingData: Integer; override;
    function RecvBuffer(Buffer: Pointer; ALength: Integer): Integer; override;
  end;
function TMemoryOnlySerial.PreTestFailing: Boolean;
begin raise Exception.Create('Memory read consulted native preflight'); end;
function TMemoryOnlySerial.CanRead(Timeout: Integer): Boolean;
begin raise Exception.Create('Memory read consulted native readiness'); end;
function TMemoryOnlySerial.WaitingData: Integer;
begin raise Exception.Create('Memory read consulted native queue'); end;
function TMemoryOnlySerial.RecvBuffer(Buffer: Pointer; ALength: Integer): Integer;
begin raise Exception.Create('Memory read performed native input'); end;

procedure TLazSerialMemoryReadTests.EmptyAndPartialResultsNeverUseIO;
var S: TMemoryOnlySerial; Data: AnsiString;
begin
  S := TMemoryOnlySerial.Create;
  try
    S.ConfigureReadBuffer(32);
    S.RaiseExcept := True;
    AssertFalse(S.BufferedDataAvailable(False));
    AssertFalse(S.TryReadBuffered(False, Data));
    AssertEquals('', Data);
    S.AppendReadBuffer('partial' + #13);
    AssertFalse(S.BufferedDataAvailable(True));
    AssertFalse(S.TryReadBuffered(True, Data));
    AssertEquals('partial' + #13, S.LineBuffer);
    AssertTrue(S.RaiseExcept);
  finally S.Free; end;
end;
procedure TLazSerialMemoryReadTests.SplitLinesAndEmptyLinesPreserveOrder;
var S: TMemoryOnlySerial; Data: AnsiString; I: Integer;
const Wire = 'ab' + #0 + #255 + #13#10 + #13#10 + 'tail';
begin
  for I := 1 to Length(Wire) do
  begin
    S := TMemoryOnlySerial.Create;
    try
      S.ConfigureReadBuffer(64);
      S.AppendReadBuffer(Copy(Wire, 1, I));
      if I < 6 then AssertFalse(S.TryReadBuffered(True, Data));
      S.AppendReadBuffer(Copy(Wire, I + 1, MaxInt));
      AssertTrue(S.TryReadBuffered(True, Data));
      AssertEquals('ab' + #0 + #255, Data);
      AssertTrue(S.TryReadBuffered(True, Data));
      AssertEquals('', Data);
      AssertFalse(S.TryReadBuffered(True, Data));
      AssertEquals('tail', S.LineBuffer);
    finally S.Free; end;
  end;
end;
procedure TLazSerialMemoryReadTests.ConvertedEndsIgnoreComplementaryByte;
var S: TMemoryOnlySerial; Data: AnsiString;
begin
  S := TMemoryOnlySerial.Create;
  try
    S.ConfigureReadBuffer(64);
    S.ConvertLineEnd := True;
    S.AppendReadBuffer('first' + #13);
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('first', Data);
    S.AppendReadBuffer(#10);
    AssertFalse(S.BufferedDataAvailable(True));
    AssertFalse(S.TryReadBuffered(True, Data));
    S.AppendReadBuffer('next' + #10);
    AssertTrue(S.BufferedDataAvailable(True));
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('next', Data);
  finally S.Free; end;
end;
procedure TLazSerialMemoryReadTests.OverflowReportsOnceAndRecovers;
var S: TMemoryOnlySerial; Data: AnsiString; Raised: Boolean; I: Integer;
begin
  S := TMemoryOnlySerial.Create;
  try
    S.ConfigureReadBuffer(32);
    S.MaxLineLength := 5;
    S.AppendReadBuffer('12345');
    AssertTrue(S.BufferedDataAvailable(True));
    Raised := False;
    try S.TryReadBuffered(True, Data);
    except on E: ESynaSerError do begin Raised := True; AssertEquals(ErrMaxBuffer, E.ErrorCode); end; end;
    AssertTrue(Raised);
    for I := 1 to 3 do
    begin
      S.AppendReadBuffer('12345');
      AssertFalse(S.BufferedDataAvailable(True));
      AssertFalse(S.TryReadBuffered(True, Data));
    end;
    S.AppendReadBuffer(#13#10 + 'ok' + #13#10);
    AssertTrue(S.BufferedDataAvailable(True));
    AssertTrue(S.TryReadBuffered(True, Data));
    AssertEquals('ok', Data);
  finally S.Free; end;
end;
procedure TLazSerialMemoryReadTests.ReadinessDoesNotConsumeDiscardedLine;
var S: TMemoryOnlySerial; Data, Before: AnsiString;
begin
  S := TMemoryOnlySerial.Create;
  try
    S.ConfigureReadBuffer(32);
    S.MaxLineLength := 5;
    S.AppendReadBuffer('12345');
    try S.TryReadBuffered(True, Data); except on E: ESynaSerError do ; end;
    S.AppendReadBuffer('tail' + #13#10);
    Before := S.LineBuffer;
    AssertFalse(S.BufferedDataAvailable(True));
    AssertFalse(S.BufferedDataAvailable(True));
    AssertEquals(Before, S.LineBuffer);
    AssertFalse(S.TryReadBuffered(True, Data));
    AssertEquals('', S.LineBuffer);
  finally S.Free; end;
end;
procedure TLazSerialMemoryReadTests.BufferLimitRejectsWithoutLosingBytes;
var S: TMemoryOnlySerial; Raised: Boolean;
begin
  S := TMemoryOnlySerial.Create;
  try
    S.ConfigureReadBuffer(4);
    S.AppendReadBuffer('abcd');
    Raised := False;
    try S.AppendReadBuffer('e'); except on E: ERangeError do Raised := True; end;
    AssertTrue(Raised);
    AssertEquals('abcd', S.LineBuffer);
    AssertEquals(4, S.WaitingDataEx);
  finally S.Free; end;
end;
procedure TLazSerialMemoryReadTests.SwitchingToPacketModeKeepsPartialBytes;
var S: TMemoryOnlySerial; Data: AnsiString;
begin
  S := TMemoryOnlySerial.Create;
  try
    S.ConfigureReadBuffer(32);
    S.AppendReadBuffer('partial' + #13);
    AssertFalse(S.TryReadBuffered(True, Data));
    AssertTrue(S.BufferedDataAvailable(False));
    AssertTrue(S.TryReadBuffered(False, Data));
    AssertEquals('partial' + #13, Data);
  finally S.Free; end;
end;
initialization RegisterTest(TLazSerialMemoryReadTests);
end.
