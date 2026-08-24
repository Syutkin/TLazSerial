unit LazSerialWindowsDevices;

{$mode ObjFPC}{$H+}

interface

uses
  LazSerialDevices;

function IsWindowsComPortName(const AValue: string): Boolean;

function BuildWindowsSerialDeviceInfo(
  const APortName, AVendor, AModel, ADeviceInstanceId: string;
  const AProblemCode: Cardinal;
  const AHasProblemCode: Boolean
): TSerialDeviceInfo;

function EnumerateWindowsSetupApiDevices: TSerialDeviceInfoArray;

implementation

uses
  Classes, StrUtils, SysUtils, LazSerialDeviceParsers
  {$IFDEF Windows}
  , Windows
  {$ENDIF};

function IsWindowsComPortName(const AValue: string): Boolean;
var
  I: Integer;
  Value: string;
begin
  Value := Trim(AValue);
  if (Length(Value) < 4) or not StartsText('COM', Value) then
    Exit(False);
  for I := 4 to Length(Value) do
    if not (Value[I] in ['0'..'9']) then
      Exit(False);
  Result := True;
end;

function WithoutTrailingPortName(
  const AModel, APortName: string
): string;
var
  Suffix: string;
begin
  Result := Trim(AModel);
  Suffix := '(' + Trim(APortName) + ')';
  if EndsText(Suffix, Result) then
    Result := Trim(Copy(Result, 1, Length(Result) - Length(Suffix)));
end;

function BuildWindowsSerialDeviceInfo(
  const APortName, AVendor, AModel, ADeviceInstanceId: string;
  const AProblemCode: Cardinal;
  const AHasProblemCode: Boolean
): TSerialDeviceInfo;
var
  ParsedDeviceId: TSerialDeviceInfo;
begin
  ParsedDeviceId := ParseWindowsPnpDeviceId(ADeviceInstanceId);
  Result := ParsedDeviceId;
  Result.Device := Trim(APortName);
  Result.Vendor := Trim(AVendor);
  Result.Model := WithoutTrailingPortName(AModel, APortName);
  if AHasProblemCode then
    Result.ErrorCode := IntToStr(AProblemCode)
  else
    Result.ErrorCode := '';
end;

{$IFDEF Windows}
const
  ConfigManagerSuccess = 0;
  DeviceInfoDataPresent = $00000002;
  DeviceRegistryGlobal = $00000001;
  DeviceRegistryHardware = $00000001;
  SetupApiDll = 'setupapi.dll';
  ConfigManagerDll = 'cfgmgr32.dll';
  SetupPropertyDeviceDescription = $00000000;
  SetupPropertyManufacturer = $0000000B;
  SetupPropertyFriendlyName = $0000000C;

  PortsDeviceClassGuid: TGUID = (
    D1: $4D36E978;
    D2: $E325;
    D3: $11CE;
    D4: ($BF, $C1, $08, $00, $2B, $E1, $03, $18)
  );

type
  HDeviceInfoSet = THandle;

  {$PACKRECORDS C}
  TSetupDeviceInfoData = record
    Size: DWORD;
    ClassGuid: TGUID;
    DeviceInstance: DWORD;
    Reserved: ULONG_PTR;
  end;
  {$PACKRECORDS DEFAULT}

function SetupDiGetClassDevsW(
  AClassGuid: PGUID;
  AEnumerator: PWideChar;
  AParentWindow: HWND;
  AFlags: DWORD
): HDeviceInfoSet; stdcall; external SetupApiDll name 'SetupDiGetClassDevsW';

function SetupDiEnumDeviceInfo(
  ADeviceInfoSet: HDeviceInfoSet;
  AMemberIndex: DWORD;
  var ADeviceInfoData: TSetupDeviceInfoData
): BOOL; stdcall; external SetupApiDll name 'SetupDiEnumDeviceInfo';

function SetupDiGetDeviceRegistryPropertyW(
  ADeviceInfoSet: HDeviceInfoSet;
  var ADeviceInfoData: TSetupDeviceInfoData;
  AProperty: DWORD;
  APropertyDataType: PDWORD;
  APropertyBuffer: PByte;
  APropertyBufferSize: DWORD;
  ARequiredSize: PDWORD
): BOOL; stdcall;
  external SetupApiDll name 'SetupDiGetDeviceRegistryPropertyW';

