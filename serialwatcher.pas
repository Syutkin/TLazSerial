// Introduced in v0.7 by СМ630 2025÷2026
unit SerialWatcher;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF Windows}
  Windows, JwaWinUser, JwaDbt,
  {$ENDIF}
  Classes, SysUtils, Controls, LCLIntf, LResources, LazSerialDevices,
  SerialWatcherSupport, SerialDeviceRefresh;

type
  TSerialWatcher = class(TComponent)
  private
    FChangeDelayMs: Cardinal;
    FChangeSource: TSerialChangeSource;
    FComConnected: TNotifyEvent;
    FComDisconnected: TNotifyEvent;
    FDeviceRefreshThread: TSerialDeviceRefreshThread;
    FDevices: TSerialDeviceInfoArray;
    FInitialized: Boolean;
    FOwnInfrastructure: Boolean;
    FRefreshDirty: Boolean;
    FRefreshOnLoaded: Boolean;
    FRefreshPending: Boolean;
    FRefreshScheduler: TSerialRefreshScheduler;
    FWatching: Boolean;
    {$IFDEF Windows}
    FDeviceNotification: HDEVNOTIFY;
    FWindowHandle: HWND;
    procedure InitializeWindowsNotifications;
    procedure WndProcNew(var Message: TMessage);
    {$ENDIF}
    procedure ChangeDetected(Sender: TObject);
    procedure InitializeInfrastructure(
      AChangeSource: TSerialChangeSource;
      ARefreshScheduler: TSerialRefreshScheduler;
      const AOwnInfrastructure: Boolean
    );
    procedure RefreshFinished;
    procedure ScheduledRefresh(Sender: TObject);
    procedure StartWatching;
    procedure StartBackgroundRefresh;
  protected
    procedure SetInfrastructure(
      AChangeSource: TSerialChangeSource;
      ARefreshScheduler: TSerialRefreshScheduler;
      const AOwnInfrastructure: Boolean
    );
    procedure ApplyDevices(const ADevices: TSerialDeviceInfoArray); virtual;
    function LoadDevices: TSerialDeviceInfoArray; virtual;
    procedure Loaded; override;
    procedure PollDevices;
    procedure StopWatching;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AdoptSnapshot(const ADevices: TSerialDeviceInfoArray);
    function ContainsDevice(const ADevice: string): Boolean;
    procedure Refresh;
    property RefreshOnLoaded: Boolean
      read FRefreshOnLoaded write FRefreshOnLoaded;
  published
    property OnComConnected: TNotifyEvent
      read FComConnected write FComConnected;
    property OnComDisconnected: TNotifyEvent
      read FComDisconnected write FComDisconnected;
  end;

procedure Register;

implementation

const
  SerialRefreshSettleRetryMs = 1;

function CopyDevices(
  const ADevices: TSerialDeviceInfoArray
): TSerialDeviceInfoArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ADevices));
  for I := Low(ADevices) to High(ADevices) do
    Result[I] := ADevices[I];
end;

function SnapshotHasAddedDevices(
  const APrevious, ACurrent: TSerialDeviceInfoArray
): Boolean;
var
  I: Integer;
begin
  for I := Low(ACurrent) to High(ACurrent) do
    if not ContainsSerialDevice(APrevious, ACurrent[I].Device) then
      Exit(True);
  Result := False;
end;

function SnapshotHasRemovedDevices(
  const APrevious, ACurrent: TSerialDeviceInfoArray
): Boolean;
var
  I: Integer;
begin
  for I := Low(APrevious) to High(APrevious) do
    if not ContainsSerialDevice(ACurrent, APrevious[I].Device) then
      Exit(True);
  Result := False;
end;

function TSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
begin
  Result := GetSerialDevices;
end;

procedure TSerialWatcher.Refresh;
begin
  StartWatching;
  if FRefreshPending then
    Exit;
  FRefreshScheduler.Cancel;
  FRefreshDirty := False;
  StartBackgroundRefresh;
end;

procedure TSerialWatcher.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray
);
var
  AddedDevices: Boolean;
  RemovedDevices: Boolean;
