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
  TSerialDeviceRefreshFinishedMethod = procedure of object;

  ISerialDeviceRefreshDelivery = interface
    procedure Cancel;
    procedure Queue(AThread: TThread);
    procedure SetResult(const ADevices: TSerialDeviceInfoArray;
      const ALoadSucceeded: Boolean);
    function GetDelivering: Boolean;
    function GetLoadSucceeded: Boolean;
  end;

  TSerialDeviceRefreshThread = class(TThread)
  private
    FDelivery: ISerialDeviceRefreshDelivery;
    FLoadDevices: TLoadSerialDevicesMethod;
    FStarted: Boolean;
    function GetDelivering: Boolean;
    function GetLoadSucceeded: Boolean;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create(
      const ALoadDevices: TLoadSerialDevicesMethod;
      const AOnDevicesLoaded: TSerialDevicesLoadedMethod;
      const AOnFinished: TSerialDeviceRefreshFinishedMethod = nil
    );
    procedure DetachCallbacks;
    procedure Start; reintroduce;
    property Delivering: Boolean read GetDelivering;
    property LoadSucceeded: Boolean read GetLoadSucceeded;
  end;

procedure CancelSerialDeviceRefresh(
  var AThread: TSerialDeviceRefreshThread
);

implementation

type
  TSerialDeviceRefreshDelivery = class(TInterfacedObject,
    ISerialDeviceRefreshDelivery)
  private
    FCancelled: Boolean;
    FDelivering: Boolean;
    FDevices: TSerialDeviceInfoArray;
    FLoadSucceeded: Boolean;
    FOnDevicesLoaded: TSerialDevicesLoadedMethod;
    FOnFinished: TSerialDeviceRefreshFinishedMethod;
    procedure Deliver;
  public
    constructor Create(const AOnDevicesLoaded: TSerialDevicesLoadedMethod;
      const AOnFinished: TSerialDeviceRefreshFinishedMethod);
    procedure Cancel;
    procedure Queue(AThread: TThread);
    procedure SetResult(const ADevices: TSerialDeviceInfoArray;
      const ALoadSucceeded: Boolean);
    function GetDelivering: Boolean;
    function GetLoadSucceeded: Boolean;
  end;

constructor TSerialDeviceRefreshDelivery.Create(
  const AOnDevicesLoaded: TSerialDevicesLoadedMethod;
  const AOnFinished: TSerialDeviceRefreshFinishedMethod);
begin
  inherited Create;
  FOnDevicesLoaded := AOnDevicesLoaded;
  FOnFinished := AOnFinished;
end;

procedure TSerialDeviceRefreshDelivery.Cancel;
begin
  FCancelled := True;
  FOnDevicesLoaded := nil;
  FOnFinished := nil;
end;

procedure TSerialDeviceRefreshDelivery.Queue(AThread: TThread);
begin
  TThread.Queue(AThread, @Deliver);
end;

procedure TSerialDeviceRefreshDelivery.SetResult(
  const ADevices: TSerialDeviceInfoArray; const ALoadSucceeded: Boolean);
begin
  FDevices := ADevices;
  FLoadSucceeded := ALoadSucceeded;
end;

function TSerialDeviceRefreshDelivery.GetDelivering: Boolean;
begin
  Result := FDelivering;
end;

function TSerialDeviceRefreshDelivery.GetLoadSucceeded: Boolean;
begin
  Result := FLoadSucceeded;
end;

procedure TSerialDeviceRefreshDelivery.Deliver;
var
  KeepAlive: ISerialDeviceRefreshDelivery;
begin
  // A callback may free the owner and its worker. Keep all delivery state
  // alive independently, and only touch that state after calling user code.
  KeepAlive := Self;
  FDelivering := True;
  try
    if not FCancelled and Assigned(FOnDevicesLoaded) then
      FOnDevicesLoaded(FDevices);
  finally
    FDelivering := False;
    if not FCancelled and Assigned(FOnFinished) then
      FOnFinished();
  end;
end;

constructor TSerialDeviceRefreshThread.Create(
  const ALoadDevices: TLoadSerialDevicesMethod;
  const AOnDevicesLoaded: TSerialDevicesLoadedMethod;
  const AOnFinished: TSerialDeviceRefreshFinishedMethod
);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDelivery := TSerialDeviceRefreshDelivery.Create(AOnDevicesLoaded, AOnFinished);
  FLoadDevices := ALoadDevices;
  FStarted := False;
end;

procedure TSerialDeviceRefreshThread.Start;
begin
  if FStarted then
    Exit;
  FStarted := True;
  try
    inherited Start;
  except
    FStarted := False;
    raise;
  end;
end;

procedure TSerialDeviceRefreshThread.Execute;
var
  Devices: TSerialDeviceInfoArray;
  Succeeded: Boolean;
begin
  Devices := nil;
  Succeeded := False;
  try
    if not Terminated and Assigned(FLoadDevices) then
    begin
      Devices := FLoadDevices();
      Succeeded := True;
    end;
  except
    Devices := nil;
    Succeeded := False;
  end;

  FDelivery.SetResult(Devices, Succeeded);
  if not Terminated then
    FDelivery.Queue(Self);
end;

function TSerialDeviceRefreshThread.GetDelivering: Boolean;
begin
  Result := FDelivery.GetDelivering;
end;

procedure TSerialDeviceRefreshThread.TerminatedSet;
begin
  inherited TerminatedSet;
  if FDelivery <> nil then
    FDelivery.Cancel;
end;

function TSerialDeviceRefreshThread.GetLoadSucceeded: Boolean;
begin
  Result := FDelivery.GetLoadSucceeded;
end;

procedure TSerialDeviceRefreshThread.DetachCallbacks;
begin
  FLoadDevices := nil;
  FDelivery.Cancel;
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

  // WaitFor may pump queued callbacks on the main thread. Invalidate their
  // targets before joining, while leaving the loader attached until it exits.
  Thread.Terminate;
  if not Thread.FStarted then
    Thread.Start;
  Thread.WaitFor;
  Thread.DetachCallbacks;
  TThread.RemoveQueuedEvents(Thread);
  Thread.Free;
end;

end.
