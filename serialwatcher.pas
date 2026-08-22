//Introduced in v0.7 by СМ630 2025÷2026
//Notifies if a COM port is connecter or disconnected
unit SerialWatcher;

{$mode ObjFPC}{$H+}

interface

uses
  {$ifdef windows}Windows, jwaWinUser, JwaDbt, ActiveX, Dialogs, {Utilwmi,} {$endif}
  {$ifNdef windows}FileUtil,{$endif}
  Controls, Classes, SysUtils, LCLIntf, ExtCtrls, PropEdits, Forms,
  LazSynaSer, LResources, LazSerialCommon;

type
  TSerialWatcher = class;

  {$ifdef windows}
  TUpdatePortsThread = class(TThread)
  private

  protected
    procedure Execute; override;
  public
    Owner: TSerialWatcher;
    Constructor Create(CreateSuspended : boolean);
  end;
  {$endif}


  TSerialWatcher = class(TComponent)
    private
      FComConnected : TNotifyEvent;
      FComDisconnected : TNotifyEvent;
      FTimer : TTimer;
      FPrevDevs : TStringList;
      {$IfDef windows}
      FwParamLast : WPARAM;
      FUpdatePortsThread   : TUpdatePortsThread;
      procedure UpdatePorts;
      procedure InitResources;
      {$EndIf}
      procedure DoOnTimer(Sender: TObject);
    protected
      {$IfDef windows}
//      procedure Loaded; override;
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

function ListsEqual (NewList: TStringList; OldList: TStringList) : Boolean;
var
  i : integer;
begin
  if (NewList = nil) and (OldList <> nil) then exit (false);
  if (NewList <> nil) and (OldList = nil) then exit (false);
  if (NewList = nil) and (OldList = nil) then exit (true);
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

{$ifdef windows}
procedure TSerialWatcher.InitResources;
begin
  FwParamLast := 0;
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

procedure TSerialWatcher.UpdatePorts;
var
  CurrentDevs : TStringList;
begin
  FTimer.Enabled := False;
  if (FwParamLast = DBT_DEVNODES_CHANGED) then //No info if the device was plugged or unplugged, so far observed with malfunctioning devices only
    begin
      //TODO: For some reason this code is executed twice. It does not seem to cause issues, anyway
      FwParamLast := 0;
      CurrentDevs := TStringList.Create;
      CurrentDevs.StrictDelimiter := True;
      CurrentDevs.Delimiter := ',';
      try
        CurrentDevs.DelimitedText := GetSerialPortNames(True); //Might crash here
        if (ListsEqual(CurrentDevs, FPrevDevs) = False) then
        begin
          //(Im)possibly maybe the values can be shuffled, but still the same, so no change has ocurred.
          if ItemsAdded(CurrentDevs, FPrevDevs) then
            if Assigned(FComConnected) then FComConnected(Self);
          if ItemsRemoved(CurrentDevs, FPrevDevs) then
            if Assigned(FComDisConnected) then FComDisConnected(Self);
        end;
        FPrevDevs.Assign(CurrentDevs);
      finally
        CurrentDevs.Free;
      end; //try
    end; //if
end;

{$endif}

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

{$ifdef windows}
procedure TSerialWatcher.DoOnTimer(Sender: TObject);
begin
  FTimer.Enabled := False;
  FUpdatePortsThread := TUpdatePortsThread.Create(True); // This way it doesn't start automatically
  FUpdatePortsThread.Owner := Self;
  FUpdatePortsThread.Start;
end;
{$endif}

{{$IfDef windows}
procedure TSerialWatcher.Loaded;
begin
  inherited Loaded;
  if not (csDesigning in ComponentState) then
    FPrevDevs.DelimitedText := GetSerialPortNames(True);
end;
{$endif}}

constructor TSerialWatcher.Create (aOwner: TComponent);
begin
  inherited;
  FTimer := TTimer.Create(Self);
  FPrevDevs := TStringList.Create;
  {$ifdef windows}
  InitResources;
  FTimer.Interval := 3000; //tried with 500, was not long enough
  FTimer.Enabled := False;
