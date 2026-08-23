// Introduced in v0.7 by СМ630 2025÷2026
unit SerialWatcher;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF Windows}
  Windows, JwaWinUser, JwaDbt,
  {$ENDIF}
  Classes, SysUtils, Controls, LCLIntf, ExtCtrls, LResources,
  LazSerialDevices;

type
  TSerialWatcher = class(TComponent)
  private
    FComConnected: TNotifyEvent;
    FComDisconnected: TNotifyEvent;
    FDevices: TSerialDeviceInfoArray;
    FInitialized: Boolean;
    FTimer: TTimer;
    {$IFDEF Windows}
    FDeviceNotification: HDEVNOTIFY;
    FWindowHandle: HWND;
    procedure InitializeWindowsNotifications;
    procedure WndProcNew(var Message: TMessage);
    {$ENDIF}
    procedure DoOnTimer(Sender: TObject);
  protected
    function LoadDevices: TSerialDeviceInfoArray; virtual;
    procedure Loaded; override;
    procedure PollDevices;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function ContainsDevice(const ADevice: string): Boolean;
    procedure Refresh;
  published
    property OnComConnected: TNotifyEvent
      read FComConnected write FComConnected;
    property OnComDisconnected: TNotifyEvent
      read FComDisconnected write FComDisconnected;
  end;

procedure Register;

implementation

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
  FDevices := LoadDevices;
  FInitialized := True;
end;

procedure TSerialWatcher.PollDevices;
var
  AddedDevices: Boolean;
  CurrentDevices: TSerialDeviceInfoArray;
  RemovedDevices: Boolean;
begin
  CurrentDevices := LoadDevices;
  if not FInitialized then
  begin
    FDevices := CurrentDevices;
    FInitialized := True;
    Exit;
  end;

  AddedDevices := SnapshotHasAddedDevices(FDevices, CurrentDevices);
  RemovedDevices := SnapshotHasRemovedDevices(FDevices, CurrentDevices);
  FDevices := CurrentDevices;

  if AddedDevices and Assigned(FComConnected) then
    FComConnected(Self);
  if RemovedDevices and Assigned(FComDisconnected) then
    FComDisconnected(Self);
end;

procedure TSerialWatcher.DoOnTimer(Sender: TObject);
begin
  {$IFDEF Windows}
  FTimer.Enabled := False;
  {$ENDIF}
  PollDevices;
end;

constructor TSerialWatcher.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDevices := nil;
  FInitialized := False;

  FTimer := TTimer.Create(Self);
  FTimer.OnTimer := @DoOnTimer;
  {$IFDEF Windows}
  FTimer.Interval := 3000;
  FTimer.Enabled := False;
  InitializeWindowsNotifications;
  {$ELSE}
  FTimer.Interval := 1000;
  FTimer.Enabled := True;
  {$ENDIF}
end;

procedure TSerialWatcher.Loaded;
begin
  inherited Loaded;
  if not (csDesigning in ComponentState) then
    Refresh;
end;

function TSerialWatcher.ContainsDevice(const ADevice: string): Boolean;
begin
  Result := FInitialized and ContainsSerialDevice(FDevices, ADevice);
end;

destructor TSerialWatcher.Destroy;
begin
  {$IFDEF Windows}
  if FDeviceNotification <> 0 then
    UnregisterDeviceNotification(FDeviceNotification);
  if FWindowHandle <> 0 then
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
  Win32Check(FDeviceNotification <> 0);
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
