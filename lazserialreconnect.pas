unit LazSerialReconnect;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, LazSerialDevices, SerialWatcherSupport;

const
  DefaultReconnectIntervalMs = 1000;
  DefaultReconnectMaxAttempts = 5;

type
  // Main-thread policy and scheduling only; the serial component owns all I/O.
  TSerialReconnect = class(TComponent)
  private
    FDevices: TSerialDeviceInfoArray;
    FTarget: TSerialDeviceFilter;
    FConnectedDevice, FOriginalPort: string;
    FConnected, FHasIdentity, FPending, FWaitForRemoval, FEnabled: Boolean;
    FAttempts, FAttemptLimit, FIntervalMs, FMaxAttempts: Cardinal;
    FGeneration: QWord;
    FScheduler: TSerialRefreshScheduler;
    FOnReady: TNotifyEvent;
    procedure CaptureIdentity;
    procedure ScheduleCandidate;
    procedure TimerElapsed(Sender: TObject);
    procedure SetEnabled(AValue: Boolean);
    procedure SetIntervalMs(AValue: Cardinal);
    procedure SetMaxAttempts(AValue: Cardinal);
  protected
    procedure ReplaceScheduler(AScheduler: TSerialRefreshScheduler);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Cancel;
    procedure Connected(const ADevice: string);
    procedure Observe(const ADevices: TSerialDeviceInfoArray);
    procedure ConnectionLost(AConfirmedRemoval: Boolean);
    procedure DeferAttempt;
    function BeginAttempt(out ADevice: string): Boolean;
    function AttemptFailed: Boolean;
    property Enabled: Boolean read FEnabled write SetEnabled;
    property IntervalMs: Cardinal read FIntervalMs write SetIntervalMs;
    property MaxAttempts: Cardinal read FMaxAttempts write SetMaxAttempts;
    property Pending: Boolean read FPending;
    property Generation: QWord read FGeneration;
    property OnReady: TNotifyEvent read FOnReady write FOnReady;
  end;

implementation

constructor TSerialReconnect.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FIntervalMs := DefaultReconnectIntervalMs;
  FMaxAttempts := DefaultReconnectMaxAttempts;
  FScheduler := TSerialTimerScheduler.Create;
end;

destructor TSerialReconnect.Destroy;
begin
  FScheduler.Free;
  inherited Destroy;
end;

procedure TSerialReconnect.ReplaceScheduler(AScheduler: TSerialRefreshScheduler);
begin
  if AScheduler = nil then raise EArgumentNilException.Create('AScheduler');
  if AScheduler = FScheduler then Exit;
  FScheduler.Free;
  FScheduler := AScheduler;
  ScheduleCandidate;
end;

procedure TSerialReconnect.Cancel;
begin
  Inc(FGeneration);
  FScheduler.Cancel;
  FPending := False;
  FConnected := False;
  FHasIdentity := False;
  FTarget := Default(TSerialDeviceFilter);
  FAttempts := 0;
end;

procedure TSerialReconnect.Connected(const ADevice: string);
begin
  Inc(FGeneration);
  FScheduler.Cancel;
  FPending := False;
  FConnected := True;
  FConnectedDevice := ADevice;
  FOriginalPort := ADevice;
  FAttempts := 0;
  CaptureIdentity;
end;

procedure TSerialReconnect.CaptureIdentity;
var
  I, Found: Integer;
  AliasFilter: TSerialDeviceFilter;
