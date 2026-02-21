//Introduced in v0.7 by СМ630 2025÷2026
unit SerialSelector;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, LResources, Forms, Controls, Dialogs, StdCtrls, LazUTF8,
  LazSynaSer, LCL, Graphics, math, Types, LCLTranslator, LazStringUtils, ExtCtrls,
  SerialWatcher, LazSerialCommon
  {$ifNdef darwin}, StrUtils{$endif}
  {$ifdef windows}, registry, Messages, Windows, ActiveX, Utilwmi{$endif}
  {$ifNdef linux}, process{$endif};

type
  Integer1D = array of integer;
  String1D = array of string;
  tVIDPIDID = record
    VID_PID : string;
    ID : String; //TODO: Is this used ?
    EnumKeyName : String;
  end;
  tVIDPIDID_1D = array of tVIDPIDID;

  TSerialSelector = class;

  {$ifdef windows}
  TUpdatePortsThread = class(TThread)
  private

  protected
    procedure Execute; override;
  public
    Owner: TSerialSelector;
    Constructor Create(CreateSuspended : boolean);
  end;
  {$endif}


  TSerialSelector = class(TCustomComboBox)

    private
      fDevice              : string;      //Used to store the device name until the selector get populated
      fDeviceList          : TStringList; //The list of the ports without the friendly names
      fDeviceListFriend    : TStringList; //The list of the ports with the friendly names
      FSerialWatcher       : TSerialWatcher;
      FHintWindow          : THintWindow;
      FAddedPorts          : String;
      FRemovedPorts        : String;
      FShowHint            : Boolean;
      FHint                : String;
      FHintCaption         : String;
      FOptions             : tSSOptionS;
      FRefreshTimer        : TTimer;
      {$ifdef windows}
      FUpdatePortsThread   : TUpdatePortsThread;{$endif}
      function GetDevice: String;
      procedure SetDevice(aValue: string);
      function MouseIn : Boolean;
      procedure DoMouseEnter (Sender: TObject);
      procedure DoUpdateComPorts(Sender: TObject);
      procedure DoOnRefreshTimer(Sender: TObject);
      procedure HideHint(Sender: TObject);
      //The list of the ports to be displayed to the user. This data CANNOT be used for connecting to the serial port (see the “DeviceList” property).
      property Items; //TODO: Shall it be read only??
      procedure Loaded; override;
      procedure SetHint(const Value: string);
      procedure setOptions (Value:tSSOptionS);
      procedure SetShowHint(const Value: Boolean);
      procedure UpdatePorts;
    public
      //The name of the selected device in the format proper for connecting to. When set the item index is changed <b>if</b> the provided value is present in the list.
      property Device: String read GetDevice write SetDevice;
      constructor Create (aOwner: TComponent); override;
      destructor Destroy; override;
      property Text;
      procedure UpdateHint;
      procedure UpdateHintCaption;
      procedure Refresh;
    published
      // The list of the ports without the friendly names. This is the list that contains the usable port names.
      property DeviceList: TStringList read fDeviceList;
      // The list of the ports with the friendly names
      property DeviceListFriend : TStringList read fDeviceListFriend; //The list of the ports with the friendly names

      //Default combo box properties
      property Align;
      property Anchors;
      property ArrowKeysTraverseList;
      property AutoComplete;
      property AutoCompleteText;
      property AutoDropDown;
      property AutoSelect;
      property AutoSize;
      property BidiMode;
      property BorderSpacing;
      property BorderStyle;
      property CharCase;
      property Color;
      property Constraints;
      property DoubleBuffered;
      property DragCursor;
      property DragKind;
      property DragMode;
      property DropDownCount;
      property Enabled;
      property Font;
      // If empty, information about the serial devices is shown as a hint, otherwse the provided text is displayed
      property Hint : string read FHint write SetHint;
      property ItemHeight;
      property ItemIndex;
      property ItemWidth;
      property MaxLength;
      // AppendFriendlyNames - Appends friendly names to the names of the COM ports
      // AppendSerialNumber - Appends the serial number of the device to the friendly name. Serial devices rarely have serial numbers
      // Hide_tty_usbserial - (MacOS only) removes COM ports starting with tty.usbserial*, if duplicated by cu.usbserial*
      // UseWMI (windows only)- retrives the list of the serial devices from WMI (slower, but data is usually true) and uses registry if fails. If disabled, gets the list from the registry only (faster, but the data is often wrong).
      property Options : tSSOptions read FOptions write SetOptions;
      property ParentBidiMode;
      property ParentColor;
      property ParentDoubleBuffered;
      property ParentFont;
      property ParentShowHint;
      property PopupMenu;
      property ShowHint : Boolean read FShowHint write SetShowHint;
      property Sorted;
      property Style;
      property TabOrder;
      property TabStop;
      property TextHint;
      property Visible;
      property OnChange;
      property OnChangeBounds;
      property OnClick;
      property OnCloseUp;
      property OnContextPopup;
      property OnDblClick;
      property OnDragDrop;
      property OnDragOver;
      property OnDrawItem;
      property OnEndDrag;
      property OnDropDown;
      property OnEditingDone;
      property OnEnter;
      property OnExit;
      property OnGetItems;
      property OnKeyDown;
      property OnKeyPress;
      property OnKeyUp;
      property OnMeasureItem;
      property OnMouseDown;
      property OnMouseEnter;
      property OnMouseLeave;
      property OnMouseMove;
      property OnMouseUp;
      property OnMouseWheel;
      property OnMouseWheelDown;
      property OnMouseWheelUp;
      property OnSelect;
      property OnStartDrag;
      property OnUTF8KeyPress;
  end;

