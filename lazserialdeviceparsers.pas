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

function ParseMacOSSystemProfilerDevice(
  const ADevice, ASnapshot: string
): TSerialDeviceInfo;

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

type
  TMacOSProfilerSection = record
    LocationId: string;
    Manufacturer: string;
    Model: string;
    ProductId: string;
    SerialNumber: string;
    VendorDescription: string;
    VendorId: string;
  end;

  TMacOSProfilerSections = array of TMacOSProfilerSection;

procedure AddMacOSProfilerSection(
  var ASections: TMacOSProfilerSections;
  const ASection: TMacOSProfilerSection
);
var
  NewIndex: Integer;
begin
  NewIndex := Length(ASections);
  SetLength(ASections, NewIndex + 1);
  ASections[NewIndex] := ASection;
end;

function ExtractParenthesizedText(const AValue: string): string;
var
  CloseParenthesis: Integer;
  OpenParenthesis: Integer;
begin
  Result := '';
  OpenParenthesis := Pos('(', AValue);
  CloseParenthesis := RPos(')', AValue);
  if (OpenParenthesis > 0) and (CloseParenthesis > OpenParenthesis) then
    Result := Trim(Copy(
      AValue,
      OpenParenthesis + 1,
      CloseParenthesis - OpenParenthesis - 1
    ));
end;

function ParseProfilerUsbId(const AValue: string): string;
var
  EndPosition: Integer;
  Value: string;
begin
  Value := Trim(AValue);
  EndPosition := Pos(' ', Value);
  if EndPosition > 0 then
    SetLength(Value, EndPosition - 1);
  Result := NormalizeUsbId(Value);
end;

function ParseMacOSProfilerSections(
  const ASnapshot: string
): TMacOSProfilerSections;
var
  ColonPosition: Integer;
  Current: TMacOSProfilerSection;
  HasCurrent: Boolean;
  I: Integer;
  Key: string;
  Lines: TStringList;
  TrimmedLine: string;
  Value: string;

  procedure FlushCurrent;
  begin
    if HasCurrent then
      AddMacOSProfilerSection(Result, Current);
    Current := Default(TMacOSProfilerSection);
    HasCurrent := False;
  end;

begin
  Result := nil;
  Current := Default(TMacOSProfilerSection);
  HasCurrent := False;
  Lines := TStringList.Create;
  try
    Lines.Text := ASnapshot;
    for I := 0 to Lines.Count - 1 do
    begin
      TrimmedLine := Trim(Lines[I]);
      if TrimmedLine = '' then
        Continue;
      ColonPosition := Pos(':', TrimmedLine);
      if ColonPosition = Length(TrimmedLine) then
      begin
        FlushCurrent;
        Current.Model := Trim(Copy(
          TrimmedLine,
          1,
          ColonPosition - 1
        ));
        HasCurrent := True;
        Continue;
      end;
      if (ColonPosition <= 1) or not HasCurrent then
        Continue;

      Key := LowerCase(Trim(Copy(
        TrimmedLine,
        1,
        ColonPosition - 1
      )));
      Value := Trim(Copy(TrimmedLine, ColonPosition + 1, MaxInt));
      case Key of
        'manufacturer': Current.Manufacturer := Value;
        'serial number': Current.SerialNumber := Value;
        'location id': Current.LocationId := Value;
        'product id': Current.ProductId := ParseProfilerUsbId(Value);
        'vendor id':
          begin
            Current.VendorId := ParseProfilerUsbId(Value);
            Current.VendorDescription := ExtractParenthesizedText(Value);
          end;
      end;
    end;
    FlushCurrent;
  finally
    Lines.Free;
  end;
end;

function MacOSDeviceToken(const ADevice: string): string;
const
  UsbModem = 'usbmodem';
  UsbSerial = 'usbserial';
var
  DeviceName: string;
  Position: Integer;
begin
  DeviceName := ExtractFileName(Trim(ADevice));
  Position := Pos(UsbSerial, LowerCase(DeviceName));
  if Position > 0 then
    Result := Copy(DeviceName, Position + Length(UsbSerial), MaxInt)
  else
  begin
    Position := Pos(UsbModem, LowerCase(DeviceName));
    if Position > 0 then
      Result := Copy(DeviceName, Position + Length(UsbModem), MaxInt)
    else
    begin
      Position := RPos('-', DeviceName);
      if Position > 0 then
        Result := Copy(DeviceName, Position + 1, MaxInt)
      else
        Result := Copy(DeviceName, RPos('.', DeviceName) + 1, MaxInt);
    end;
  end;

  Result := Trim(Result);
  while (Result <> '') and (Result[1] in ['-', '_', '.']) do
    Delete(Result, 1, 1);
end;

function NormalizeMacOSLocationId(const AValue: string): string;
var
  EndPosition: Integer;
begin
  Result := LowerCase(Trim(AValue));
  EndPosition := Pos(' ', Result);
  if EndPosition > 0 then
    SetLength(Result, EndPosition - 1);
  if StartsStr('0x', Result) then
    Delete(Result, 1, 2);
end;

function MacOSTokenMatches(const AToken, AValue: string): Boolean;
var
  Token: string;
  Value: string;
begin
  Token := LowerCase(Trim(AToken));
  Value := LowerCase(Trim(AValue));
  Result := (Token <> '') and (Value <> '') and
    ((Token = Value) or
    ((Length(Value) >= 4) and (Pos(Value, Token) > 0)) or
    ((Length(Token) >= 4) and (Pos(Token, Value) > 0)));
end;

function ParseMacOSSystemProfilerDevice(
  const ADevice, ASnapshot: string
): TSerialDeviceInfo;
var
  DeviceToken: string;
  I: Integer;
  LocationToken: string;
  Sections: TMacOSProfilerSections;
begin
  Result := Default(TSerialDeviceInfo);
  Result.Device := Trim(ADevice);
  DeviceToken := MacOSDeviceToken(Result.Device);
  if DeviceToken = '' then
    Exit;

  Sections := ParseMacOSProfilerSections(ASnapshot);
  for I := Low(Sections) to High(Sections) do
  begin
    LocationToken := NormalizeMacOSLocationId(Sections[I].LocationId);
    if not MacOSTokenMatches(DeviceToken, Sections[I].SerialNumber) and
      not MacOSTokenMatches(DeviceToken, LocationToken) then
      Continue;

    Result.Vendor := Trim(Sections[I].Manufacturer);
    if Result.Vendor = '' then
      Result.Vendor := Trim(Sections[I].VendorDescription);
    Result.Model := Trim(Sections[I].Model);
    Result.SerialShort := Trim(Sections[I].SerialNumber);
    Result.VendorId := Sections[I].VendorId;
    Result.ProductId := Sections[I].ProductId;
    if Result.SerialShort <> '' then
      Result.PersistentId := Result.SerialShort
    else
      Result.PersistentId := Trim(Sections[I].LocationId);
    Exit;
  end;
end;

end.