begin
  if not FConnected or FHasIdentity or (FConnectedDevice = '') then Exit;
  Found := IndexOfSerialDevice(FDevices, FConnectedDevice);
  if Found < 0 then
  begin
    AliasFilter := Default(TSerialDeviceFilter);
    AliasFilter.PersistentId := FConnectedDevice;
    for I := Low(FDevices) to High(FDevices) do
      if MatchesSerialDevice(FDevices[I], AliasFilter) then
      begin
        if Found >= 0 then Exit; // An alias must identify one port.
        Found := I;
      end;
  end;
  if Found < 0 then Exit;
  FTarget := Default(TSerialDeviceFilter);
  if FDevices[Found].PersistentId <> '' then
    FTarget.PersistentId := FDevices[Found].PersistentId
  else
  begin
    FTarget.VendorId := NormalizeUsbId(FDevices[Found].VendorId);
    FTarget.ProductId := NormalizeUsbId(FDevices[Found].ProductId);
    FTarget.SerialShort := FDevices[Found].SerialShort;
    if (FTarget.VendorId = '') or (FTarget.ProductId = '') or
      (FTarget.SerialShort = '') then Exit;
  end;
  FHasIdentity := True;
  FOriginalPort := FDevices[Found].Device;
end;

procedure TSerialReconnect.Observe(const ADevices: TSerialDeviceInfoArray);
var Matches: TSerialDeviceInfoArray;
begin
  FDevices := Copy(ADevices);
  CaptureIdentity;
  if FPending and FWaitForRemoval then
  begin
    Matches := FilterSerialDevices(FDevices, FTarget);
    if IndexOfSerialDevice(Matches, FOriginalPort) < 0 then
      FWaitForRemoval := False;
  end;
  ScheduleCandidate;
end;

procedure TSerialReconnect.ConnectionLost(AConfirmedRemoval: Boolean);
begin
  if not FConnected then Exit;
  FConnected := False;
  if not FEnabled or not FHasIdentity then Exit;
  Inc(FGeneration);
  FPending := True;
  FWaitForRemoval := not AConfirmedRemoval;
  FAttempts := 0;
  FAttemptLimit := FMaxAttempts;
  Observe(FDevices);
end;

procedure TSerialReconnect.ScheduleCandidate;
var Matches: TSerialDeviceInfoArray;
begin
  if FPending and not FWaitForRemoval then
  begin
    Matches := FilterSerialDevices(FDevices, FTarget);
    if (Length(Matches) = 1) and (Matches[0].Device <> '') then
    begin
      if not FScheduler.Scheduled then
        FScheduler.Schedule(FIntervalMs, @TimerElapsed);
      Exit;
    end;
  end;
  FScheduler.Cancel;
end;

procedure TSerialReconnect.DeferAttempt;
begin
  ScheduleCandidate;
end;

function TSerialReconnect.BeginAttempt(out ADevice: string): Boolean;
var Matches: TSerialDeviceInfoArray;
begin
  ADevice := '';
  Result := False;
  if not FPending or FWaitForRemoval then Exit;
  Matches := FilterSerialDevices(FDevices, FTarget);
  if (Length(Matches) <> 1) or (Matches[0].Device = '') then Exit;
  FScheduler.Cancel;
  ADevice := Matches[0].Device;
  Inc(FAttempts);
  Result := True;
end;

function TSerialReconnect.AttemptFailed: Boolean;
begin
  Result := FPending and (FAttempts >= FAttemptLimit);
  if Result then FPending := False;
  ScheduleCandidate;
end;

procedure TSerialReconnect.TimerElapsed(Sender: TObject);
begin
  if Assigned(FOnReady) then FOnReady(Self);
  // The owner may have been destroyed by the callback.
end;

procedure TSerialReconnect.SetEnabled(AValue: Boolean);
begin
  if FEnabled = AValue then Exit;
  FEnabled := AValue;
  if not FEnabled then Cancel;
end;

procedure TSerialReconnect.SetIntervalMs(AValue: Cardinal);
begin
  if AValue = 0 then raise EArgumentException.Create('Reconnect interval must be positive');
  FIntervalMs := AValue;
end;

procedure TSerialReconnect.SetMaxAttempts(AValue: Cardinal);
begin
  if AValue = 0 then raise EArgumentException.Create('Reconnect attempts must be positive');
  FMaxAttempts := AValue;
end;

end.
