// Introduced in v0.7 by СМ630 2025÷2026
unit SerialSelector;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, LResources, Controls, StdCtrls,
  SerialWatcher, LazSerialDevices;

type
  TSerialSelector = class(TCustomComboBox)
  private
    FAllowCustomDevice: Boolean;
    FDevices: TSerialDeviceInfoArray;
    FRequestedDevice: string;
    FSerialWatcher: TSerialWatcher;
    FAddedPorts: string;
    FRemovedPorts: string;
    FHint: string;
    FShowFriendlyName: Boolean;
    FDisplayOptions: TSerialDeviceDisplayOptions;
    function GetDevice: string;
    function GetDeviceCount: Integer;
    function GetDeviceInfo(const AIndex: Integer): TSerialDeviceInfo;
    procedure ApplyCustomDeviceMode;
    procedure SetAllowCustomDevice(const AValue: Boolean);
    procedure SetDevice(const AValue: string);
    procedure SetDisplayOptions(const AValue: TSerialDeviceDisplayOptions);
    procedure SetShowFriendlyName(const AValue: Boolean);
    procedure DevicesRefreshed(Sender: TObject;
      const ADevices: TSerialDeviceInfoArray);
    procedure SetSelectorHint(const AValue: string);
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
    procedure DoOnShowHint(HintInfo: PHintInfo); override;
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
    property ShowHint default True;
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

type
  // Keep the selector's virtual loader hook, but let the watcher own the only
  // refresh worker, retry policy and hotplug snapshot.
  TSelectorSerialWatcher = class(TSerialWatcher)
  private
    FSelector: TSerialSelector;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    constructor Create(ASelector: TSerialSelector); reintroduce;
    function RefreshFinished: Boolean;
    procedure RefreshSynchronously;
  end;

constructor TSelectorSerialWatcher.Create(ASelector: TSerialSelector);
begin
  inherited Create(ASelector);
  FSelector := ASelector;
  RefreshOnLoaded := False;
end;

function TSelectorSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
begin
  Result := FSelector.LoadDevices;
end;

function TSelectorSerialWatcher.RefreshFinished: Boolean;
begin
  Result := BackgroundRefreshFinished;
end;

procedure TSelectorSerialWatcher.RefreshSynchronously;
begin
  StartWatching;
  PollDevices;
end;

function SameDevices(const ALeft, ARight: TSerialDeviceInfoArray): Boolean;
var
  I: Integer;
begin
  if Length(ALeft) <> Length(ARight) then
    Exit(False);
  for I := Low(ALeft) to High(ALeft) do
    if (ALeft[I].Device <> ARight[I].Device) or
      (ALeft[I].Vendor <> ARight[I].Vendor) or
      (ALeft[I].Model <> ARight[I].Model) or
      (ALeft[I].SerialShort <> ARight[I].SerialShort) or
      (ALeft[I].VendorId <> ARight[I].VendorId) or
      (ALeft[I].ProductId <> ARight[I].ProductId) or
      (ALeft[I].PersistentId <> ARight[I].PersistentId) or
      (ALeft[I].ErrorCode <> ARight[I].ErrorCode) then
      Exit(False);
  Result := True;
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
  UpdateHintCaption;
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
  UpdateHintCaption;
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
    TSelectorSerialWatcher(FSerialWatcher).RefreshSynchronously;
end;

procedure TSerialSelector.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray
);
var
  OldDevices: TSerialDeviceInfoArray;
  SelectedDevice: string;
begin
  // Polling may deliver the same snapshot repeatedly. Leave the editable text
  // and the last port-change hint alone until the actual records change.
  if SameDevices(FDevices, ADevices) then
  begin
    // A non-editable selector still restores its normal fallback selection
    // after an unknown Device was assigned, even if the ports did not change.
    if not FAllowCustomDevice and (Length(FDevices) > 0) and
      ((ItemIndex < 0) or (ItemIndex >= Length(FDevices))) then
      RebuildItems(FRequestedDevice);
    Exit;
  end;
  SelectedDevice := Device;
  if (SelectedDevice = '') and not FAllowCustomDevice then
    SelectedDevice := FRequestedDevice;
  OldDevices := FDevices;
  FDevices := Copy(ADevices, 0, Length(ADevices));
  UpdatePortChanges(OldDevices);
  RebuildItems(SelectedDevice);
end;

function TSerialSelector.UseBackgroundRefresh: Boolean;
begin
  Result := True;
end;

function TSerialSelector.BackgroundRefreshFinished: Boolean;
begin
  Result := TSelectorSerialWatcher(FSerialWatcher).RefreshFinished;
end;

procedure TSerialSelector.StartBackgroundRefresh;
begin
  FSerialWatcher.Refresh;
end;

procedure TSerialSelector.DevicesRefreshed(Sender: TObject;
  const ADevices: TSerialDeviceInfoArray);
begin
  ApplyDevices(ADevices);
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
  ShowHint := True;
  FHint := '';

  Sorted := False;
  ItemIndex := -1;
  ApplyCustomDeviceMode;
  Text := '';
  Width := 256;

  FSerialWatcher := TSelectorSerialWatcher.Create(Self);
  FSerialWatcher.OnDevicesRefreshed := @DevicesRefreshed;
  UpdateHintCaption;
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
      FDisplayOptions
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
  inherited Hint := BuildHintCaption;
end;

procedure TSerialSelector.UpdateHint;
begin
  UpdateHintCaption;
end;

procedure TSerialSelector.DoOnShowHint(HintInfo: PHintInfo);
begin
  HintInfo^.HintStr := BuildHintCaption;
  inherited DoOnShowHint(HintInfo);
end;

procedure TSerialSelector.SetSelectorHint(const AValue: string);
begin
  if FHint = AValue then
    Exit;
  FHint := AValue;
  UpdateHintCaption;
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
  if FSerialWatcher <> nil then
  begin
    FSerialWatcher.OnDevicesRefreshed := nil;
    // The worker calls the selector's virtual LoadDevices. Join it before
    // destroying any selector state, including during snapshot delivery.
    FreeAndNil(FSerialWatcher);
  end;
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
