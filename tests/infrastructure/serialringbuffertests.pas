unit SerialRingBufferTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, SerialRingBuffer, LazSynaSer;

type
  TSerialRingBufferTests = class(TTestCase)
  published
    procedure AppendAcrossWrapPreservesBinaryBytes;
    procedure PrependAcrossWrapPreservesUnreadSuffix;
    procedure GrowthPreservesWrappedData;
    procedure FindMatchesAcrossPhysicalBoundary;
    procedure OverflowLeavesTheBufferUnchanged;
    procedure ClearAndAssignReuseStorage;
    procedure InvalidCountsDoNotConsumeData;
    procedure MixedOperationsMatchAByteStream;
    procedure SynaserPreservesLineBufferAndProtectedAccess;
  end;

implementation

type
  TBufferedSerialProbe = class(TBlockSerial)
  protected
    function PreTestFailing: Boolean; override;
  public
    procedure AssignProtectedBuffer(const AData: AnsiString);
    function ProtectedBuffer: AnsiString;
  end;

function TBufferedSerialProbe.PreTestFailing: Boolean;
begin
  Result := False;
end;

procedure TBufferedSerialProbe.AssignProtectedBuffer(const AData: AnsiString);
begin
  FBuffer := AData;
end;

function TBufferedSerialProbe.ProtectedBuffer: AnsiString;
begin
  Result := FBuffer;
end;

procedure TSerialRingBufferTests.AppendAcrossWrapPreservesBinaryBytes;
var
  Buffer: TSerialRingBuffer;
