//Introduced in v0.7 by СМ630 2025÷2026
unit SerialWatcher;

{$mode ObjFPC}{$H+}

interface

uses
  {$ifdef windows}Windows, jwaWinUser, JwaDbt, {$endif}
  {$ifNdef windows}FileUtil, {$endif}
  Controls, Classes, SysUtils, LCLIntf, ExtCtrls, PropEdits,
  LazSynaSer, LResources, LazSerialCommon;

type
  //Notifies if a COM port is connecter or disconnected
  TSerialWatcher = class(TComponent)
    private
      FComConnected : TNotifyEvent;
      FComDisconnected : TNotifyEvent;
      {$ifNdef windows}
      FTimer : TTimer;
      {$EndIf}
      FPrevDevs : TStringList;
      {$IfDef windows}
      procedure InitResources;
      {$EndIf}
      {$IfNDef windows}
      procedure DoOnTimer(Sender: TObject);
      {$EndIf}
    protected
      {$IfDef windows}
      procedure WndProcNew(var Message: TMessage);
      {$EndIf}
   public
     constructor Create (aOwner: TComponent); override;
     destructor Destroy; override;
   published
      property OnComConnected: TNotifyEvent read FComConnected write FComConnected;
      property OnComDisconnected: TNotifyEvent read FComDisconnected write FComDisconnected;
  end;

DEV_BROADCAST_HDR_DEVICE_TYPE = Cardinal;

DEV_BROADCAST_HDR = record
  dbch_size: Cardinal;
  dbch_devicetype: DEV_BROADCAST_HDR_DEVICE_TYPE;
  dbch_reserved: Cardinal;
end;

DEV_BROADCAST_DEVICEINTERFACE_W = record
  dbcc_size: Cardinal;
  dbcc_devicetype: Cardinal;
  dbcc_reserved: Cardinal;
  dbcc_classguid: TGuid;
  dbcc_name: array[0..0] of WideChar;
end;

const
 DBT_DEVTYP_DEVICEINTERFACE = $5;
 DEVICE_NOTIFY_WINDOW_HANDLE = $0;
 DEVICE_NOTIFY_ALL_INTERFACE_CLASSES = $4;
 //THIS IS A GUI FOR USB
 GUID_DEVINTERFACE_USB_DEVICE: TGUID = '{A5DCBF10-6530-11D2-901F-00C04FB951ED}';

var
  _dev: Dev_Broadcast_DeviceInterface_W;
  DevBlockRem: DEV_BROADCAST_HDR;
  {$ifdef windows}
  NewHandle: HWND;
  FDevNotify: HDEVNOTIFY;
  {$endif}

procedure Register;

implementation

