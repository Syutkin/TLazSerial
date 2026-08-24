// Introduced in v0.7 by СМ630 2025÷2026
unit SerialWatcher;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF Windows}
  Windows, JwaWinUser, JwaDbt,
  {$ENDIF}
  Classes, SysUtils, Controls, LCLIntf, ExtCtrls, LResources,
  LazSerialDevices, SerialDeviceRefresh;

type
  TSerialWatcher = class(TComponent)
  private
    FComConnected: TNotifyEvent;
    FComDisconnected: TNotifyEvent;
    FDeviceRefreshThread: TSerialDeviceRefreshThread;
    FDevices: TSerialDeviceInfoArray;
    FInitialized: Boolean;
    FRefreshOnLoaded: Boolean;
    FTimer: TTimer;
    {$IFDEF Windows}
    FDeviceNotification: HDEVNOTIFY;
    FWindowHandle: HWND;
    procedure InitializeWindowsNotifications;
    procedure WndProcNew(var Message: TMessage);
    {$ENDIF}
    procedure DoOnTimer(Sender: TObject);
    procedure StartBackgroundRefresh;
  protected
    procedure ApplyDevices(const ADevices: TSerialDeviceInfoArray); virtual;
    function LoadDevices: TSerialDeviceInfoArray; virtual;
    procedure Loaded; override;
    procedure PollDevices;
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

  {$IFNDEF Windows}
  FTimer.Enabled := True;
  {$ENDIF}
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
  {$IFNDEF Windows}
  FTimer.Enabled := True;
  {$ENDIF}
end;

procedure TSerialWatcher.StartBackgroundRefresh;
begin
  if FDeviceRefreshThread <> nil then
  begin
    if not FDeviceRefreshThread.Finished or
      FDeviceRefreshThread.Delivering then
      Exit;
    CancelSerialDeviceRefresh(FDeviceRefreshThread);
  end;

  FTimer.Enabled := False;
  FDeviceRefreshThread := TSerialDeviceRefreshThread.Create(
    @LoadDevices,
    @ApplyDevices
  );
  FDeviceRefreshThread.Start;
end;

procedure TSerialWatcher.DoOnTimer(Sender: TObject);
begin
  FTimer.Enabled := False;
  Refresh;
end;

constructor TSerialWatcher.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDevices := nil;
  FDeviceRefreshThread := nil;
  FInitialized := False;
  FRefreshOnLoaded := True;

  FTimer := TTimer.Create(Self);
  FTimer.OnTimer := @DoOnTimer;
  FTimer.Enabled := False;
  {$IFDEF Windows}
  FTimer.Interval := 3000;
  InitializeWindowsNotifications;
  {$ELSE}
  FTimer.Interval := 1000;
  {$ENDIF}
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
  FTimer.Enabled := False;
  CancelSerialDeviceRefresh(FDeviceRefreshThread);
  {$IFDEF Windows}
  if FDeviceNotification <> nil then
    UnregisterDeviceNotification(FDeviceNotification);
  if FWindowHandle <> nil then
    DeallocateHWnd(FWindowHandle);
  {$ENDIF}
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
        begin
          FTimer.Enabled := False;
          FTimer.Enabled := True;
        end;
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