//  if (AOwner <> nil) and not (csLoading in AOwner.ComponentState) and not (csDesigning in ComponentState) then
    FPrevDevs.DelimitedText := GetSerialPortNames(False{True});
  {$endif}
  {$ifNdef windows}
  FindAllFiles (FPrevDevs,'/dev',AssemblePrefixes,False);
  FTimer.Interval := 250;
  FTimer.Enabled := True;
  {$endif}
  FTimer.OnTimer := @DoOnTimer;
end;

destructor TSerialWatcher.Destroy;
begin
  FPrevDevs.Free;
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
  begin
    case Message.wParam of
      DBT_DEVICEARRIVAL :
        begin
          FTimer.Enabled := False;
          FwParamLast := DBT_DEVICEARRIVAL;
          if (PDEV_BROADCAST_HDR(Message.Lparam)^.dbch_deviceType = 3) //This crashed for some values of wParam, so it must be exactly here
            and Assigned(FComConnected)
              then FComConnected(Self);
          FwParamLast := 0;
          end; //DBT_DEVICEARRIVAL
      DBT_DEVICEREMOVECOMPLETE :
        begin
          FTimer.Enabled := False;
          FwParamLast := DBT_DEVICEREMOVECOMPLETE;
          if (PDEV_BROADCAST_HDR(Message.Lparam)^.dbch_deviceType = 3)
            and Assigned(FComDisconnected)
              then FComDisconnected(Self);
          FwParamLast := 0;
          end; //DBT_DEVICEREMOVECOMPLETE
      { DBT_DEVNODES_CHANGED :
         if ((FwParamLast <> DBT_DEVICEARRIVAL) and (FwParamLast <> DBT_DEVICEREMOVECOMPLETE)) then
           if (Message.Lparam <> 0) then
             if (PDEV_BROADCAST_HDR(Message.Lparam)^.dbch_deviceType = 3) then
             begin
               FwParamLast := DBT_DEVNODES_CHANGED; //Some devices never send DBT_DEVICEARRIVAL or DBT_DEVICEREMOVECOMPLETE, but  WM_DEVICECHANGE is sent multiple times.
               FTimer.Enabled := False;
               FTimer.Enabled := True; //restart the timer
             end;}
      DBT_DEVNODES_CHANGED :
       if ((FwParamLast <> DBT_DEVICEARRIVAL) and (FwParamLast <> DBT_DEVICEREMOVECOMPLETE)) then
       begin
         FwParamLast := DBT_DEVNODES_CHANGED;
         FTimer.Enabled := False;
         FTimer.Enabled := True;
       end;
    end; //case
  end; //if Message.Msg
end;

{TUpdatePortsThread}
constructor TUpdatePortsThread.Create(CreateSuspended : boolean);
begin
  inherited Create(CreateSuspended);
  FreeOnTerminate := True;
end;

procedure TUpdatePortsThread.Execute;
begin
  try
    //CoInitialize(nil); //The app will crash without this
    //The first call of GetWMIInfo is slow. The next call is done in TriggerDisconnected, but it is not slow
    //Todo: maybe this is not reliable enough
    //GetWMIInfo('Win32_PnPEntity',['Caption','DeviceID'],'WHERE Caption LIKE ''%%(COM%%)''',30); //usually this does not take more than 6 seconds, but 20 seconds are also observed
    @Owner.UpdatePorts;
    Synchronize(@Application.ProcessMessages);
  finally
    Terminate;
  end; //try
end;
{$endif} //windows


procedure Register;
begin
  {$I serialwatcher_icon.lrs}
  RegisterComponents('LazSerial',[TSerialWatcher]);
  RegisterPropertyEditor(TypeInfo(boolean), TSerialWatcher, 'Active', THiddenPropertyEditor);
end;

initialization
  {$i serialwatcher_icon.lrs}

end.
