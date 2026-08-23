unit LazSerialDeviceParsers;

{$mode ObjFPC}{$H+}

interface

uses
  LazSerialDevices;

function DecodeUdevEncodedValue(const AValue: string): string;

function ParseLinuxUdevProperties(
  const ADevice, AProperties: string
): TSerialDeviceInfo;

function ParseWindowsPnpDeviceId(
  const ADeviceId: string
): TSerialDeviceInfo;

function ParseWindowsWmiSnapshot(
  const ASnapshot: string
): TSerialDeviceInfoArray;

implementation

uses
  Classes, StrUtils, SysUtils;

function HexDigitValue(const AValue: Char): Integer;
begin
  case AValue of
    '0'..'9': Result := Ord(AValue) - Ord('0');
    'a'..'f': Result := Ord(AValue) - Ord('a') + 10;
    'A'..'F': Result := Ord(AValue) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function DecodeUdevEncodedValue(const AValue: string): string;
var
  FirstDigit: Integer;
  I: Integer;
  SecondDigit: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(AValue) do
  begin
    if (AValue[I] = '\') and (I + 3 <= Length(AValue)) and
      (AValue[I + 1] = 'x') then
    begin
      FirstDigit := HexDigitValue(AValue[I + 2]);
      SecondDigit := HexDigitValue(AValue[I + 3]);
      if (FirstDigit >= 0) and (SecondDigit >= 0) then
      begin
        Result := Result + Char((FirstDigit shl 4) or SecondDigit);
        Inc(I, 4);
        Continue;
      end;
    end;

    Result := Result + AValue[I];
    Inc(I);
  end;
end;

procedure ParsePropertyLines(const AProperties: string; AValues: TStrings);
var
  EqualPosition: Integer;
  I: Integer;
  Key: string;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AProperties;
    for I := 0 to Lines.Count - 1 do
    begin
      EqualPosition := Pos('=', Lines[I]);
      if EqualPosition <= 1 then
        Continue;

      Key := Trim(Copy(Lines[I], 1, EqualPosition - 1));
      if Key = '' then
        Continue;
      AValues.Values[Key] := Trim(Copy(
        Lines[I],
        EqualPosition + 1,
        MaxInt
      ));
    end;
  finally
    Lines.Free;
  end;
end;

function FirstNotEmpty(const AValues: TStrings;
  const ANames: array of string): string;
var
  I: Integer;
begin
  for I := Low(ANames) to High(ANames) do
  begin
    Result := Trim(AValues.Values[ANames[I]]);
    if Result <> '' then
      Exit;
  end;
  Result := '';
end;

function ParseUdevName(const AValues: TStrings;
  const ADatabaseName, AEncodedName, APlainName: string): string;
begin
  Result := Trim(AValues.Values[ADatabaseName]);
  if Result <> '' then
    Exit;

  Result := Trim(AValues.Values[AEncodedName]);
  if Result <> '' then
    Exit(DecodeUdevEncodedValue(Result));

  Result := StringReplace(
    Trim(AValues.Values[APlainName]),
    '_',
    ' ',
    [rfReplaceAll]
  );
end;

function ParseUsbId(const AValues: TStrings;
  const APrimaryName, AFallbackName: string): string;
begin
  Result := NormalizeUsbId(AValues.Values[APrimaryName]);
  if Result = '' then
    Result := NormalizeUsbId(AValues.Values[AFallbackName]);
end;

function FindPersistentId(const ADeviceLinks: string): string;
var
  I: Integer;
  Links: TStringList;
begin
  Result := '';
  Links := TStringList.Create;
  try
    ExtractStrings([' ', #9], [], PChar(ADeviceLinks), Links);
    for I := 0 to Links.Count - 1 do
      if Pos('/dev/serial/by-id/', Links[I]) = 1 then
        Exit(Links[I]);
  finally
    Links.Free;
  end;
end;

function ParseLinuxUdevProperties(
  const ADevice, AProperties: string
): TSerialDeviceInfo;
var
  Values: TStringList;
begin
  Result := Default(TSerialDeviceInfo);
  Result.Device := Trim(ADevice);

  Values := TStringList.Create;
  try
    Values.NameValueSeparator := '=';
    Values.CaseSensitive := True;
    ParsePropertyLines(AProperties, Values);

    Result.Vendor := ParseUdevName(
      Values,
      'ID_VENDOR_FROM_DATABASE',
      'ID_VENDOR_ENC',
      'ID_VENDOR'
    );
    Result.Model := ParseUdevName(
      Values,
      'ID_MODEL_FROM_DATABASE',
      'ID_MODEL_ENC',
      'ID_MODEL'
    );
    Result.SerialShort := FirstNotEmpty(
      Values,
      ['ID_SERIAL_SHORT', 'ID_USB_SERIAL_SHORT']
    );
    Result.VendorId := ParseUsbId(
      Values,
      'ID_VENDOR_ID',
      'ID_USB_VENDOR_ID'
    );
    Result.ProductId := ParseUsbId(
      Values,
      'ID_MODEL_ID',
      'ID_USB_MODEL_ID'
    );
    Result.PersistentId := FindPersistentId(Values.Values['DEVLINKS']);
  finally
    Values.Free;
  end;
end;

function FindWindowsUsbId(const ADeviceId, ATag: string): string;
var
  Position: Integer;
begin
  Position := Pos(ATag, UpperCase(ADeviceId));
  if Position = 0 then
    Exit('');
  Result := NormalizeUsbId(Copy(
    ADeviceId,
    Position + Length(ATag),
    4
  ));
end;

function ExtractWindowsSerialShort(const ADeviceId: string): string;
var
  Candidate: string;
  HardwareId: string;
  LastSeparator: Integer;
  NextSeparator: Integer;
  UpperDeviceId: string;
begin
  Result := '';
  UpperDeviceId := UpperCase(ADeviceId);
  if StartsStr('FTDIBUS\', UpperDeviceId) then
  begin
    HardwareId := Copy(ADeviceId, Length('FTDIBUS\') + 1, MaxInt);
    NextSeparator := Pos('\', HardwareId);
    if NextSeparator > 0 then
      SetLength(HardwareId, NextSeparator - 1);
    LastSeparator := RPos('+', HardwareId);
    if LastSeparator = 0 then
      Exit;
    Candidate := Copy(HardwareId, LastSeparator + 1, MaxInt);
    if EndsText('A', Candidate) then
      Delete(Candidate, Length(Candidate), 1);
    Exit(Trim(Candidate));
  end;

  LastSeparator := RPos('\', ADeviceId);
  if LastSeparator = 0 then
    Exit;
  Candidate := Trim(Copy(ADeviceId, LastSeparator + 1, MaxInt));
  if (Candidate = '') or (Pos('&', Candidate) > 0) then
    Exit;
  Result := Candidate;
end;

function ParseWindowsPnpDeviceId(
  const ADeviceId: string
): TSerialDeviceInfo;
var
  DeviceId: string;
begin
  Result := Default(TSerialDeviceInfo);
  DeviceId := Trim(ADeviceId);
  Result.PersistentId := DeviceId;
  Result.VendorId := FindWindowsUsbId(DeviceId, 'VID_');
  Result.ProductId := FindWindowsUsbId(DeviceId, 'PID_');
  Result.SerialShort := ExtractWindowsSerialShort(DeviceId);
end;

function TryParseWindowsComCaption(
  const ACaption: string;
  out ADevice, AModel: string
): Boolean;
var
  Caption: string;
  I: Integer;
  OpenParenthesis: Integer;
  PortName: string;
begin
  ADevice := '';
  AModel := '';
  Caption := Trim(ACaption);
  OpenParenthesis := RPos('(', Caption);
  if (OpenParenthesis <= 0) or not EndsStr(')', Caption) then
    Exit(False);

  PortName := UpperCase(Copy(
    Caption,
    OpenParenthesis + 1,
    Length(Caption) - OpenParenthesis - 1
  ));
  if (Length(PortName) < 4) or not StartsStr('COM', PortName) then
    Exit(False);
  for I := 4 to Length(PortName) do
    if not (PortName[I] in ['0'..'9']) then
      Exit(False);

  ADevice := PortName;
  AModel := Trim(Copy(Caption, 1, OpenParenthesis - 1));
  Result := True;
end;

procedure AddSerialDevice(
  var ADevices: TSerialDeviceInfoArray;
  const ADevice: TSerialDeviceInfo
);
var
  NewIndex: Integer;
begin
  NewIndex := Length(ADevices);
  SetLength(ADevices, NewIndex + 1);
  ADevices[NewIndex] := ADevice;
end;

function ParseWindowsWmiSnapshot(
  const ASnapshot: string
): TSerialDeviceInfoArray;
var
  EqualPosition: Integer;
  I: Integer;
  Key: string;
  Lines: TStringList;
  PnpDevice: TSerialDeviceInfo;
  PnpDeviceId: string;
  Values: TStringList;

  procedure FlushRecord;
  var
    Device: TSerialDeviceInfo;
  begin
    if Values.Count = 0 then
      Exit;

    Device := Default(TSerialDeviceInfo);
    if not TryParseWindowsComCaption(
      Values.Values['Caption'],
      Device.Device,
      Device.Model
    ) then
    begin
      Values.Clear;
      Exit;
    end;

    Device.Vendor := Trim(Values.Values['Manufacturer']);
    Device.ErrorCode := Trim(Values.Values['ConfigManagerErrorCode']);
    PnpDeviceId := FirstNotEmpty(
      Values,
      ['PNPDeviceID', 'DeviceID']
    );
    PnpDevice := ParseWindowsPnpDeviceId(PnpDeviceId);
    Device.VendorId := PnpDevice.VendorId;
    Device.ProductId := PnpDevice.ProductId;
    Device.SerialShort := PnpDevice.SerialShort;
    Device.PersistentId := PnpDevice.PersistentId;
    AddSerialDevice(Result, Device);
    Values.Clear;
  end;

begin
  Result := nil;
  Lines := TStringList.Create;
  Values := TStringList.Create;
  try
    Lines.Text := ASnapshot;
    Values.NameValueSeparator := '=';
    Values.CaseSensitive := False;
    for I := 0 to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then
      begin
        FlushRecord;
        Continue;
      end;

      EqualPosition := Pos('=', Lines[I]);
      if EqualPosition <= 1 then
        Continue;
      Key := Trim(Copy(Lines[I], 1, EqualPosition - 1));
      if Key <> '' then
        Values.Values[Key] := Trim(Copy(
          Lines[I],
          EqualPosition + 1,
          MaxInt
        ));
    end;
    FlushRecord;
  finally
    Values.Free;
    Lines.Free;
  end;
end;

end.