const
  DBT_DEVICEARRIVAL         = $8000;      // system detected a new device
  DBT_DEVNODES_CHANGED      = $0007;
  DBT_DEVICEREMOVECOMPLETE  = $8004;      // dec32772 = device is gone
  DBT_DEVTYP_HANDLE         = $00000006;  // file system handle
  DBT_DEVTYP_PORT           = $00000003;  // port handle (serial, parallel)
  DBT_DEVTYP_VOLUME         = $00000002;  // volume handle (CDROM, DVD)
  DBFT_MEDIA                = $0001;
  DBFT_NET                  = $0002;

procedure Register;

implementation

function TSerialSelector.GetDevice: string;
begin
  Result := '';
  if (Items.Count > ItemIndex)
    then Result := fDeviceList[ItemIndex];
end;

//TODO: Maybe allow unlisted devices?
procedure TSerialSelector.SetDevice(aValue: string);
var
  mIndex : integer = -1;
begin
  if (DeviceList.Count <1) then
  begin
    fDevice := aValue; //Store the value to populate it when the list is updated
    exit;
  end;
  mIndex := SearchStringList(DeviceList,aValue,{$ifdef windows}false{$else}true{$endif});
  if (mIndex > -1) then
  begin
    ItemIndex := mIndex;
    fDevice :=  DeviceList.Strings[ItemIndex];
  end;
end;

//TODO: Preserve the currently seleected port, if still present
procedure TSerialSelector.Refresh;
begin
  {$ifdef windows}
  DoUpdateComPorts(Self);
  {$else}
  UpdatePorts;
  {$endif};
end;

{$ifdef darwin}
procedure RemoveTTY(var aDeviceList: tStringlist; DoNothing : boolean);
var
  i: integer = 0;
begin
  if ((DoNothing = True) or (aDeviceList.Count = 0)) then exit;
  for i:= aDeviceList.Count -1 downto 0 do
    if aDeviceList.Strings[i].StartsWith('/dev/tty') then aDeviceList.Delete(i);
end;
{$endif}

procedure TSerialSelector.UpdatePorts;
var
  OldPorts: TStringList;
  AddedPorts: TStringList;
  RemovedPorts: TStringList;
  CurrentPort: string = '';
  i : integer;
  FriendlyName : string = '';
  DeviceIDs : string = '';
