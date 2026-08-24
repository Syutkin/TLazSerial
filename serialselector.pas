// Introduced in v0.7 by СМ630 2025÷2026
unit SerialSelector;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, LResources, Forms, Controls, StdCtrls, Graphics, Types,
  ExtCtrls, SerialWatcher, LazSerialDevices, SerialDeviceRefresh;

type
  TSerialSelector = class(TCustomComboBox)
  private
    FAllowCustomDevice: Boolean;
    FDevices: TSerialDeviceInfoArray;
    FRequestedDevice: string;
    FSerialWatcher: TSerialWatcher;
    FHintWindow: THintWindow;
    FAddedPorts: string;
    FRemovedPorts: string;
    FShowHint: Boolean;
    FHint: string;
    FHintCaption: string;
    FShowFriendlyName: Boolean;
    FDisplayOptions: TSerialDeviceDisplayOptions;
    FRefreshTimer: TTimer;
    FDeviceRefreshThread: TSerialDeviceRefreshThread;
    function GetDevice: string;
    function GetDeviceCount: Integer;
    function GetDeviceInfo(const AIndex: Integer): TSerialDeviceInfo;
    procedure ApplyCustomDeviceMode;
    procedure SetAllowCustomDevice(const AValue: Boolean);
    procedure SetDevice(const AValue: string);
    procedure SetDisplayOptions(const AValue: TSerialDeviceDisplayOptions);
    procedure SetShowFriendlyName(const AValue: Boolean);
    function MouseIn: Boolean;
    procedure DoMouseEnter(Sender: TObject);
    procedure DoUpdateComPorts(Sender: TObject);
    procedure DoOnRefreshTimer(Sender: TObject);
    procedure HideHint(Sender: TObject);
    procedure SetSelectorHint(const AValue: string);
    procedure SetShowHint(const AValue: Boolean);
    procedure RebuildItems(const ASelectedDevice: string);
    procedure UpdatePortChanges(const AOldDevices: TSerialDeviceInfoArray);
    property Items;
  protected
    procedure ApplyDevices(const ADevices: TSerialDeviceInfoArray); virtual;
    function BackgroundRefreshFinished: Boolean;
    function BuildHintCaption: string;
    function LoadDevices: TSerialDeviceInfoArray; virtual;
    procedure StartBackgroundRefresh;
    function UseBackgroundRefresh: Boolean; virtual;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function TryGetSelectedDevice(out ADevice: TSerialDeviceInfo): Boolean;
    procedure Refresh;
    procedure UpdateHint;
    procedure UpdateHintCaption;
    property Device: string read GetDevice write SetDevice;
    property DeviceCount: Integer read GetDeviceCount;
    property Devices[const AIndex: Integer]: TSerialDeviceInfo
      read GetDeviceInfo;
    property Text;
  published
    property AllowCustomDevice: Boolean
      read FAllowCustomDevice write SetAllowCustomDevice default False;
    property ShowFriendlyName: Boolean
      read FShowFriendlyName write SetShowFriendlyName default True;
    property DisplayOptions: TSerialDeviceDisplayOptions
      read FDisplayOptions write SetDisplayOptions
      default DefaultSerialDeviceDisplayOptions;

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
    property Hint: string read FHint write SetSelectorHint;
    property ItemHeight;
    property ItemWidth;
    property MaxLength;
    property ParentBidiMode;
    property ParentColor;
    property ParentDoubleBuffered;
    property ParentFont;
    property ParentShowHint;
    property PopupMenu;
    property ShowHint: Boolean read FShowHint write SetShowHint default True;
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

procedure Register;

implementation

uses
  LazSerialCommon;

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

function DeviceChanges(
  const ASource, AReference: TSerialDeviceInfoArray
): string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(ASource) to High(ASource) do
    if not ContainsSerialDevice(AReference, ASource[I].Device) then
    begin
      if Result <> '' then
        Result := Result + LineEnding;
      Result := Result + ASource[I].Device;
    end;
end;

function TSerialSelector.GetDevice: string;
begin
  if (ItemIndex >= Low(FDevices)) and (ItemIndex <= High(FDevices)) then
    Result := FDevices[ItemIndex].Device
  else if FAllowCustomDevice then
    Result := Text
  else
    Result := '';
end;

function TSerialSelector.GetDeviceCount: Integer;
begin
  Result := Length(FDevices);
end;

function TSerialSelector.GetDeviceInfo(
  const AIndex: Integer
): TSerialDeviceInfo;
begin
  if (AIndex < Low(FDevices)) or (AIndex > High(FDevices)) then
    raise EListError.CreateFmt('Serial device index %d out of bounds', [AIndex]);
  Result := FDevices[AIndex];
end;

procedure TSerialSelector.ApplyCustomDeviceMode;
begin
  if FAllowCustomDevice then
  begin
    Style := csDropDown;
    ReadOnly := False;
  end
  else
    ReadOnly := True;
end;

procedure TSerialSelector.SetAllowCustomDevice(const AValue: Boolean);
var
  SelectedDevice: string;