{$ifdef windows}
procedure TSerialWatcher.InitResources;
begin
  NewHandle:= LCLIntf.AllocateHwnd(@WndProcNew);
  ZeroMemory(@_dev, sizeOf(Dev_Broadcast_DeviceInterface_W));
  with _dev do
    begin
      dbcc_size:=sizeOf(Dev_Broadcast_DeviceInterface_W);
      dbcc_devicetype:= DBT_DEVTYP_DEVICEINTERFACE;
      dbcc_reserved:=0;
      dbcc_classguid:= GUID_DEVINTERFACE_USB_DEVICE;
      dbcc_name:='';
    end;
  //Use "DEVICE_NOTIFY_ALL_INTERFACE_CLASSES" if you want catch all messages from all classes (ignore dbcc_classguid)
  FDevNotify:=RegisterDeviceNotification(NewHandle, @_dev, DEVICE_NOTIFY_WINDOW_HANDLE or DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
  Win32Check(FDevNotify <> nil);
end;
{$endif}

function ListsEqual (NewList: TStringList; OldList: TStringList) : Boolean;
var
  i : integer;
begin
  if (NewList.Count <> OldList.Count) then exit (False);
  Result := True;;
  if (NewList.Count = 0) then exit (True);
  for i:=0 to (NewList.Count - 1) do
  begin
    if NewList.Strings[i] <> OldList.Strings[i] then exit(False);
  end;
end;

function ItemsAdded (NewList: TStringList; OldList: TStringList) : Boolean;
var
  i : integer;
begin
  if (NewList.Count < 1) then exit(False);
  if (OldList.Count < NewList.Count) then exit(True);
  Result := False;
  for i:= 0 to (NewList.Count - 1) do
    if (OldList.IndexOf(NewList.Strings[i]) < 0) then exit(True);
end;

function ItemsRemoved (NewList: TStringList; OldList: TStringList) : Boolean;
var
  i : integer;
begin
  if (OldList.Count > NewList.Count) then exit(True);
  if (OldList.Count < 1) and (NewList.Count < 1) then exit(False);
  Result := False;
  for i:= 0 to (OldList.Count - 1) do
    if (NewList.IndexOf(OldList.Strings[i]) < 0) then exit(True);
end;

{$ifNdef windows}
function AssemblePrefixes: string;
var
  i: integer;
  Suffix : string = {$ifdef linux}'*'{$else}''{$endif};
begin
  Result := '';
  if (Length(OSPrefixes) = 0) then exit;
  for i := 0 to high(OSPrefixes) do
  begin
    if OSPrefixes[i].StartsWith('/dev/')
      then Result := Result + copy(OSPrefixes[i],6,MaxInt) + '*'
      else Result := Result + OSPrefixes[i] + '*';
    if (i < high(OSPrefixes)) then Result := Result + ';';
  end;
end;

procedure TSerialWatcher.DoOnTimer(Sender: TObject);
var
  CurrentDevs : TStringList;
begin
  CurrentDevs := TStringList.Create;
  FindAllFiles (CurrentDevs, '/dev', AssemblePrefixes,False);

  if (ListsEqual(CurrentDevs, FPrevDevs) = False) then
  begin
    //(Im)possibly maybe the values can be shuffled, but still the same, so no change has ocurred.
    if ItemsAdded(CurrentDevs, FPrevDevs) then
      if Assigned(FComConnected) then FComConnected(Self);
    if ItemsRemoved(CurrentDevs, FPrevDevs) then
      if Assigned(FComDisConnected) then FComDisConnected(Self);
  end;
  FPrevDevs.Assign(CurrentDevs);
  CurrentDevs.Free;
end;
{$endif}

constructor TSerialWatcher.Create (aOwner: TComponent);
begin
  inherited;
  {$ifdef windows}InitResources; {$endif}
  {$ifNdef windows}
  FPrevDevs := TStringList.Create;
  FindAllFiles (FPrevDevs,'/dev',AssemblePrefixes,False);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 250;
  FTimer.Enabled := True;
  FTimer.OnTimer := @DoOnTimer;
  {$endif}
end;

destructor TSerialWatcher.Destroy;
begin
  {$ifdef windows}
  if FDevNotify <> nil then
    UnregisterDeviceNotification(FDevNotify);
  {$endif}
  {$IfDef linux}
  if Assigned(FTimer) then FTimer.Free;
  {$endif}
  inherited;
end;

{$ifdef windows}
procedure TSerialWatcher.WndProcNew(var Message: TMessage);
begin
  if (Message.Msg = WM_DEVICECHANGE) then
    case Message.wParam of
      DBT_DEVICEARRIVAL :
        if (PDEV_BROADCAST_HDR(Message.Lparam)^.dbch_deviceType = 3) //This crashed for some values of wParam, so it must be exactly here
          and Assigned(FComConnected)
            then FComConnected(Self);
      DBT_DEVICEREMOVECOMPLETE :
        if (PDEV_BROADCAST_HDR(Message.Lparam)^.dbch_deviceType = 3)
          and Assigned(FComDisconnected)
            then FComDisconnected(Self);
    end; //case
end;
{$endif}

procedure Register;
begin
  {$I serialwatcher_icon.lrs}
  RegisterComponents('LazSerial',[TSerialWatcher]);
  RegisterPropertyEditor(TypeInfo(boolean), TSerialWatcher,
                        'Active', THiddenPropertyEditor);
end;

initialization
  {$i serialwatcher_icon.lrs}

end.