begin
  if (ItemIndex > 0)
    then CurrentPort := fDeviceList.Strings[ItemIndex]
    else CurrentPort := fDevice; //Stored device (from the settings)
  OldPorts     := TStringList.Create;
  AddedPorts   := TStringList.Create;
    AddedPorts.StrictDelimiter := True;
    AddedPorts.Delimiter := #13;
  RemovedPorts := TStringList.Create;
    RemovedPorts.StrictDelimiter := True;
    RemovedPorts.Delimiter := #13;

  OldPorts.Assign(fDeviceList);
  {$ifdef windows}
  if ssoUseWMI in FOptions
    then fDeviceList.CommaText := GetSerialPortNames(DeviceIDs)
    else {$endif}fDeviceList.CommaText := GetSerialPortNames;
  {$ifdef darwin}
  RemoveTTY(fDeviceList,not (ssoHide_tty_usbserial in FOptions));
  fDeviceList.Sort;
  {$endif}
  {$ifdef windows}{$IF FPC_FULLVERSION >= 30002}fDeviceList.CustomSort(@NaturalSortCompare);{$endif}{$endif}
  {$ifdef linux}{$IF FPC_FULLVERSION >= 30002}fDeviceList.CustomSort(@NaturalSortCompare);{$endif}{$endif}
  fDeviceListFriend.Clear;
  for i:= 0 to fDeviceList.Count -1 do
    begin
      FriendlyName := GetFriendlyName(fDeviceList[i],ssoAppendSerialNumber in FOptions{$ifdef windows},DeviceIDs{$endif});
      fDeviceListFriend.Append (fDeviceList[i] + BoolToStr(FriendlyName = '','',' <' + FriendlyName +'>'));
    end;

  if (OldPorts.Count > 0)    then FindRemovedPorts(OldPorts, fDeviceList, RemovedPorts);
  if (fDeviceList.Count < 1) then begin Clear; FRemovedPorts := UTF8StringReplace(RemovedPorts.DelimitedText,#13,#13#10,[rfReplaceAll]); UpdateHintCaption;  exit; end;
  if (fDeviceList.Count > 0) then
    FindAddedPorts(OldPorts, fDeviceList,AddedPorts);
  FAddedPorts := UTF8StringReplace(AddedPorts.DelimitedText,#13,#13#10,[rfReplaceAll]);

  FRemovedPorts := UTF8StringReplace(RemovedPorts.DelimitedText,#13,#13#10,[rfReplaceAll]);

  if assigned(OldPorts) then OldPorts.Free;
  if assigned(AddedPorts) then AddedPorts.Free;
  if assigned(RemovedPorts) then RemovedPorts.Free;

  if (ssoAppendFriendlyNames in FOptions = True)
    then Items := fDeviceListFriend
    else Items := fDeviceList;

 if (CurrentPort <> '') then
    if (SearchStringList(fDeviceList,CurrentPort) > -1)
      then ItemIndex := SearchStringList(fDeviceList,CurrentPort);

  if (ItemIndex < 0) and (Items.Count  > 0) then ItemIndex := 0;
  Text := Items.Strings[ItemIndex];
  if (FHintWindow <> nil) then
    UpdateHint;
end;

procedure TSerialSelector.DoUpdateComPorts(Sender: TObject);
begin
  {$ifNdef windows}UpdatePorts;
  {$else}
  if (ssoUseWMI in FOptions) then
  begin
    FUpdatePortsThread := TUpdatePortsThread.Create(True); // This way it doesn't start automatically
    FUpdatePortsThread.Owner := Self;
    FUpdatePortsThread.Start;
  end
  else
     UpdatePorts;
  {$endif}
end;

function TSerialSelector.MouseIn: Boolean;
var
  MyPoint : TPoint;
begin
  MyPoint := ScreenToClient(Mouse.CursorPos);
  Result := PtInRect(ClientRect, MyPoint);
end;

//In Linux the hint might not be removed when the control is removed.
//Also applied for all OSes, just in case.
procedure TSerialSelector.DoOnRefreshTimer(Sender: TObject);
begin
  if not MouseIn then
    HideHint(Self);
end;

//TODO: The last added/removed device is lost when applying the change
procedure TSerialSelector.setOptions(Value: tSSOptionS);
begin
  FOptions := Value;
end;

constructor TSerialSelector.Create (aOwner: TComponent);
begin
  inherited Create(aOwner);
  ItemIndex := -1;
  fDevice := '';
  fDeviceList := TStringList.Create;
  fDeviceListFriend := TStringList.Create;
  FAddedPorts := '';
  FRemovedPorts := '';
  FOptions := [ssoAppendFriendlyNames,ssoUseWMI, ssoHide_tty_usbserial,ssoAppendSerialNumber];

  FRefreshTimer := TTimer.Create(Self) ;
  FRefreshTimer.Enabled := True;
  FRefreshTimer.Interval := 1000;
  FRefreshTimer.OnTimer := @DoOnRefreshTimer;

  Hint := '';
  FShowHint := True;
  ReadOnly := True;
  Text := '';
  OnMouseEnter := @DoMouseEnter;
  OnMouseLeave := @HideHint;
  OnGetItems := @HideHint;
  FSerialWatcher := TSerialWatcher.Create(Self);
  FSerialWatcher.OnComConnected    := @DoUpdateComPorts;
  FSerialWatcher.OnComDisconnected := @DoUpdateComPorts;
  Width := 256;
end;

//Begin HintRoutines
procedure TSerialSelector.UpdateHintCaption;
begin
  if (ItemIndex < 0) then exit; //Todo: How come that ItemIndex = -1 when the .Items are not empty‽
  FHintCaption := '';
  if (FHint = '') then
  begin
    if (fDeviceList.Count > 0)
      then FHintCaption := fDeviceListFriend.Strings[ItemIndex]
      else FHintCaption := lngNoDevicesAvailable;
    //Todo: Maybe there is bug in Linux: LineEnding + LineEnding is rendered as a single LineEnding
    if (FAddedPorts <> '') then
      FHintCaption := FHintCaption + LineEnding + ' ' + LineEnding + lngAddedPorts + LineEnding + FAddedPorts;
    if (FRemovedPorts <> '') then
      FHintCaption := FHintCaption + LineEnding + ' ' + LineEnding + lngRemovedPorts + LineEnding + FRemovedPorts;
  end
  else
    FHintCaption := FHint;
end;

//Shows the hint or updates it if shown
procedure TSerialSelector.UpdateHint;
var
  mRect : trect;
begin
  if not ShowHint then exit;
  if not MouseIn then exit;
  if (FHintWindow = nil) then
  begin
    FHintWindow:= THintWindow.Create(self);
    FRefreshTimer.Enabled := True;
  end;
  UpdateHintCaption;
  mRect := FHintWindow.CalcHintRect(0, FHintCaption ,nil);
  Offsetrect(mRect, Mouse.CursorPos.X,Mouse.CursorPos.Y + 4);
  FHintWindow.ActivateHint(mRect,FHintCaption);
end;

//Show the hint
procedure TSerialSelector.DoMouseEnter(Sender: TObject);
begin
  UpdateHint;
end;

procedure TSerialSelector.SetHint(const Value: string);
begin
  if (FHint = Value) then exit;
  FHint := Value;
  DoUpdateComPorts(self); //Todo: maybe this is not the best behaviour
end;

procedure TSerialSelector.SetShowHint(const Value: Boolean);
begin
  if (FShowHint = Value) then exit;
  FShowHint := Value;
  try
    if (FShowHint = True)
      then UpdateHintCaption
      else if (FHintWindow <> nil) then
       HideHint(self);
  finally
  end;
end;

procedure TSerialSelector.HideHint(Sender: TObject);
begin
  try
    {$ifNdef linux}
    FreeAndNil(FHintWindow);
    {$else}
    //Linux Mint Cinnamon crashes on FreeAndNil
    if (FHintWindow <> nil) then FHintWindow.Hide;
    {$endif}
  finally
//    FTimer.Enabled := False;
  end;
end;
//End HintRoutines

//Complete initialization after settings are loaded from the GUI
procedure TSerialSelector.Loaded;
begin
  inherited;
  DoUpdateComPorts(self);
end;

destructor TSerialSelector.Destroy;
begin
  if assigned(fDeviceList) then fDeviceList.Free;
  if assigned(fDeviceListFriend) then fDeviceListFriend.Free;
  if assigned(FHintWindow) then FHintWindow.Free;
  inherited;
end;


{TUpdatePortsThread}
{$ifdef windows}
constructor TUpdatePortsThread.Create(CreateSuspended : boolean);
begin
  inherited Create(CreateSuspended);
  FreeOnTerminate := True;
end;

procedure TUpdatePortsThread.Execute;
begin
  try
   CoInitialize(nil); //The app will crash without this
   //The first call of GetWMIInfo is slow. The next call is done in TriggerDisconnected, but it is not slow
   //Todo: maybe this is not reliable enough
   GetWMIInfo('Win32_PnPEntity',['Caption','DeviceID'],'WHERE Caption LIKE ''%%(COM%%)''',30); //usually this does not take more than 6 seconds, but 20 seconds are also observed
   Synchronize(@Owner.UpdatePorts);
  finally
    Terminate;
  end; //try
end;
{$endif} //windows
//End: Handle disconnect detection

procedure Register;
begin
  {$I serialselector_icon.lrs}
  RegisterComponents('LazSerial',[TSerialSelector]);
end;

initialization
{$i serialselector_icon.lrs}

end.
