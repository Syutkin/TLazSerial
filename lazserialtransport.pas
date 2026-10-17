unit LazSerialTransport;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  LazSerialCommon, LazSynaSer, LazSerialWrite;

type
  TLazSerialTransport = class
  public
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeoutMs: Cardinal; const AOnFinished: TSerialWriteFinished):
      ISerialWriteOperation; virtual;
    procedure CompleteWrite(const AResult: TSerialWriteResult); virtual;
    procedure Close; virtual; abstract;
    procedure Configure(ABaudRate, ADataBits: Integer; AParity: Char;
      AStopBits: Integer; AFlowControl: TFlowControl); virtual; abstract;
    procedure Connect(const ADevice: string); virtual; abstract;
    function CanRead(const ATimeout: Integer): Boolean; virtual; abstract;
    function CanReadLine(const ATimeout: Integer): Boolean; virtual;
    function DeviceName: string; virtual; abstract;
    function IsOpen: Boolean; virtual; abstract;
    function NativeSerial: TBlockSerial; virtual; abstract;
    function ReadPacket(const ATimeout: Integer): AnsiString;
      virtual; abstract;
    function ReadString(const ATimeout: Integer): AnsiString;
      virtual; abstract;
    function SendBuffer(ABuffer: Pointer; ASize: Integer): Integer;
      virtual; abstract;
    function SendString(const AData: AnsiString): Integer; virtual; abstract;
    procedure SetDTR(const AEnabled: Boolean); virtual; abstract;
    procedure SetRTS(const AEnabled: Boolean); virtual; abstract;
    procedure SetStatusHandler(const AHandler: THookSerialStatus);
      virtual; abstract;
    function GetCarrier: Boolean; virtual; abstract;
    function GetCTS: Boolean; virtual; abstract;
    function GetDSR: Boolean; virtual; abstract;
    function GetRing: Boolean; virtual; abstract;
  end;

  TLazSynapseSerialTransport = class(TLazSerialTransport)
  private
    FSerial: TBlockSerial;
    FSerialOwner: ISerialWritePort;
    FConfigured: Boolean;
    FWriteError: Integer;
    FSkipDrain: Boolean;
    function RestoreConfiguration(const APrevious: TDCB): Boolean;
  protected
    function CreateSerial: TBlockSerial; virtual;
  public
    constructor Create;
    destructor Destroy; override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeoutMs: Cardinal; const AOnFinished: TSerialWriteFinished):
      ISerialWriteOperation; override;
    procedure CompleteWrite(const AResult: TSerialWriteResult); override;
    procedure Close; override;
    procedure Configure(ABaudRate, ADataBits: Integer; AParity: Char;
      AStopBits: Integer; AFlowControl: TFlowControl); override;
    procedure Connect(const ADevice: string); override;
    function CanRead(const ATimeout: Integer): Boolean; override;
    function CanReadLine(const ATimeout: Integer): Boolean; override;
    function DeviceName: string; override;
    function IsOpen: Boolean; override;
    function NativeSerial: TBlockSerial; override;
    function ReadPacket(const ATimeout: Integer): AnsiString; override;
    function ReadString(const ATimeout: Integer): AnsiString; override;
    function SendBuffer(ABuffer: Pointer; ASize: Integer): Integer; override;
    function SendString(const AData: AnsiString): Integer; override;
    procedure SetDTR(const AEnabled: Boolean); override;
    procedure SetRTS(const AEnabled: Boolean); override;
    procedure SetStatusHandler(const AHandler: THookSerialStatus); override;
    function GetCarrier: Boolean; override;
    function GetCTS: Boolean; override;
    function GetDSR: Boolean; override;
    function GetRing: Boolean; override;
  end;

implementation

uses
  Classes, SysUtils, LazSerialNativeWrite;

function TLazSerialTransport.CanReadLine(const ATimeout: Integer): Boolean;
begin
  Result := CanRead(ATimeout);
end;

