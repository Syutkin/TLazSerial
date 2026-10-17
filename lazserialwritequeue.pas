unit LazSerialWriteQueue;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, LazSerialCommon;

const
  DefaultWriteQueueByteLimit = 65536;
  DefaultWriteQueueItemLimit = 64;

type
  TSerialQueuedWrite = record
    OperationId: QWord;
    Data: AnsiString;
    TimeoutMs: Cardinal;
  end;

  // Main-thread FIFO and accounting only. Native I/O remains in LazSerialWrite.
  // Results keep their reservation until popped for delivery, bounding empty
  // writes and cancelled-result backlogs as well as payload storage.
  TSerialWriteQueue = class
  private
    FEnabled: Boolean;
    FByteLimit, FItemLimit: Integer;
    FBytes: SizeInt;
    FItems: array of record
      Request: TSerialQueuedWrite;
      State: (qwsWaiting, qwsActive, qwsResult);
      Result: TSerialWriteResult;
    end;
    function GetCount: Integer;
    function GetActiveId: QWord;
    procedure CheckIdle;
    procedure SetEnabled(AValue: Boolean);
    procedure SetByteLimit(AValue: Integer);
    procedure SetItemLimit(AValue: Integer);
  public
    constructor Create;
    procedure Push(AId: QWord; const AData: AnsiString; ATimeoutMs: Cardinal);
    // Undo admission if scheduling fails before an ID can be returned.
    procedure RollbackPush(AId: QWord);
    function BeginNext(out ARequest: TSerialQueuedWrite): Boolean;
    procedure Complete(const AResult: TSerialWriteResult);
    function PopResult(out AResult: TSerialWriteResult): Boolean;
    procedure CancelWaiting;
    procedure Clear;
    property Enabled: Boolean read FEnabled write SetEnabled;
    property ByteLimit: Integer read FByteLimit write SetByteLimit;
    property ItemLimit: Integer read FItemLimit write SetItemLimit;
    property Count: Integer read GetCount;
    property Bytes: SizeInt read FBytes;
    property ActiveId: QWord read GetActiveId;
  end;

implementation

constructor TSerialWriteQueue.Create;
begin
  inherited Create;
  FByteLimit := DefaultWriteQueueByteLimit;
  FItemLimit := DefaultWriteQueueItemLimit;
end;

function TSerialWriteQueue.GetCount: Integer;
begin Result := Length(FItems); end;

function TSerialWriteQueue.GetActiveId: QWord;
begin
  Result := 0;
  if (Count > 0) and (FItems[0].State = qwsActive) then
    Result := FItems[0].Request.OperationId;
end;

procedure TSerialWriteQueue.CheckIdle;
begin
  if Count > 0 then
    raise EInvalidOperation.Create('Write queue settings require no pending writes');
end;

procedure TSerialWriteQueue.SetEnabled(AValue: Boolean);
begin
  if FEnabled = AValue then Exit;
  CheckIdle;
  FEnabled := AValue;
end;
procedure TSerialWriteQueue.SetByteLimit(AValue: Integer);
begin
  CheckIdle;
  if AValue <= 0 then raise EArgumentException.Create('Write queue byte limit must be positive');
  FByteLimit := AValue;
end;
procedure TSerialWriteQueue.SetItemLimit(AValue: Integer);
begin
  CheckIdle;
  if AValue <= 0 then raise EArgumentException.Create('Write queue item limit must be positive');
  FItemLimit := AValue;
end;

procedure TSerialWriteQueue.Push(AId: QWord; const AData: AnsiString; ATimeoutMs: Cardinal);
var Request: TSerialQueuedWrite; Index: Integer;
begin
  if not FEnabled then raise EInvalidOperation.Create('Write queue is not enabled');
  if AId = 0 then raise EArgumentException.Create('Write operation ID must be nonzero');
  if ATimeoutMs = 0 then raise EArgumentException.Create('Write timeout must be greater than zero');
  if Count >= FItemLimit then raise EInvalidOperation.Create('Write queue item limit exceeded');
  if Length(AData) > FByteLimit - FBytes then
    raise EInvalidOperation.Create('Write queue byte limit exceeded');
  Request.OperationId := AId;
  Request.Data := Copy(AData, 1, Length(AData));
  Request.TimeoutMs := ATimeoutMs;
  Index := Count;
  SetLength(FItems, Index + 1);
  FItems[Index].Request := Request;
  FItems[Index].State := qwsWaiting;
  FItems[Index].Result := Default(TSerialWriteResult);
  FItems[Index].Result.OperationId := AId;
  FItems[Index].Result.BytesRequested := Length(AData);
  Inc(FBytes, Length(AData));
end;

procedure TSerialWriteQueue.RollbackPush(AId: QWord);
var Index: Integer;
begin
  Index := Count - 1;
  if (Index < 0) or (FItems[Index].Request.OperationId <> AId) or
    (FItems[Index].State <> qwsWaiting) then
    raise EInvalidOperation.Create('Cannot roll back a started or non-tail queue entry');
  Dec(FBytes, FItems[Index].Result.BytesRequested);
  SetLength(FItems, Index);
end;

function TSerialWriteQueue.BeginNext(out ARequest: TSerialQueuedWrite): Boolean;
begin
  ARequest := Default(TSerialQueuedWrite);
  Result := (Count > 0) and (FItems[0].State = qwsWaiting);
  if not Result then Exit;
  ARequest := FItems[0].Request;
  FItems[0].State := qwsActive;
  FItems[0].Request.Data := '';
end;

procedure TSerialWriteQueue.Complete(const AResult: TSerialWriteResult);
var Requested: Integer;
begin
  if (AResult.OperationId = 0) or (ActiveId <> AResult.OperationId) then
    raise EInvalidOperation.Create('Write result does not match the active queue entry');
  Requested := FItems[0].Result.BytesRequested;
  FItems[0].Result := AResult;
  FItems[0].Result.BytesRequested := Requested;
  FItems[0].State := qwsResult;
  if AResult.Outcome <> swoCompleted then CancelWaiting;
end;

function TSerialWriteQueue.PopResult(out AResult: TSerialWriteResult): Boolean;
var I: Integer;
begin
  AResult := Default(TSerialWriteResult);
  Result := (Count > 0) and (FItems[0].State = qwsResult);
  if not Result then Exit;
  AResult := FItems[0].Result;
  Dec(FBytes, AResult.BytesRequested);
  for I := 1 to High(FItems) do FItems[I - 1] := FItems[I];
  SetLength(FItems, Count - 1);
end;

procedure TSerialWriteQueue.CancelWaiting;
var I: Integer;
begin
  for I := 0 to High(FItems) do
    if FItems[I].State = qwsWaiting then
    begin
      FItems[I].Request.Data := '';
      FItems[I].Result.Outcome := swoCancelled;
      FItems[I].State := qwsResult;
    end;
end;

procedure TSerialWriteQueue.Clear;
begin
  FItems := nil;
  FBytes := 0;
end;

end.