begin
  if not FInitialized then
  begin
    FDevices := CopyDevices(ADevices);
    FInitialized := True;
  end
  else
  begin
    AddedDevices := SnapshotHasAddedDevices(FDevices, ADevices);
    RemovedDevices := SnapshotHasRemovedDevices(FDevices, ADevices);
    FDevices := CopyDevices(ADevices);

    if AddedDevices and Assigned(FComConnected) then
      FComConnected(Self);
    if RemovedDevices and Assigned(FComDisconnected) then
      FComDisconnected(Self);
  end;
end;

procedure TSerialWatcher.PollDevices;
begin
  ApplyDevices(LoadDevices);
end;

procedure TSerialWatcher.AdoptSnapshot(
  const ADevices: TSerialDeviceInfoArray
);
begin
  FDevices := CopyDevices(ADevices);
  FInitialized := True;
  StartWatching;
end;

procedure TSerialWatcher.StartBackgroundRefresh;
begin
  if not FWatching or FRefreshPending then
    Exit;

  if FDeviceRefreshThread <> nil then
  begin
    if not FDeviceRefreshThread.Finished or
      FDeviceRefreshThread.Delivering then
    begin
      FRefreshScheduler.Schedule(
        SerialRefreshSettleRetryMs,
        @ScheduledRefresh
      );
      Exit;
    end;
    CancelSerialDeviceRefresh(FDeviceRefreshThread);
  end;

  FRefreshPending := True;
  try
    FDeviceRefreshThread := TSerialDeviceRefreshThread.Create(
      @LoadDevices,
      @ApplyDevices,
      @RefreshFinished
    );
    FDeviceRefreshThread.Start;
  except
    FRefreshPending := False;
    raise;
  end;
end;

procedure TSerialWatcher.RefreshFinished;
begin
  if not FRefreshPending then
    Exit;
  FRefreshPending := False;
  if FWatching and FRefreshDirty then
  begin
    FRefreshDirty := False;
    FRefreshScheduler.Schedule(FChangeDelayMs, @ScheduledRefresh);
  end;
end;

procedure TSerialWatcher.ChangeDetected(Sender: TObject);
begin
  if not FWatching then
    Exit;
  if FRefreshPending then
  begin
    FRefreshDirty := True;
    Exit;
  end;
  FRefreshScheduler.Schedule(FChangeDelayMs, @ScheduledRefresh);
end;

procedure TSerialWatcher.ScheduledRefresh(Sender: TObject);
begin
  if FWatching then
    StartBackgroundRefresh;
end;

procedure TSerialWatcher.InitializeInfrastructure(
  AChangeSource: TSerialChangeSource;
  ARefreshScheduler: TSerialRefreshScheduler;
  const AOwnInfrastructure: Boolean
);
begin
  if AChangeSource = nil then
    raise EArgumentNilException.Create('AChangeSource');
  if ARefreshScheduler = nil then
    raise EArgumentNilException.Create('ARefreshScheduler');

  FChangeSource := AChangeSource;
  FRefreshScheduler := ARefreshScheduler;
  FOwnInfrastructure := AOwnInfrastructure;
  FDevices := nil;
  FDeviceRefreshThread := nil;
  FInitialized := False;
  FRefreshDirty := False;
  FRefreshOnLoaded := True;
  FRefreshPending := False;
  FWatching := False;
  {$IFDEF Windows}
  FChangeDelayMs := 3000;
  {$ELSE}
  FChangeDelayMs := 0;
  {$ENDIF}
end;

procedure TSerialWatcher.SetInfrastructure(
  AChangeSource: TSerialChangeSource;
  ARefreshScheduler: TSerialRefreshScheduler;
  const AOwnInfrastructure: Boolean
);
begin
  if AChangeSource = nil then
    raise EArgumentNilException.Create('AChangeSource');
  if ARefreshScheduler = nil then
    raise EArgumentNilException.Create('ARefreshScheduler');

  StopWatching;
  if FOwnInfrastructure then
  begin
    FRefreshScheduler.Free;
    FChangeSource.Free;
  end;
  InitializeInfrastructure(
    AChangeSource,
    ARefreshScheduler,
    AOwnInfrastructure
  );
