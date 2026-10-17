unit LazSerialStatistics;

{$mode ObjFPC}{$H+}

interface

type
  TSerialCloseReason = (scrNone, scrUserRequest, scrDeviceRemoved,
    scrReadError, scrConfigurationError, scrDestroyed);

  TSerialStatistics = record
    BytesReceived, BytesSent: QWord;
    ReadBufferUsed, ReadBufferPeak: SizeInt;
    ErrorCount: QWord;
    LastErrorCode: Integer;
    LastErrorMessage: string;
    CloseReason: TSerialCloseReason;
  end;

  { Internal session state shared by the port and its retained operations.
    Snapshot copies memory under a short lock; no method performs I/O. }
  ISerialStatisticsState = interface
    function Snapshot: TSerialStatistics;
    procedure AddReceived(ACount: SizeInt);
    procedure AddSent(ACount: SizeInt);
    procedure UpdateReadBuffer(AUsed: SizeInt);
    procedure RecordError(ACode: Integer; const AMessage: string);
    procedure MarkClosed(AReason: TSerialCloseReason);
  end;

function CreateSerialStatistics: ISerialStatisticsState;

implementation

uses Classes, SyncObjs;

type
  TSerialStatisticsState = class(TInterfacedObject, ISerialStatisticsState)
  private
    FLock: TCriticalSection;
    FValue: TSerialStatistics;
  public
    constructor Create;
    destructor Destroy; override;
    function Snapshot: TSerialStatistics;
    procedure AddReceived(ACount: SizeInt);
    procedure AddSent(ACount: SizeInt);
    procedure UpdateReadBuffer(AUsed: SizeInt);
    procedure RecordError(ACode: Integer; const AMessage: string);
    procedure MarkClosed(AReason: TSerialCloseReason);
  end;

function CreateSerialStatistics: ISerialStatisticsState;
begin
  Result := TSerialStatisticsState.Create;
end;

constructor TSerialStatisticsState.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TSerialStatisticsState.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TSerialStatisticsState.Snapshot: TSerialStatistics;
begin
  FLock.Acquire;
  try Result := FValue;
  finally FLock.Release; end;
end;

procedure TSerialStatisticsState.AddReceived(ACount: SizeInt);
begin
  if ACount <= 0 then Exit;
  FLock.Acquire;
  try Inc(FValue.BytesReceived, QWord(ACount));
  finally FLock.Release; end;
end;

procedure TSerialStatisticsState.AddSent(ACount: SizeInt);
begin
  if ACount <= 0 then Exit;
  FLock.Acquire;
  try Inc(FValue.BytesSent, QWord(ACount));
  finally FLock.Release; end;
end;

procedure TSerialStatisticsState.UpdateReadBuffer(AUsed: SizeInt);
begin
  FLock.Acquire;
  try
    FValue.ReadBufferUsed := AUsed;
    if AUsed > FValue.ReadBufferPeak then FValue.ReadBufferPeak := AUsed;
  finally FLock.Release; end;
end;

procedure TSerialStatisticsState.RecordError(ACode: Integer; const AMessage: string);
begin
  FLock.Acquire;
  try
    Inc(FValue.ErrorCount);
    FValue.LastErrorCode := ACode;
    FValue.LastErrorMessage := AMessage;
  finally FLock.Release; end;
end;

procedure TSerialStatisticsState.MarkClosed(AReason: TSerialCloseReason);
begin
  FLock.Acquire;
  try
    if FValue.CloseReason = scrNone then FValue.CloseReason := AReason;
  finally FLock.Release; end;
end;

end.