begin
  if FAllowCustomDevice = AValue then
  begin
    ApplyCustomDeviceMode;
    Exit;
  end;

  SelectedDevice := Device;
  if SelectedDevice = '' then
    SelectedDevice := FRequestedDevice;
  FAllowCustomDevice := AValue;
  ApplyCustomDeviceMode;
  RebuildItems(SelectedDevice);
end;

procedure TSerialSelector.SetDevice(const AValue: string);
var
  Index: Integer;
begin
  FRequestedDevice := AValue;
  Index := IndexOfSerialDevice(FDevices, AValue);
  if Index >= 0 then
  begin
    ItemIndex := Index
  end
  else
  begin
    ItemIndex := -1;
    if FAllowCustomDevice then
      Text := AValue
    else
      Text := '';
  end;
  SelLength := 0;
end;

procedure TSerialSelector.SetDisplayOptions(
  const AValue: TSerialDeviceDisplayOptions
);
var
  SelectedDevice: string;
begin
  if FDisplayOptions = AValue then
    Exit;
  SelectedDevice := Device;
  FDisplayOptions := AValue;
  RebuildItems(SelectedDevice);
end;

procedure TSerialSelector.SetShowFriendlyName(const AValue: Boolean);
var
  SelectedDevice: string;
begin
  if FShowFriendlyName = AValue then
    Exit;
  SelectedDevice := Device;
  FShowFriendlyName := AValue;
  RebuildItems(SelectedDevice);
end;

function TSerialSelector.LoadDevices: TSerialDeviceInfoArray;
begin
  Result := GetSerialDevices;
end;

procedure TSerialSelector.RebuildItems(const ASelectedDevice: string);
var
  I: Integer;
  SelectedIndex: Integer;
begin
  Sorted := False;
  Items.BeginUpdate;
  try
    Items.Clear;
    for I := Low(FDevices) to High(FDevices) do
      if FShowFriendlyName then
        Items.Add(FormatSerialDeviceDisplayName(FDevices[I], FDisplayOptions))
      else
        Items.Add(FDevices[I].Device);
  finally
    Items.EndUpdate;
  end;

  SelectedIndex := IndexOfSerialDevice(FDevices, ASelectedDevice);
  if (SelectedIndex < 0) and
    not (FAllowCustomDevice and (ASelectedDevice <> '')) and
    (Length(FDevices) > 0) then
    SelectedIndex := 0;
  ItemIndex := SelectedIndex;

  if ItemIndex >= 0 then
  begin
    FRequestedDevice := FDevices[ItemIndex].Device;
    Text := Items[ItemIndex];
  end
  else if FAllowCustomDevice then
  begin
    FRequestedDevice := ASelectedDevice;
    Text := ASelectedDevice;
  end
  else
    Text := '';
  SelLength := 0;
end;

procedure TSerialSelector.UpdatePortChanges(
  const AOldDevices: TSerialDeviceInfoArray
);
begin
  FAddedPorts := DeviceChanges(FDevices, AOldDevices);
  FRemovedPorts := DeviceChanges(AOldDevices, FDevices);
end;

procedure TSerialSelector.Refresh;
begin
  if UseBackgroundRefresh then
    StartBackgroundRefresh
  else
    ApplyDevices(LoadDevices);
end;

procedure TSerialSelector.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray
);
var
  OldDevices: TSerialDeviceInfoArray;
  SelectedDevice: string;
begin
  SelectedDevice := Device;
  if (SelectedDevice = '') and not FAllowCustomDevice then
    SelectedDevice := FRequestedDevice;
  OldDevices := CopyDevices(FDevices);
  FDevices := CopyDevices(ADevices);
  FSerialWatcher.AdoptSnapshot(FDevices);
  UpdatePortChanges(OldDevices);
  RebuildItems(SelectedDevice);
  if FHintWindow <> nil then
    UpdateHint;
end;

function TSerialSelector.UseBackgroundRefresh: Boolean;
begin
  Result := True;
end;

function TSerialSelector.BackgroundRefreshFinished: Boolean;
begin
  Result := (FDeviceRefreshThread = nil) or
    FDeviceRefreshThread.Finished;
end;

procedure TSerialSelector.StartBackgroundRefresh;
begin
  if FDeviceRefreshThread <> nil then
  begin
    if not FDeviceRefreshThread.Finished or
      FDeviceRefreshThread.Delivering then
      Exit;
    CancelSerialDeviceRefresh(FDeviceRefreshThread);
  end;

  FDeviceRefreshThread := TSerialDeviceRefreshThread.Create(
    @LoadDevices,
    @ApplyDevices
  );
  FDeviceRefreshThread.Start;
end;

procedure TSerialSelector.DoUpdateComPorts(Sender: TObject);
begin
  Refresh;
end;

function TSerialSelector.MouseIn: Boolean;
var
  MousePoint: TPoint;
begin
  MousePoint := ScreenToClient(Mouse.CursorPos);
  Result := PtInRect(ClientRect, MousePoint);