function TLazSerialTransport.CreateWriteOperation(const AData: AnsiString;
  const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
begin
  Result := nil;
  raise EInvalidOperation.Create('Transport does not support asynchronous writes');
end;

procedure TLazSerialTransport.CompleteWrite(const AResult: TSerialWriteResult);
begin
end;

constructor TLazSynapseSerialTransport.Create;
begin
  inherited Create;
  FSerial := CreateSerial;
  FSerialOwner := TSerialWritePort.Create(FSerial);
  FSerial.LinuxLock := False;
end;

function TLazSynapseSerialTransport.CreateSerial: TBlockSerial;
begin
  Result := TBlockSerial.Create;
end;

destructor TLazSynapseSerialTransport.Destroy;
begin
  FSerial.OnStatus := nil;
  FSerialOwner := nil;
  inherited Destroy;
end;

function TLazSynapseSerialTransport.CreateWriteOperation(const AData: AnsiString;
  const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
begin
  Result := TNativeSerialWriteOperation.Create(FSerialOwner, AData, AId,
    ATimeoutMs, AOnFinished);
end;

procedure TLazSynapseSerialTransport.CompleteWrite(const AResult: TSerialWriteResult);
begin
  if AResult.Outcome <> swoCompleted then
  begin
    FSkipDrain := True;
    if FWriteError = 0 then
      FWriteError := AResult.ErrorCode;
  end;
end;

procedure TLazSynapseSerialTransport.Close;
var
  ErrorCode, PendingBytes, Timeout: Integer;
  RaiseNative: Boolean;
  Started: QWord;
begin
  FConfigured := False;
  if not IsOpen then
    Exit;
  RaiseNative := FSerial.RaiseExcept;
  FSerial.RaiseExcept := False;
  // Other transport calls can clear LastError after a write has failed.
  ErrorCode := FWriteError;
  try
    try
      if (ErrorCode = 0) and not FSkipDrain then
      begin
        Timeout := FSerial.DeadlockTimeout;
        Started := GetTickCount64;
        repeat
          PendingBytes := FSerial.SendingData;
          ErrorCode := FSerial.LastError;
          if (ErrorCode <> 0) or (PendingBytes = 0) then
            Break;
          if (Timeout <= 0) or (GetTickCount64 - Started >= QWord(Timeout)) then
          begin
            ErrorCode := ErrTimeout;
            Break;
          end;
          Sleep(1);
        until False;
      end;
    finally
      // Purge immediately after a failed write, or after the drain deadline.
      FSerial.CloseSocket;
    end;
  finally
    FWriteError := 0;
    FSkipDrain := False;
    FSerial.RaiseExcept := RaiseNative;
    if ErrorCode <> 0 then
      FSerial.SetSynaError(ErrorCode);
  end;
  FSerial.ExceptCheck;
end;

procedure TLazSynapseSerialTransport.Configure(ABaudRate,
  ADataBits: Integer; AParity: Char; AStopBits: Integer;
  AFlowControl: TFlowControl);
var
  ErrorCode: Integer;
  ErrorMessage: string;
  Error: ESynaSerError;
  Previous: TDCB;
begin
  Previous := FSerial.DCB;
  try
    FSerial.Config(ABaudRate, ADataBits, AParity, AStopBits, AFlowControl);
    ErrorCode := FSerial.LastError;
    if ErrorCode <> 0 then
    begin
      ErrorMessage := TBlockSerial.GetErrorDesc(ErrorCode);
      Error := ESynaSerError.CreateFmt('Could not configure device %s: %s',
        [FSerial.Device, ErrorMessage]);
      Error.ErrorCode := ErrorCode;
      Error.ErrorMessage := ErrorMessage;
      raise Error;
    end;
    FConfigured := True;
  except
    on E: ESynaSerError do
    begin
      try
        if FConfigured and not RestoreConfiguration(Previous) then
        begin
          FConfigured := False;
          try
            Close;
          except
            on CloseError: ESynaSerError do ;
          end;
        end
        else
          FSerial.DCB := Previous;
      finally
        FSerial.SetSynaError(E.ErrorCode);
      end;
      raise;
    end;
  end;
end;

function TLazSynapseSerialTransport.RestoreConfiguration(
  const APrevious: TDCB): Boolean;
begin
  FSerial.DCB := APrevious;
  try
    FSerial.SetCommState;
    Result := FSerial.LastError = 0;
  except
    on E: ESynaSerError do Result := False;
  end;
end;

procedure TLazSynapseSerialTransport.Connect(const ADevice: string);
begin
  FConfigured := False;
  if not IsOpen then
  begin
    FWriteError := 0;
    FSkipDrain := False;
  end;
  FSerial.Connect(ADevice);
end;

function TLazSynapseSerialTransport.CanRead(
  const ATimeout: Integer): Boolean;
begin
  Result := FSerial.CanReadEx(ATimeout);
end;

function TLazSynapseSerialTransport.CanReadLine(
  const ATimeout: Integer): Boolean;
begin
  Result := FSerial.CanReadLine(ATimeout);
end;

function TLazSynapseSerialTransport.DeviceName: string;
begin
  Result := FSerial.Device;
end;

function TLazSynapseSerialTransport.IsOpen: Boolean;
begin
  // FPC 3.2.4's SysUtils.INVALID_HANDLE_VALUE is unsigned on Unix.
  // Cast -1 to THandle to match Synaser's closed descriptor.
  Result := FSerial.Handle <> THandle(-1);
end;

function TLazSynapseSerialTransport.NativeSerial: TBlockSerial;
begin
  Result := FSerial;
end;

function TLazSynapseSerialTransport.ReadPacket(
  const ATimeout: Integer): AnsiString;
begin
  Result := FSerial.RecvPacket(ATimeout);
end;

function TLazSynapseSerialTransport.ReadString(
  const ATimeout: Integer): AnsiString;
begin
  Result := FSerial.RecvString(ATimeout);
end;

function TLazSynapseSerialTransport.SendBuffer(ABuffer: Pointer;
  ASize: Integer): Integer;
begin
  try
    Result := FSerial.SendBuffer(ABuffer, ASize);
  except
    on E: ESynaSerError do
    begin
      if FWriteError = 0 then
        FWriteError := E.ErrorCode;
      raise;
    end;
  end;
  if FWriteError = 0 then
    FWriteError := FSerial.LastError;
end;

function TLazSynapseSerialTransport.SendString(
  const AData: AnsiString): Integer;
begin
  Result := SendBuffer(Pointer(AData), Length(AData));
end;

procedure TLazSynapseSerialTransport.SetDTR(const AEnabled: Boolean);
begin
  FSerial.DTR := AEnabled;
end;

procedure TLazSynapseSerialTransport.SetRTS(const AEnabled: Boolean);
begin
  FSerial.RTS := AEnabled;
end;

procedure TLazSynapseSerialTransport.SetStatusHandler(
  const AHandler: THookSerialStatus);
begin
  FSerial.OnStatus := AHandler;
end;

function TLazSynapseSerialTransport.GetCarrier: Boolean;
begin
  Result := FSerial.Carrier;
end;

function TLazSynapseSerialTransport.GetCTS: Boolean;
begin
  Result := FSerial.CTS;
end;

function TLazSynapseSerialTransport.GetDSR: Boolean;
begin
  Result := FSerial.DSR;
end;

function TLazSynapseSerialTransport.GetRing: Boolean;
begin
  Result := FSerial.Ring;
end;

end.
