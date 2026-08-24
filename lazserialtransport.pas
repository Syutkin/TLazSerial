unit LazSerialTransport;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  LazSerialCommon, LazSynaSer;

type
  TLazSerialTransport = class
  public
    procedure Close; virtual; abstract;
    procedure Configure(ABaudRate, ADataBits: Integer; AParity: Char;
      AStopBits: Integer; AFlowControl: TFlowControl); virtual; abstract;
    procedure Connect(const ADevice: string); virtual; abstract;
    function CanRead(const ATimeout: Integer): Boolean; virtual; abstract;
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
  public
    constructor Create;
    destructor Destroy; override;
    procedure Close; override;
    procedure Configure(ABaudRate, ADataBits: Integer; AParity: Char;
      AStopBits: Integer; AFlowControl: TFlowControl); override;
    procedure Connect(const ADevice: string); override;
    function CanRead(const ATimeout: Integer): Boolean; override;
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

constructor TLazSynapseSerialTransport.Create;
begin
  inherited Create;
  FSerial := TBlockSerial.Create;
  FSerial.LinuxLock := False;
end;

destructor TLazSynapseSerialTransport.Destroy;
begin
  FSerial.OnStatus := nil;
  FSerial.Free;
  inherited Destroy;
end;

procedure TLazSynapseSerialTransport.Close;
begin
  if not IsOpen then
    Exit;
  FSerial.Flush;
  FSerial.Purge;
  FSerial.CloseSocket;
end;

procedure TLazSynapseSerialTransport.Configure(ABaudRate,
  ADataBits: Integer; AParity: Char; AStopBits: Integer;
  AFlowControl: TFlowControl);
begin
  FSerial.Config(ABaudRate, ADataBits, AParity, AStopBits, AFlowControl);
end;

procedure TLazSynapseSerialTransport.Connect(const ADevice: string);
begin
  FSerial.Connect(ADevice);
end;

function TLazSynapseSerialTransport.CanRead(
  const ATimeout: Integer): Boolean;
begin
  Result := FSerial.CanReadEx(ATimeout);
end;

function TLazSynapseSerialTransport.DeviceName: string;
begin
  Result := FSerial.Device;
end;

function TLazSynapseSerialTransport.IsOpen: Boolean;
begin
  Result := FSerial.Handle <> INVALID_HANDLE_VALUE;
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
  Result := FSerial.SendBuffer(ABuffer, ASize);
end;

function TLazSynapseSerialTransport.SendString(
  const AData: AnsiString): Integer;
begin
  FSerial.SendString(AData);
  Result := Length(AData);
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