end;

constructor TSerialWatcher.Create(AOwner: TComponent);
var
  ChangeSource: TSerialChangeSource;
begin
  inherited Create(AOwner);
  {$IFDEF Windows}
  ChangeSource := TSerialManualChangeSource.Create;
  {$ELSE}
  ChangeSource := TSerialPollingChangeSource.Create(1000);
  {$ENDIF}
  try
    InitializeInfrastructure(
      ChangeSource,
      TSerialTimerScheduler.Create,
      True
    );
  except
    ChangeSource.Free;
    raise;
  end;

  {$IFDEF Windows}
  InitializeWindowsNotifications;
  {$ENDIF}
end;

procedure TSerialWatcher.StartWatching;
begin
  if FWatching then
    Exit;
  FWatching := True;
  try
    FChangeSource.Start(@ChangeDetected);
  except
    FWatching := False;
    raise;
  end;
end;

procedure TSerialWatcher.StopWatching;
begin
  FWatching := False;
  FRefreshDirty := False;
  if FRefreshScheduler <> nil then
    FRefreshScheduler.Cancel;
  if FChangeSource <> nil then
    FChangeSource.Stop;
  CancelSerialDeviceRefresh(FDeviceRefreshThread);
  FRefreshPending := False;
end;

procedure TSerialWatcher.Loaded;
begin
  inherited Loaded;
  if FRefreshOnLoaded and not (csDesigning in ComponentState) then
    Refresh;
end;

function TSerialWatcher.ContainsDevice(const ADevice: string): Boolean;
begin
  Result := FInitialized and ContainsSerialDevice(FDevices, ADevice);
end;

destructor TSerialWatcher.Destroy;
begin
  StopWatching;
  {$IFDEF Windows}
  if FDeviceNotification <> nil then
    UnregisterDeviceNotification(FDeviceNotification);
  if FWindowHandle <> 0 then
    DeallocateHWnd(FWindowHandle);
  {$ENDIF}
  if FOwnInfrastructure then
  begin
    FRefreshScheduler.Free;
    FChangeSource.Free;
  end;
  inherited Destroy;
end;

{$IFDEF Windows}
procedure TSerialWatcher.InitializeWindowsNotifications;
const
  GuidDeviceInterfaceUsbDevice: TGUID =
    '{A5DCBF10-6530-11D2-901F-00C04FB951ED}';
var
  DeviceInterface: DEV_BROADCAST_DEVICEINTERFACE_W;
begin
  FWindowHandle := LCLIntf.AllocateHWnd(@WndProcNew);
  ZeroMemory(@DeviceInterface, SizeOf(DeviceInterface));
  DeviceInterface.dbcc_size := SizeOf(DeviceInterface);
  DeviceInterface.dbcc_devicetype := DBT_DEVTYP_DEVICEINTERFACE;
  DeviceInterface.dbcc_classguid := GuidDeviceInterfaceUsbDevice;
  FDeviceNotification := RegisterDeviceNotification(
    FWindowHandle,
    @DeviceInterface,
    DEVICE_NOTIFY_WINDOW_HANDLE or DEVICE_NOTIFY_ALL_INTERFACE_CLASSES
  );
  Win32Check(FDeviceNotification <> nil);
end;

procedure TSerialWatcher.WndProcNew(var Message: TMessage);
begin
  if Message.Msg = WM_DEVICECHANGE then
    case Message.WParam of
      DBT_DEVICEARRIVAL,
      DBT_DEVICEREMOVECOMPLETE,
      DBT_DEVNODES_CHANGED:
        ChangeDetected(Self);
    end;
end;
{$ENDIF}

procedure Register;
begin
  {$I serialwatcher_icon.lrs}
  RegisterComponents('LazSerial', [TSerialWatcher]);
end;

initialization
  {$I serialwatcher_icon.lrs}

end.
