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

  TSerialDeviceRefreshThread = class(TThread)
  private
    FDelivering: Boolean;
    FDevices: TSerialDeviceInfoArray;
    FLoadDevices: TLoadSerialDevicesMethod;
    FLoadSucceeded: Boolean;
    FOnDevicesLoaded: TSerialDevicesLoadedMethod;
    FOnFinished: TSerialDeviceRefreshFinishedMethod;
    FStarted: Boolean;
    procedure Deliver;
  protected
    procedure Execute; override;
  public
    constructor Create(
      const ALoadDevices: TLoadSerialDevicesMethod;
      const AOnDevicesLoaded: TSerialDevicesLoadedMethod;
      const AOnFinished: TSerialDeviceRefreshFinishedMethod = nil
    );
    procedure DetachCallbacks;
    procedure Start; reintroduce;
    property Delivering: Boolean read FDelivering;
    property LoadSucceeded: Boolean read FLoadSucceeded;
  end;

procedure CancelSerialDeviceRefresh(
  var AThread: TSerialDeviceRefreshThread
);

implementation

constructor TSerialDeviceRefreshThread.Create(
  const ALoadDevices: TLoadSerialDevicesMethod;
  const AOnDevicesLoaded: TSerialDevicesLoadedMethod;
  const AOnFinished: TSerialDeviceRefreshFinishedMethod
);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDelivering := False;
  FLoadDevices := ALoadDevices;
  FLoadSucceeded := False;
  FOnDevicesLoaded := AOnDevicesLoaded;
  FOnFinished := AOnFinished;
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
begin
  try
    if not Terminated and Assigned(FLoadDevices) then
    begin
      FDevices := FLoadDevices();
      FLoadSucceeded := True;
    end;
  except
    FDevices := nil;
    FLoadSucceeded := False;
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
    if not Terminated and Assigned(FOnFinished) then
      FOnFinished();
  end;
end;

procedure TSerialDeviceRefreshThread.DetachCallbacks;
begin
  FLoadDevices := nil;
  FOnDevicesLoaded := nil;
  FOnFinished := nil;
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
  if not Thread.FStarted then
    Thread.Start;
  Thread.WaitFor;
  TThread.RemoveQueuedEvents(Thread);
  Thread.DetachCallbacks;
  Thread.Free;
end;

end.
