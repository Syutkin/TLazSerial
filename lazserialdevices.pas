unit LazSerialDevices;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

type
  TSerialDeviceInfo = record
    Device: string;
    Vendor: string;
    Model: string;
    SerialShort: string;
    VendorId: string;
    ProductId: string;
    PersistentId: string;
    ErrorCode: string;
  end;

  TSerialDeviceInfoArray = array of TSerialDeviceInfo;

  TSerialDeviceEnumerationOption = (
    sdeoAccessibleOnly
  );
  TSerialDeviceEnumerationOptions = set of TSerialDeviceEnumerationOption;

  TSerialDeviceDisplayOption = (
    sddoVendor,
    sddoModel,
    sddoSerialShort,
    sddoErrorCode
  );
  TSerialDeviceDisplayOptions = set of TSerialDeviceDisplayOption;

const
  DefaultSerialDeviceDisplayOptions = [
    sddoVendor,
    sddoModel,
    sddoSerialShort,
    sddoErrorCode
  ];

function GetSerialDevices(
  const AOptions: TSerialDeviceEnumerationOptions = []
): TSerialDeviceInfoArray;

function IndexOfSerialDevice(
  const ADevices: TSerialDeviceInfoArray;
  const ADevice: string
): Integer;

function ContainsSerialDevice(
  const ADevices: TSerialDeviceInfoArray;
  const ADevice: string
): Boolean;

function NormalizeUsbId(const AValue: string): string;

function FormatSerialDeviceFriendlyName(
  const ADevice: TSerialDeviceInfo;
  const AOptions: TSerialDeviceDisplayOptions =
    DefaultSerialDeviceDisplayOptions
): string;

function FormatSerialDeviceDisplayName(
  const ADevice: TSerialDeviceInfo;
  const AOptions: TSerialDeviceDisplayOptions =
    DefaultSerialDeviceDisplayOptions
): string;

implementation

uses
  LazSerialDeviceCollectors;

resourcestring
  SSerialDeviceErrorCode = 'error %s';

function GetSerialDevices(
  const AOptions: TSerialDeviceEnumerationOptions
): TSerialDeviceInfoArray;
{$IFDEF Linux}
var
  Collector: TLinuxSerialDeviceCollector;
{$ELSE}
{$IFDEF Windows}
var
  Collector: TWindowsSerialDeviceCollector;
{$ENDIF}
{$ENDIF}
begin
  {$IFDEF Linux}
  Collector := TLinuxSerialDeviceCollector.Create;
  try
    Result := Collector.Collect(AOptions);
  finally
    Collector.Free;
  end;
  {$ELSE}
  {$IFDEF Windows}
  Collector := TWindowsSerialDeviceCollector.Create;
  try
    Result := Collector.Collect(AOptions);
  finally
    Collector.Free;
  end;
  {$ELSE}
  Result := nil;
  {$ENDIF}
  {$ENDIF}
end;

function IndexOfSerialDevice(
  const ADevices: TSerialDeviceInfoArray;
  const ADevice: string
): Integer;
var
  I: Integer;
begin
  for I := Low(ADevices) to High(ADevices) do
  begin
    {$IFDEF Windows}
    if CompareText(ADevices[I].Device, ADevice) = 0 then
    {$ELSE}
    if CompareStr(ADevices[I].Device, ADevice) = 0 then
    {$ENDIF}
      Exit(I);
  end;
  Result := -1;
end;

function ContainsSerialDevice(
  const ADevices: TSerialDeviceInfoArray;
  const ADevice: string
): Boolean;
begin
  Result := IndexOfSerialDevice(ADevices, ADevice) >= 0;
end;

procedure AppendPart(var ATarget: string; const APart: string);
var
  Part: string;
begin
  Part := Trim(APart);
  if Part = '' then
    Exit;

  if ATarget <> '' then
    ATarget := ATarget + ' ';
  ATarget := ATarget + Part;
end;

function TextStartsWith(const AText, APrefix: string): Boolean;
begin
  Result :=
    (APrefix <> '') and
    (Length(AText) >= Length(APrefix)) and
    (CompareText(Copy(AText, 1, Length(APrefix)), APrefix) = 0);
end;

function IsHexDigit(const AValue: Char): Boolean;
begin
  Result :=
    ((AValue >= '0') and (AValue <= '9')) or
    ((AValue >= 'a') and (AValue <= 'f'));
end;

function NormalizeUsbId(const AValue: string): string;
var
  I: Integer;
  Value: string;
begin
  Value := LowerCase(Trim(AValue));

  if TextStartsWith(Value, 'vid_') or TextStartsWith(Value, 'pid_') then
    Delete(Value, 1, 4);
  if TextStartsWith(Value, '0x') then
    Delete(Value, 1, 2);

  if (Length(Value) < 1) or (Length(Value) > 4) then
    Exit('');

  for I := 1 to Length(Value) do
    if not IsHexDigit(Value[I]) then
      Exit('');

  Result := StringOfChar('0', 4 - Length(Value)) + Value;
end;

function FormatSerialDeviceFriendlyName(
  const ADevice: TSerialDeviceInfo;
  const AOptions: TSerialDeviceDisplayOptions
): string;
var
  ErrorCode: string;
  ErrorNumber: Int64;
  Model: string;
  Vendor: string;
begin
  Result := '';
  Vendor := Trim(ADevice.Vendor);
  Model := Trim(ADevice.Model);

  if (sddoVendor in AOptions) and
    not ((sddoModel in AOptions) and TextStartsWith(Model, Vendor)) then
    AppendPart(Result, Vendor);
  if sddoModel in AOptions then
    AppendPart(Result, Model);
  if sddoSerialShort in AOptions then
    AppendPart(Result, ADevice.SerialShort);

  if sddoErrorCode in AOptions then
  begin
    ErrorCode := Trim(ADevice.ErrorCode);
    if (ErrorCode <> '') and
      (not TryStrToInt64(ErrorCode, ErrorNumber) or (ErrorNumber <> 0)) then
      AppendPart(Result, Format(SSerialDeviceErrorCode, [ErrorCode]));
  end;
end;

function FormatSerialDeviceDisplayName(
  const ADevice: TSerialDeviceInfo;
  const AOptions: TSerialDeviceDisplayOptions
): string;
var
  Device: string;
  FriendlyName: string;
begin
  Device := Trim(ADevice.Device);
  FriendlyName := FormatSerialDeviceFriendlyName(ADevice, AOptions);

  if FriendlyName = '' then
    Exit(Device);
  if Device = '' then
    Exit(FriendlyName);
  Result := Device + ' <' + FriendlyName + '>';
end;

end.
