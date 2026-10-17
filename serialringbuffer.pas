unit SerialRingBuffer;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

type
  { Byte storage only. The caller serializes access when sharing a buffer
    between threads. Zero MaxCapacity means grow on demand without a limit. }
  TSerialRingBuffer = class
  private
    FData: array of Byte;
    FHead, FCount, FMaxCapacity: SizeInt;
    function GetCapacity: SizeInt;
    function PhysicalIndex(AOffset: SizeInt): SizeInt;
    procedure EnsureCapacity(ARequired: SizeInt);
    procedure CopyOut(ADestination: Pointer; ACount: SizeInt);
    procedure CopyIn(const AData: AnsiString; AIndex: SizeInt);
  public
    constructor Create(AInitialCapacity: SizeInt = 4096;
      AMaxCapacity: SizeInt = 0);
    procedure Clear;
    procedure Assign(const AData: AnsiString);
    procedure Append(const AData: AnsiString);
    procedure Prepend(const AData: AnsiString);
    procedure Discard(ACount: SizeInt);
    function PeekByte(AIndex: SizeInt): Byte;
    // Peek and Read return up to ACount bytes; negative counts are invalid.
    function Peek(ACount: SizeInt): AnsiString;
    function Read(ACount: SizeInt): AnsiString;
    function Snapshot: AnsiString;
    // Zero-based offset; -1 for an absent or empty pattern.
    function Find(const APattern: AnsiString; AStart: SizeInt = 0): SizeInt;
    property Count: SizeInt read FCount;
    property Capacity: SizeInt read GetCapacity;
    property MaxCapacity: SizeInt read FMaxCapacity;
  end;

implementation

constructor TSerialRingBuffer.Create(AInitialCapacity, AMaxCapacity: SizeInt);
begin
  inherited Create;
  if (AInitialCapacity < 0) or (AMaxCapacity < 0) or
    ((AMaxCapacity > 0) and (AInitialCapacity > AMaxCapacity)) then
    raise EArgumentException.Create('Invalid ring buffer capacity');
  FMaxCapacity := AMaxCapacity;
  SetLength(FData, AInitialCapacity);
end;

function TSerialRingBuffer.GetCapacity: SizeInt;
begin
  Result := Length(FData);
end;

function TSerialRingBuffer.PhysicalIndex(AOffset: SizeInt): SizeInt;
begin
  if AOffset >= Capacity - FHead then
    Result := AOffset - (Capacity - FHead)
  else
    Result := FHead + AOffset;
end;

procedure TSerialRingBuffer.CopyOut(ADestination: Pointer; ACount: SizeInt);
var
  First: SizeInt;
begin
  if ACount = 0 then
    Exit;
  First := Capacity - FHead;
  if First > ACount then
    First := ACount;
  Move(FData[FHead], ADestination^, First);
  if First < ACount then
    Move(FData[0], (PByte(ADestination) + First)^, ACount - First);
end;

procedure TSerialRingBuffer.EnsureCapacity(ARequired: SizeInt);
var
  NewCapacity: SizeInt;
  NewData: array of Byte;
begin
  if (ARequired < 0) or ((FMaxCapacity > 0) and (ARequired > FMaxCapacity)) then
    raise ERangeError.Create('Ring buffer capacity exceeded');
  if ARequired <= Capacity then
    Exit;
  NewCapacity := Capacity;
  if NewCapacity = 0 then
    NewCapacity := 16;
  while NewCapacity < ARequired do
    if NewCapacity > High(SizeInt) div 2 then
      NewCapacity := ARequired
    else
      NewCapacity := NewCapacity * 2;
  if (FMaxCapacity > 0) and (NewCapacity > FMaxCapacity) then
    NewCapacity := FMaxCapacity;
  SetLength(NewData, NewCapacity);
  CopyOut(@NewData[0], FCount);
  FData := NewData;
  FHead := 0;
end;

procedure TSerialRingBuffer.CopyIn(const AData: AnsiString; AIndex: SizeInt);
var
  First: SizeInt;
begin
  if AData = '' then
    Exit;
  First := Capacity - AIndex;
  if First > Length(AData) then
    First := Length(AData);
  Move(AData[1], FData[AIndex], First);
  if First < Length(AData) then
    Move(AData[First + 1], FData[0], Length(AData) - First);
end;

procedure TSerialRingBuffer.Clear;
begin
  FHead := 0;
  FCount := 0;
end;

procedure TSerialRingBuffer.Assign(const AData: AnsiString);
begin
  EnsureCapacity(Length(AData));
  FHead := 0;
  CopyIn(AData, 0);
  FCount := Length(AData);
end;

procedure TSerialRingBuffer.Append(const AData: AnsiString);
begin
  if AData = '' then
    Exit;
  if Length(AData) > High(SizeInt) - FCount then
    raise ERangeError.Create('Ring buffer size overflow');
  EnsureCapacity(FCount + Length(AData));
  CopyIn(AData, PhysicalIndex(FCount));
  Inc(FCount, Length(AData));
end;

procedure TSerialRingBuffer.Prepend(const AData: AnsiString);
begin
  if AData = '' then
    Exit;
  if Length(AData) > High(SizeInt) - FCount then
    raise ERangeError.Create('Ring buffer size overflow');
  EnsureCapacity(FCount + Length(AData));
  if Length(AData) <= FHead then
    Dec(FHead, Length(AData))
  else
    FHead := Capacity - (Length(AData) - FHead);
  CopyIn(AData, FHead);
  Inc(FCount, Length(AData));
end;

procedure TSerialRingBuffer.Discard(ACount: SizeInt);
begin
  if (ACount < 0) or (ACount > FCount) then
    raise EArgumentException.Create('Invalid ring buffer read count');
  FHead := PhysicalIndex(ACount);
  Dec(FCount, ACount);
  if FCount = 0 then
    FHead := 0;
end;

function TSerialRingBuffer.PeekByte(AIndex: SizeInt): Byte;
begin
  if (AIndex < 0) or (AIndex >= FCount) then
    raise EArgumentException.Create('Invalid ring buffer index');
  Result := FData[PhysicalIndex(AIndex)];
end;

function TSerialRingBuffer.Peek(ACount: SizeInt): AnsiString;
begin
  if ACount < 0 then
    raise EArgumentException.Create('Invalid ring buffer read count');
  if ACount > FCount then
    ACount := FCount;
  SetLength(Result, ACount);
  CopyOut(Pointer(Result), ACount);
end;

function TSerialRingBuffer.Read(ACount: SizeInt): AnsiString;
begin
  Result := Peek(ACount);
  Discard(Length(Result));
end;

function TSerialRingBuffer.Snapshot: AnsiString;
begin
  Result := Peek(FCount);
end;

function TSerialRingBuffer.Find(const APattern: AnsiString; AStart: SizeInt): SizeInt;
var
  I, J: SizeInt;
begin
  if (AStart < 0) or (AStart > FCount) then
    raise EArgumentException.Create('Invalid ring buffer search offset');
  Result := -1;
  if APattern = '' then
    Exit;
  for I := AStart to FCount - Length(APattern) do
  begin
    J := 1;
    while (J <= Length(APattern)) and
      (PeekByte(I + J - 1) = Byte(APattern[J])) do
      Inc(J);
    if J > Length(APattern) then
      Exit(I);
  end;
end;

end.