begin
  Buffer := TSerialRingBuffer.Create(8, 8);
  try
    Buffer.Append('abcdef');
    AssertEquals('abcde', Buffer.Read(5));
    Buffer.Append(#0 + #255 + '12345');
    AssertEquals(8, Buffer.Count);
    AssertEquals('f' + #0 + #255 + '12345', Buffer.Read(99));
    AssertEquals(0, Buffer.Count);
    AssertEquals('', Buffer.Read(1));
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.PrependAcrossWrapPreservesUnreadSuffix;
var
  Buffer: TSerialRingBuffer;
begin
  Buffer := TSerialRingBuffer.Create(8, 8);
  try
    Buffer.Append('abcdef');
    Buffer.Discard(4);
    Buffer.Prepend('123456');
    AssertEquals('123456ef', Buffer.Snapshot);
    AssertEquals('123', Buffer.Read(3));
    Buffer.Prepend('XYZ');
    AssertEquals('XYZ456ef', Buffer.Read(8));
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.GrowthPreservesWrappedData;
var
  Buffer: TSerialRingBuffer;
begin
  Buffer := TSerialRingBuffer.Create(4);
  try
    Buffer.Append('abcd');
    Buffer.Discard(3);
    Buffer.Append('efg');
    Buffer.Append('hijklmnop');
    AssertTrue(Buffer.Capacity >= 13);
    AssertEquals('defghijklmnop', Buffer.Snapshot);
    Buffer.Prepend('abc');
    AssertEquals('abcdefghijklmnop', Buffer.Read(99));
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.FindMatchesAcrossPhysicalBoundary;
var
  Buffer: TSerialRingBuffer;
begin
  Buffer := TSerialRingBuffer.Create(8, 8);
  try
    Buffer.Append('1234567' + #13);
    Buffer.Discard(7);
    Buffer.Append(#10 + 'ab' + #0 + 'ab');
    AssertEquals(0, Buffer.Find(#13#10));
    AssertEquals(2, Buffer.Find('ab'));
    AssertEquals(5, Buffer.Find('ab', 3));
    AssertEquals(4, Buffer.Find(#0));
    AssertEquals(-1, Buffer.Find('missing'));
    AssertEquals(-1, Buffer.Find(''));
    AssertEquals(7, Buffer.Count);
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.OverflowLeavesTheBufferUnchanged;
var
  Buffer: TSerialRingBuffer;
  I: Integer;
  Raised: Boolean;
begin
  Buffer := TSerialRingBuffer.Create(0, 4);
  try
    Buffer.Append('abc');
    for I := 0 to 2 do
    begin
      Raised := False;
      try
        case I of
          0: Buffer.Append('de');
          1: Buffer.Prepend('de');
          2: Buffer.Assign('abcde');
        end;
      except
        on E: ERangeError do Raised := True;
      end;
      AssertTrue(Raised);
      AssertEquals('abc', Buffer.Snapshot);
      AssertTrue(Buffer.Capacity <= 4);
    end;
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.ClearAndAssignReuseStorage;
var
  Buffer: TSerialRingBuffer;
  Capacity: SizeInt;
begin
  Buffer := TSerialRingBuffer.Create(0);
  try
    Buffer.Discard(0);
    Buffer.Append('abc');
    Capacity := Buffer.Capacity;
    Buffer.Clear;
    AssertEquals(0, Buffer.Count);
    AssertEquals(Capacity, Buffer.Capacity);
    Buffer.Assign(#0 + #255);
    AssertEquals(#0 + #255, Buffer.Snapshot);
    Buffer.Assign('');
    AssertEquals(0, Buffer.Count);
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.InvalidCountsDoNotConsumeData;
var
  Buffer: TSerialRingBuffer;
  Raised: Boolean;
  I: Integer;
begin
  Buffer := TSerialRingBuffer.Create;
  try
    Buffer.Append('abc');
    for I := 0 to 4 do
    begin
      Raised := False;
      try
        case I of
          0: Buffer.Read(-1);
          1: Buffer.Discard(4);
          2: Buffer.PeekByte(3);
          3: Buffer.Find('a', -1);
          4: Buffer.Find('a', 4);
        end;
      except
        on E: EArgumentException do Raised := True;
      end;
      AssertTrue(Raised);
      AssertEquals('abc', Buffer.Snapshot);
    end;
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.MixedOperationsMatchAByteStream;
var
  Buffer: TSerialRingBuffer;
  Model, Piece: AnsiString;
  Seed: QWord;
  I, N: Integer;
begin
  Buffer := TSerialRingBuffer.Create(1);
  try
    Model := '';
    Seed := 12345;
    for I := 1 to 2000 do
    begin
      Seed := (Seed * 1664525 + 1013904223) and $FFFFFFFF;
      N := Seed mod 17;
      Piece := StringOfChar(AnsiChar(Seed mod 256), N);
      case (Seed shr 8) mod 4 of
        0:
          begin
            Buffer.Append(Piece);
            Model := Model + Piece;
          end;
        1:
          begin
            Buffer.Prepend(Piece);
            Model := Piece + Model;
          end;
        2, 3:
          begin
            AssertEquals(Copy(Model, 1, N), Buffer.Read(N));
            Delete(Model, 1, N);
          end;
      end;
      AssertEquals(Length(Model), Buffer.Count);
      AssertEquals(Model, Buffer.Snapshot);
    end;
  finally
    Buffer.Free;
  end;
end;

procedure TSerialRingBufferTests.SynaserPreservesLineBufferAndProtectedAccess;
var
  Serial: TBufferedSerialProbe;
  Snapshot: AnsiString;
begin
  Serial := TBufferedSerialProbe.Create;
  try
    Serial.AssignProtectedBuffer('A' + #0 + 'B' + #13#10);
    AssertEquals('A' + #0 + 'B' + #13#10, Serial.LineBuffer);
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals(Ord('A'), Serial.RecvByte(0));
    Snapshot := Serial.LineBuffer;
    Snapshot[1] := 'X';
    AssertEquals(#0 + 'B' + #13#10, Serial.ProtectedBuffer);
    AssertEquals(#0 + 'B', Serial.RecvString(0));
    Serial.LineBuffer := 'tail';
    AssertEquals('tail', Serial.RecvPacket(0));
    AssertEquals('', Serial.ProtectedBuffer);
  finally
    Serial.Free;
  end;
end;

initialization
  RegisterTest(TSerialRingBufferTests);

end.