end;

procedure TSerialSelector.DoOnRefreshTimer(Sender: TObject);
begin
  if not MouseIn then
    HideHint(Self);
end;

constructor TSerialSelector.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAllowCustomDevice := False;
  FDevices := nil;
  FRequestedDevice := '';
  FAddedPorts := '';
  FRemovedPorts := '';
  FShowFriendlyName := True;
  FDisplayOptions := DefaultSerialDeviceDisplayOptions;
  FShowHint := True;
  FHint := '';
  FDeviceRefreshThread := nil;

  Sorted := False;
  ItemIndex := -1;
  ApplyCustomDeviceMode;
  Text := '';
  Width := 256;

  FRefreshTimer := TTimer.Create(Self);
  FRefreshTimer.Enabled := True;
  FRefreshTimer.Interval := 1000;
  FRefreshTimer.OnTimer := @DoOnRefreshTimer;

  OnMouseEnter := @DoMouseEnter;
  OnMouseLeave := @HideHint;
  FSerialWatcher := TSerialWatcher.Create(Self);
  FSerialWatcher.RefreshOnLoaded := False;
  FSerialWatcher.OnComConnected := @DoUpdateComPorts;
  FSerialWatcher.OnComDisconnected := @DoUpdateComPorts;
end;

function TSerialSelector.TryGetSelectedDevice(
  out ADevice: TSerialDeviceInfo
): Boolean;
begin
  Result := (ItemIndex >= Low(FDevices)) and (ItemIndex <= High(FDevices));
  if Result then
    ADevice := FDevices[ItemIndex]
  else
    ADevice := Default(TSerialDeviceInfo);
end;

function TSerialSelector.BuildHintCaption: string;
begin
  if FHint <> '' then
    Result := FHint
  else if (ItemIndex >= Low(FDevices)) and (ItemIndex <= High(FDevices)) then
    Result := FormatSerialDeviceDisplayName(
      FDevices[ItemIndex],
      DefaultSerialDeviceDisplayOptions
    )
  else if FAllowCustomDevice and (Device <> '') then
    Result := Format(lngManualDevice, [Device])
  else
    Result := lngNoDevicesAvailable;

  if FHint = '' then
  begin
    if FAddedPorts <> '' then
      Result := Result + LineEnding + ' ' + LineEnding +
        lngAddedPorts + LineEnding + FAddedPorts;
    if FRemovedPorts <> '' then
      Result := Result + LineEnding + ' ' + LineEnding +
        lngRemovedPorts + LineEnding + FRemovedPorts;
  end;
end;

procedure TSerialSelector.UpdateHintCaption;
begin
  FHintCaption := BuildHintCaption;
end;

procedure TSerialSelector.UpdateHint;
var
  HintRect: TRect;
begin
  if not ShowHint or not MouseIn then
    Exit;
  if FHintWindow = nil then
  begin
    FHintWindow := THintWindow.Create(Self);
    FRefreshTimer.Enabled := True;
  end;
  UpdateHintCaption;
  HintRect := FHintWindow.CalcHintRect(0, FHintCaption, nil);
  OffsetRect(HintRect, Mouse.CursorPos.X, Mouse.CursorPos.Y + 4);
  FHintWindow.ActivateHint(HintRect, FHintCaption);
end;

procedure TSerialSelector.DoMouseEnter(Sender: TObject);
begin
  UpdateHint;
end;

procedure TSerialSelector.SetSelectorHint(const AValue: string);
begin
  if FHint = AValue then
    Exit;
  FHint := AValue;
  UpdateHintCaption;
  if FHintWindow <> nil then
    UpdateHint;
end;

procedure TSerialSelector.SetShowHint(const AValue: Boolean);
begin
  if FShowHint = AValue then
    Exit;
  FShowHint := AValue;
  if FShowHint then
    UpdateHintCaption
  else if FHintWindow <> nil then
    HideHint(Self);
end;

procedure TSerialSelector.HideHint(Sender: TObject);
begin
  {$IFNDEF Linux}
  FreeAndNil(FHintWindow);
  {$ELSE}
  // Linux Mint Cinnamon crashes when a visible THintWindow is freed here.
  if FHintWindow <> nil then
    FHintWindow.Hide;
  {$ENDIF}
end;

procedure TSerialSelector.Loaded;
begin
  inherited Loaded;
  ApplyCustomDeviceMode;
  if not (csDesigning in ComponentState) then
    Refresh;
end;

destructor TSerialSelector.Destroy;
begin
  FSerialWatcher.OnComConnected := nil;
  FSerialWatcher.OnComDisconnected := nil;
  CancelSerialDeviceRefresh(FDeviceRefreshThread);
  FreeAndNil(FHintWindow);
  inherited Destroy;
end;

procedure Register;
begin
  {$I serialselector_icon.lrs}
  RegisterComponents('LazSerial', [TSerialSelector]);
end;

initialization
  {$I serialselector_icon.lrs}

end.