function SetupDiGetDeviceInstanceIdW(
  ADeviceInfoSet: HDeviceInfoSet;
  var ADeviceInfoData: TSetupDeviceInfoData;
  ADeviceInstanceId: PWideChar;
  ADeviceInstanceIdSize: DWORD;
  ARequiredSize: PDWORD
): BOOL; stdcall; external SetupApiDll name 'SetupDiGetDeviceInstanceIdW';

function SetupDiOpenDevRegKey(
  ADeviceInfoSet: HDeviceInfoSet;
  var ADeviceInfoData: TSetupDeviceInfoData;
  AScope, AHardwareProfile, AKeyType: DWORD;
  ADesiredAccess: REGSAM
): HKEY; stdcall; external SetupApiDll name 'SetupDiOpenDevRegKey';

function SetupDiDestroyDeviceInfoList(
  ADeviceInfoSet: HDeviceInfoSet
): BOOL; stdcall; external SetupApiDll name 'SetupDiDestroyDeviceInfoList';

function CMGetDeviceNodeStatus(
  out AStatus, AProblemNumber: DWORD;
  ADeviceInstance, AFlags: DWORD
): DWORD; stdcall; external ConfigManagerDll name 'CM_Get_DevNode_Status';

function RefreshTerminated: Boolean;
begin
  try
    Result := TThread.CheckTerminated;
  except
    on E: EThreadExternalException do
      Result := False;
  end;
end;

function WideBufferToString(const ABuffer: array of WideChar): string;
begin
  if Length(ABuffer) = 0 then
    Exit('');
  Result := UTF8Encode(UnicodeString(PWideChar(@ABuffer[0])));
end;

function ReadSetupDeviceProperty(
  const ADeviceInfoSet: HDeviceInfoSet;
  var ADeviceInfoData: TSetupDeviceInfoData;
  const AProperty: DWORD
): string;
var
  Buffer: array of WideChar;
  DataType: DWORD;
  RequiredSize: DWORD;
begin
  Result := '';
  Buffer := nil;
  DataType := 0;
  RequiredSize := 0;
  SetupDiGetDeviceRegistryPropertyW(
    ADeviceInfoSet,
    ADeviceInfoData,
    AProperty,
    @DataType,
    nil,
    0,
    @RequiredSize
  );
  if RequiredSize = 0 then
    Exit;

  SetLength(Buffer, (RequiredSize div SizeOf(WideChar)) + 1);
  FillChar(Buffer[0], Length(Buffer) * SizeOf(WideChar), 0);
  if not SetupDiGetDeviceRegistryPropertyW(
    ADeviceInfoSet,
    ADeviceInfoData,
    AProperty,
    @DataType,
    PByte(@Buffer[0]),
    Length(Buffer) * SizeOf(WideChar),
    @RequiredSize
  ) then
    Exit;
  Result := Trim(WideBufferToString(Buffer));
end;

function ReadSetupDeviceInstanceId(
  const ADeviceInfoSet: HDeviceInfoSet;
  var ADeviceInfoData: TSetupDeviceInfoData
): string;
var
  Buffer: array of WideChar;
  RequiredSize: DWORD;
begin
  Result := '';
  Buffer := nil;
  RequiredSize := 0;
  SetupDiGetDeviceInstanceIdW(
    ADeviceInfoSet,
    ADeviceInfoData,
    nil,
    0,
    @RequiredSize
  );
  if RequiredSize = 0 then
    Exit;

  SetLength(Buffer, RequiredSize + 1);
  FillChar(Buffer[0], Length(Buffer) * SizeOf(WideChar), 0);
  if not SetupDiGetDeviceInstanceIdW(
    ADeviceInfoSet,
    ADeviceInfoData,
    @Buffer[0],
    Length(Buffer),
    @RequiredSize
  ) then
    Exit;
  Result := Trim(WideBufferToString(Buffer));
end;

