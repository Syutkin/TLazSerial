unit SerialDeviceRefresh;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, LazSerialDevices;

type
  TLoadSerialDevicesMethod = function: TSerialDeviceInfoArray of object;
  TSerialDevicesLoadedMethod = procedure(
    const ADevices: TSerialDeviceInfoArray
  ) of object;

  TSerialDeviceRefreshThread = class(TThread)
  private
    FDelivering: Boolean;
    FDevices: TSerialDeviceInfoArray;
    FLoadDevices: TLoadSerialDevicesMethod;
    FOnDevicesLoaded: TSerialDevicesLoadedMethod;
    procedure Deliver;
  protected
    procedure Execute; override;
  public
    constructor Create(
      const ALoadDevices: TLoadSerialDevicesMethod;
      const AOnDevicesLoaded: TSerialDevicesLoadedMethod
    );
    procedure DetachCallbacks;
    property Delivering: Boolean read FDelivering;
  end;

procedure CancelSerialDeviceRefresh(
  var AThread: TSerialDeviceRefreshThread
);

implementation

constructor TSerialDeviceRefreshThread.Create(
  const ALoadDevices: TLoadSerialDevicesMethod;
  const AOnDevicesLoaded: TSerialDevicesLoadedMethod
);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDelivering := False;
  FLoadDevices := ALoadDevices;
  FOnDevicesLoaded := AOnDevicesLoaded;
end;

procedure TSerialDeviceRefreshThread.Execute;
begin
  try
    if not Terminated and Assigned(FLoadDevices) then
      FDevices := FLoadDevices();
  except
    FDevices := nil;
  end;

  if not Terminated and Assigned(FOnDevicesLoaded) then
    TThread.Queue(Self, @Deliver);
end;

procedure TSerialDeviceRefreshThread.Deliver;
begin
  FDelivering := True;
  try
    if not Terminated and Assigned(FOnDevicesLoaded) then
      FOnDevicesLoaded(FDevices);
  finally
    FDelivering := False;
  end;
end;

procedure TSerialDeviceRefreshThread.DetachCallbacks;
begin
  FLoadDevices := nil;
  FOnDevicesLoaded := nil;
end;

procedure CancelSerialDeviceRefresh(
  var AThread: TSerialDeviceRefreshThread
);
var
  Thread: TSerialDeviceRefreshThread;
begin
  Thread := AThread;
  AThread := nil;
  if Thread = nil then
    Exit;

  Thread.Terminate;
  Thread.WaitFor;
  TThread.RemoveQueuedEvents(Thread);
  Thread.DetachCallbacks;
  Thread.Free;
end;

end.
