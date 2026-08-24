unit SerialWindowsChangeSource;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SerialWatcherSupport;

{$IFDEF Windows}
type
  TSerialWindowsNotificationDriver = class
  public
    function Start(
      const AOnChanged: TNotifyEvent;
      const AOnFailed: TNotifyEvent
    ): Boolean; virtual; abstract;
    procedure Stop; virtual; abstract;
  end;

  TSerialWindowsNotificationChangeSource = class(TSerialChangeSource)
  private
    FDriver: TSerialWindowsNotificationDriver;
    FOwnDriver: Boolean;
    procedure DriverChanged(Sender: TObject);
    procedure DriverFailed(Sender: TObject);
  protected
    procedure DoStart; override;
    procedure DoStop; override;
    function GetRequiresSettling: Boolean; override;
  public
    constructor Create(
      ADriver: TSerialWindowsNotificationDriver;
      const AOwnDriver: Boolean = True
    );
    destructor Destroy; override;
  end;

function CreateWindowsSerialChangeSource: TSerialChangeSource;
{$ENDIF}

implementation

{$IFDEF Windows}
uses
  LCLIntf, LMessages, Windows, JwaDbt, JwaWinUser, SysUtils;

type
  TSerialWindowsDeviceNotificationDriver = class(
    TSerialWindowsNotificationDriver
  )
  private
    FDeviceNotification: HDEVNOTIFY;
    FOnChanged: TNotifyEvent;
    FOnFailed: TNotifyEvent;
    FWindowHandle: HWND;
    procedure WndProc(var AMessage: TMessage);
  public
    function Start(
      const AOnChanged: TNotifyEvent;
      const AOnFailed: TNotifyEvent
    ): Boolean; override;
    procedure Stop; override;
    destructor Destroy; override;
  end;

const
  GuidDeviceInterfaceComPort: TGUID =
    '{86E0D1E0-8089-11D0-9CE4-08003E301F73}';
  WindowsPollingIntervalMs = 1000;

constructor TSerialWindowsNotificationChangeSource.Create(
  ADriver: TSerialWindowsNotificationDriver;
  const AOwnDriver: Boolean
);
begin
  inherited Create;
  if ADriver = nil then
    raise EArgumentNilException.Create('ADriver');
  FDriver := ADriver;
  FOwnDriver := AOwnDriver;
end;

procedure TSerialWindowsNotificationChangeSource.DriverChanged(Sender: TObject);
begin
  Changed;
end;

procedure TSerialWindowsNotificationChangeSource.DriverFailed(Sender: TObject);
begin
  Failed;
end;

procedure TSerialWindowsNotificationChangeSource.DoStart;
begin
  if not FDriver.Start(@DriverChanged, @DriverFailed) then
  begin
    FDriver.Stop;
    raise EInvalidOperation.Create(
      'Windows serial device notifications are unavailable'
    );
  end;
end;

procedure TSerialWindowsNotificationChangeSource.DoStop;
begin
  FDriver.Stop;
end;

function TSerialWindowsNotificationChangeSource.GetRequiresSettling: Boolean;
begin
  Result := True;
end;

destructor TSerialWindowsNotificationChangeSource.Destroy;
begin
  Stop;
  if FOwnDriver then
    FDriver.Free;
  inherited Destroy;
end;

function TSerialWindowsDeviceNotificationDriver.Start(
  const AOnChanged: TNotifyEvent;
  const AOnFailed: TNotifyEvent
): Boolean;
var
  DeviceInterface: DEV_BROADCAST_DEVICEINTERFACE_W;
begin
  Result := False;
  Stop;
  FOnChanged := AOnChanged;
  FOnFailed := AOnFailed;
  try
    FWindowHandle := LCLIntf.AllocateHWnd(@WndProc);
    if FWindowHandle = 0 then
      Exit;

    ZeroMemory(@DeviceInterface, SizeOf(DeviceInterface));
    DeviceInterface.dbcc_size := SizeOf(DeviceInterface);
    DeviceInterface.dbcc_devicetype := DBT_DEVTYP_DEVICEINTERFACE;
    DeviceInterface.dbcc_classguid := GuidDeviceInterfaceComPort;
    FDeviceNotification := RegisterDeviceNotification(
      FWindowHandle,
      @DeviceInterface,
      DEVICE_NOTIFY_WINDOW_HANDLE
    );
    Result := FDeviceNotification <> nil;
  except
    Result := False;
  end;
  if not Result then
    Stop;
end;

procedure TSerialWindowsDeviceNotificationDriver.Stop;
begin
  FOnChanged := nil;
  FOnFailed := nil;
  if FDeviceNotification <> nil then
    UnregisterDeviceNotification(FDeviceNotification);
  FDeviceNotification := nil;
  if FWindowHandle <> 0 then
    LCLIntf.DeallocateHWnd(FWindowHandle);
  FWindowHandle := 0;
end;

procedure TSerialWindowsDeviceNotificationDriver.WndProc(
  var AMessage: TMessage
);
begin
  if AMessage.Msg = WM_DEVICECHANGE then
    case AMessage.WParam of
      DBT_DEVICEARRIVAL,
      DBT_DEVICEREMOVECOMPLETE,
      DBT_DEVNODES_CHANGED:
        if Assigned(FOnChanged) then
          FOnChanged(Self);
    end;
end;

destructor TSerialWindowsDeviceNotificationDriver.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function CreateWindowsSerialChangeSource: TSerialChangeSource;
begin
  Result := TSerialFallbackChangeSource.Create([
    TSerialWindowsNotificationChangeSource.Create(
      TSerialWindowsDeviceNotificationDriver.Create
    ),
    TSerialPollingChangeSource.Create(WindowsPollingIntervalMs)
  ]);
end;
{$ENDIF}

end.