function ReadPortName(
  const ADeviceInfoSet: HDeviceInfoSet;
  var ADeviceInfoData: TSetupDeviceInfoData
): string;
var
  Buffer: array of Byte;
  DataSize: DWORD;
  DataType: DWORD;
  DeviceKey: HKEY;
  ValueName: UnicodeString;
begin
  Result := '';
  Buffer := nil;
  DeviceKey := SetupDiOpenDevRegKey(
    ADeviceInfoSet,
    ADeviceInfoData,
    DeviceRegistryGlobal,
    0,
    DeviceRegistryHardware,
    KEY_READ
  );
  if DeviceKey = HKEY(INVALID_HANDLE_VALUE) then
    Exit;
  try
    ValueName := 'PortName';
    DataSize := 0;
    DataType := 0;
    if RegQueryValueExW(
      DeviceKey,
      PWideChar(ValueName),
      nil,
      @DataType,
      nil,
      @DataSize
    ) <> ERROR_SUCCESS then
      Exit;
    if (DataSize = 0) or
      not (DataType in [REG_SZ, REG_EXPAND_SZ]) then
      Exit;

    SetLength(Buffer, DataSize + SizeOf(WideChar));
    FillChar(Buffer[0], Length(Buffer), 0);
    if RegQueryValueExW(
      DeviceKey,
      PWideChar(ValueName),
      nil,
      @DataType,
      @Buffer[0],
      @DataSize
    ) <> ERROR_SUCCESS then
      Exit;
    Result := Trim(UTF8Encode(UnicodeString(PWideChar(@Buffer[0]))));
  finally
    RegCloseKey(DeviceKey);
  end;
end;

procedure AddDevice(
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

function EnumerateWindowsSetupApiDevices: TSerialDeviceInfoArray;
var
  DeviceInfoData: TSetupDeviceInfoData;
  DeviceInfoSet: HDeviceInfoSet;
  DeviceInstanceId: string;
  DeviceModel: string;
  DeviceStatus: DWORD;
  HasProblemCode: Boolean;
  Index: DWORD;
  PortName: string;
  ProblemCode: DWORD;
begin
  Result := nil;
  DeviceInfoSet := SetupDiGetClassDevsW(
    @PortsDeviceClassGuid,
    nil,
    0,
    DeviceInfoDataPresent
  );
  if DeviceInfoSet = INVALID_HANDLE_VALUE then
    Exit;
  try
    Index := 0;
    while not RefreshTerminated do
    begin
      DeviceInfoData := Default(TSetupDeviceInfoData);
      DeviceInfoData.Size := SizeOf(TSetupDeviceInfoData);
      if not SetupDiEnumDeviceInfo(
        DeviceInfoSet,
        Index,
        DeviceInfoData
      ) then
        Break;
      Inc(Index);

      PortName := ReadPortName(DeviceInfoSet, DeviceInfoData);
      if not IsWindowsComPortName(PortName) then
        Continue;

      DeviceInstanceId := ReadSetupDeviceInstanceId(
        DeviceInfoSet,
        DeviceInfoData
      );
      DeviceModel := ReadSetupDeviceProperty(
        DeviceInfoSet,
        DeviceInfoData,
        SetupPropertyDeviceDescription
      );
      if DeviceModel = '' then
        DeviceModel := ReadSetupDeviceProperty(
          DeviceInfoSet,
          DeviceInfoData,
          SetupPropertyFriendlyName
        );
      DeviceStatus := 0;
      ProblemCode := 0;
      HasProblemCode := CMGetDeviceNodeStatus(
        DeviceStatus,
        ProblemCode,
        DeviceInfoData.DeviceInstance,
        0
      ) = ConfigManagerSuccess;

      AddDevice(Result, BuildWindowsSerialDeviceInfo(
        PortName,
        ReadSetupDeviceProperty(
          DeviceInfoSet,
          DeviceInfoData,
          SetupPropertyManufacturer
        ),
        DeviceModel,
        DeviceInstanceId,
        ProblemCode,
        HasProblemCode
      ));
    end;
  finally
    SetupDiDestroyDeviceInfoList(DeviceInfoSet);
  end;
end;
{$ELSE}
function EnumerateWindowsSetupApiDevices: TSerialDeviceInfoArray;
begin
  Result := nil;
end;
{$ENDIF}

end.
