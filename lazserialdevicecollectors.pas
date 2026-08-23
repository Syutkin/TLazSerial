unit LazSerialDeviceCollectors;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, LazSerialDevices;

type
  TLinuxSerialDeviceCollector = class
  protected
    function CanOpenDevice(const ADevice: string): Boolean; virtual;
    procedure EnumerateDeviceNames(ADevices: TStrings); virtual;
    function ReadDeviceProperties(const ADevice: string;
      out AProperties: string): Boolean; virtual;
  public
    function Collect(
      const AOptions: TSerialDeviceEnumerationOptions = []
    ): TSerialDeviceInfoArray;
  end;

  TWindowsSerialDeviceCollector = class
  protected
    function CanOpenDevice(const ADevice: string): Boolean; virtual;
    procedure EnumerateRegistryDeviceNames(ADevices: TStrings); virtual;
    function ReadWmiSnapshot(out ASnapshot: string): Boolean; virtual;
  public
    function Collect(
      const AOptions: TSerialDeviceEnumerationOptions = []
    ): TSerialDeviceInfoArray;
  end;

  TUnixSerialDeviceCollector = class
  protected
    function CanOpenDevice(const ADevice: string): Boolean; virtual;
    procedure EnumerateDeviceNames(ADevices: TStrings); virtual;
  public
    function Collect(
      const AOptions: TSerialDeviceEnumerationOptions = []
    ): TSerialDeviceInfoArray; virtual;
  end;

  TMacOSSerialDeviceCollector = class(TUnixSerialDeviceCollector)
  protected
    procedure EnumerateDeviceNames(ADevices: TStrings); override;
    function ReadSystemProfilerSnapshot(out ASnapshot: string): Boolean;
      virtual;
  public
    function Collect(
      const AOptions: TSerialDeviceEnumerationOptions = []
    ): TSerialDeviceInfoArray; override;
  end;

function MatchesLinuxSerialDevicePattern(const ADevice: string): Boolean;
function IsLinuxBuiltInSerialDevice(const ATypeValue: string;
  const ADeviceExists: Boolean): Boolean;

implementation

uses
  FileUtil, Process, StrUtils, SysUtils, LazSerialDeviceParsers
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF}
  {$IFDEF Windows}
  , ActiveX, ComObj, Registry, Variants, Windows, WmiUtil
  {$ENDIF};

const
  LinuxSerialDevicePatterns: array[0..3] of string = (
    'ttyAMA*',
    'rfcomm*',
    'ttyUSB*',
    'ttyACM*'
  );

function MatchesLinuxSerialDevicePattern(const ADevice: string): Boolean;
var
  DeviceName: string;
  I: Integer;
  Prefix: string;
begin
  Result := False;
  if ExcludeTrailingPathDelimiter(ExtractFileDir(ADevice)) <> '/dev' then
    Exit;

  DeviceName := ExtractFileName(ADevice);
  for I := Low(LinuxSerialDevicePatterns) to
    High(LinuxSerialDevicePatterns) do
  begin
    Prefix := Copy(
      LinuxSerialDevicePatterns[I],
      1,
      Length(LinuxSerialDevicePatterns[I]) - 1
    );
    if DeviceName.StartsWith(Prefix) then
      Exit(True);
  end;
end;

function IsLinuxBuiltInSerialDevice(const ATypeValue: string;
  const ADeviceExists: Boolean): Boolean;
begin
  Result := ADeviceExists and (Trim(ATypeValue) = '4');
end;

function NaturalSortDeviceNames(AList: TStringList;
  AIndex1, AIndex2: Integer): Integer;
begin
  Result := NaturalCompareText(AList[AIndex1], AList[AIndex2]);
end;

procedure NormalizeDeviceNames(const ASource, ADestination: TStringList);
var
  DeviceName: string;
  I: Integer;
begin
  ADestination.Clear;
  for I := 0 to ASource.Count - 1 do
  begin
    DeviceName := Trim(ASource[I]);
    if (DeviceName <> '') and (ADestination.IndexOf(DeviceName) < 0) then
      ADestination.Add(DeviceName);
  end;
  ADestination.CustomSort(@NaturalSortDeviceNames);
end;

procedure AddDevice(var ADevices: TSerialDeviceInfoArray;
  const ADevice: TSerialDeviceInfo);
var
  NewIndex: Integer;
begin
  NewIndex := Length(ADevices);
  SetLength(ADevices, NewIndex + 1);
  ADevices[NewIndex] := ADevice;
end;

function IndexOfWindowsDevice(
  const ADevices: TSerialDeviceInfoArray;
  const ADevice: string
): Integer;
var
  I: Integer;
begin
  for I := Low(ADevices) to High(ADevices) do
    if CompareText(ADevices[I].Device, ADevice) = 0 then
      Exit(I);
  Result := -1;
end;

procedure SortWindowsDevices(var ADevices: TSerialDeviceInfoArray);
var
  Current: TSerialDeviceInfo;
  I: Integer;
  J: Integer;
begin
  for I := Low(ADevices) + 1 to High(ADevices) do
  begin
    Current := ADevices[I];
    J := I - 1;
    while (J >= Low(ADevices)) and
      (NaturalCompareText(ADevices[J].Device, Current.Device) > 0) do
    begin
      ADevices[J + 1] := ADevices[J];
      Dec(J);
    end;
    ADevices[J + 1] := Current;
  end;
end;

function NormalizeWindowsDevices(
  const ADevices: TSerialDeviceInfoArray
): TSerialDeviceInfoArray;
var
  Device: TSerialDeviceInfo;
  I: Integer;
begin
  Result := nil;
  for I := Low(ADevices) to High(ADevices) do
  begin
    Device := ADevices[I];
    Device.Device := Trim(Device.Device);
    if (Device.Device <> '') and
      (IndexOfWindowsDevice(Result, Device.Device) < 0) then
      AddDevice(Result, Device);
  end;
  SortWindowsDevices(Result);
end;

function TLinuxSerialDeviceCollector.Collect(
  const AOptions: TSerialDeviceEnumerationOptions
): TSerialDeviceInfoArray;
var
  DeviceInfo: TSerialDeviceInfo;
  DeviceName: string;
  DeviceNames: TStringList;
  I: Integer;
  RawDeviceNames: TStringList;
  Properties: string;
begin
  Result := nil;
  RawDeviceNames := TStringList.Create;
  DeviceNames := TStringList.Create;
  try
    DeviceNames.CaseSensitive := True;
    RawDeviceNames.CaseSensitive := True;
    EnumerateDeviceNames(RawDeviceNames);
    NormalizeDeviceNames(RawDeviceNames, DeviceNames);
    for I := 0 to DeviceNames.Count - 1 do
    begin
      DeviceName := DeviceNames[I];
      if (sdeoAccessibleOnly in AOptions) and
        not CanOpenDevice(DeviceName) then
        Continue;

      DeviceInfo := Default(TSerialDeviceInfo);
      DeviceInfo.Device := DeviceName;
      Properties := '';
      try
        if ReadDeviceProperties(DeviceName, Properties) and
          (Trim(Properties) <> '') then
          DeviceInfo := ParseLinuxUdevProperties(DeviceName, Properties);
      except
        on E: Exception do
          DeviceInfo.Device := DeviceName;
      end;
      AddDevice(Result, DeviceInfo);
    end;
  finally
    DeviceNames.Free;
    RawDeviceNames.Free;
  end;
end;

{$IFDEF Linux}
function TryReadFileContent(const AFileName: string;
  out AValue: string): Boolean;
begin
  AValue := '';
  try
    AValue := ReadFileToString(AFileName);
    Result := True;
  except
    on E: Exception do
      Result := False;
  end;
end;

procedure AddBuiltInDevices(ADevices: TStrings);
var
  Directories: TStringList;
  DevicePath: string;
  DeviceType: string;
  I: Integer;
  SysDevicePath: string;
begin
  Directories := FindAllDirectories('/sys/class/tty/', False);
  try
    for I := 0 to Directories.Count - 1 do
    begin
      SysDevicePath := Directories[I];
      DevicePath := '/dev/' + ExtractFileName(SysDevicePath);
      if TryReadFileContent(SysDevicePath + '/type', DeviceType) and
        IsLinuxBuiltInSerialDevice(DeviceType, FileExists(DevicePath)) then
        ADevices.Add(DevicePath);
    end;
  finally
    Directories.Free;
  end;
end;

{$ENDIF}

function TLinuxSerialDeviceCollector.CanOpenDevice(
  const ADevice: string
): Boolean;
{$IFDEF Linux}
var
  DeviceHandle: cint;
{$ENDIF}
begin
  Result := False;
  {$IFDEF Linux}
  DeviceHandle := fpOpen(
    ADevice,
    O_RdWr or O_NonBlock or O_NoCtty
  );
  if DeviceHandle < 0 then
    Exit;
  fpClose(DeviceHandle);
  Result := True;
  {$ENDIF}
end;

procedure TLinuxSerialDeviceCollector.EnumerateDeviceNames(ADevices: TStrings);
{$IFDEF Linux}
var
  I: Integer;
{$ENDIF}
begin
  {$IFDEF Linux}
  AddBuiltInDevices(ADevices);
  for I := Low(LinuxSerialDevicePatterns) to
    High(LinuxSerialDevicePatterns) do
    FindAllFiles(
      ADevices,
      '/dev',
      LinuxSerialDevicePatterns[I],
      False,
      faAnyFile
    );
  {$ENDIF}
end;

function TLinuxSerialDeviceCollector.ReadDeviceProperties(
  const ADevice: string;
  out AProperties: string
): Boolean;
begin
  AProperties := '';
  Result := False;
  {$IFDEF Linux}
  Result := RunCommand(
    'udevadm',
    ['info', '--query=property', '--name', ADevice],
    AProperties,
    [poStderrToOutput]
  ) and (Trim(AProperties) <> '');
  {$ENDIF}
end;

function TWindowsSerialDeviceCollector.Collect(
  const AOptions: TSerialDeviceEnumerationOptions
): TSerialDeviceInfoArray;
var
  Device: TSerialDeviceInfo;
  I: Integer;
  RawDevices: TSerialDeviceInfoArray;
  RegistryDeviceNames: TStringList;
  Snapshot: string;
begin
  Result := nil;
  RawDevices := nil;
  Snapshot := '';
  try
    if ReadWmiSnapshot(Snapshot) then
      RawDevices := ParseWindowsWmiSnapshot(Snapshot);
  except
    on E: Exception do
      RawDevices := nil;
  end;

  if Length(RawDevices) = 0 then
  begin
    RegistryDeviceNames := TStringList.Create;
    try
      RegistryDeviceNames.CaseSensitive := False;
      try
        EnumerateRegistryDeviceNames(RegistryDeviceNames);
      except
        on E: Exception do
          RegistryDeviceNames.Clear;
      end;
      for I := 0 to RegistryDeviceNames.Count - 1 do
      begin
        Device := Default(TSerialDeviceInfo);
        Device.Device := RegistryDeviceNames[I];
        AddDevice(RawDevices, Device);
      end;
    finally
      RegistryDeviceNames.Free;
    end;
  end;

  RawDevices := NormalizeWindowsDevices(RawDevices);
  for I := Low(RawDevices) to High(RawDevices) do
  begin
    if (sdeoAccessibleOnly in AOptions) and
      not CanOpenDevice(RawDevices[I].Device) then
      Continue;
    AddDevice(Result, RawDevices[I]);
  end;
end;

function TWindowsSerialDeviceCollector.CanOpenDevice(
  const ADevice: string
): Boolean;
{$IFDEF Windows}
var
  DeviceHandle: THandle;
  DevicePath: string;
{$ENDIF}
begin
  Result := False;
  {$IFDEF Windows}
  DevicePath := '\\.\' + ADevice;
  DeviceHandle := CreateFile(
    PChar(DevicePath),
    GENERIC_READ or GENERIC_WRITE,
    0,
    nil,
    OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    0
  );
  if DeviceHandle = INVALID_HANDLE_VALUE then
    Exit;
  CloseHandle(DeviceHandle);
  Result := True;
  {$ENDIF}
end;

procedure TWindowsSerialDeviceCollector.EnumerateRegistryDeviceNames(
  ADevices: TStrings
);
{$IFDEF Windows}
const
  SerialCommKey = '\HARDWARE\DEVICEMAP\SERIALCOMM';
var
  I: Integer;
  Registry: TRegistry;
  ValueNames: TStringList;
{$ENDIF}
begin
  ADevices.Clear;
  {$IFDEF Windows}
  Registry := TRegistry.Create(KEY_READ);
  ValueNames := TStringList.Create;
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    if not Registry.OpenKey(SerialCommKey, False) then
      Exit;
    Registry.GetValueNames(ValueNames);
    for I := 0 to ValueNames.Count - 1 do
      try
        ADevices.Add(Registry.ReadString(ValueNames[I]));
      except
        on E: Exception do
          Continue;
      end;
  finally
    ValueNames.Free;
    Registry.Free;
  end;
  {$ENDIF}
end;

{$IFDEF Windows}
function SanitizeWmiSnapshotValue(const AValue: string): string;
begin
  Result := StringReplace(AValue, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
end;

procedure AppendWmiSnapshotProperty(
  var ASnapshot: string;
  const AName, AValue: string
);
begin
  ASnapshot := ASnapshot + AName + '=' +
    SanitizeWmiSnapshotValue(AValue) + LineEnding;
end;
{$ENDIF}

function TWindowsSerialDeviceCollector.ReadWmiSnapshot(
  out ASnapshot: string
): Boolean;
{$IFDEF Windows}
const
  WbemComputer = 'localhost';
  WbemPassword = '';
  WbemUser = '';
  WbemFlagForwardOnly = $00000020;
var
  ComInitialization: HRESULT;
  Iterator: OEnumIterator;
  Locator: OleVariant;
  ObjectSet: OleVariant;
  Service: OleVariant;
  WmiObject: OleVariant;
{$ENDIF}
begin
  ASnapshot := '';
  Result := False;
  {$IFDEF Windows}
  ComInitialization := CoInitialize(nil);
  if Failed(ComInitialization) then
    Exit;
  try
    try
      Locator := CreateOleObject('WbemScripting.SWbemLocator');
      Service := Locator.ConnectServer(
        WbemComputer,
        'root\CIMV2',
        WbemUser,
        WbemPassword
      );
      ObjectSet := Service.ExecQuery(
        'SELECT Caption, Manufacturer, DeviceID, PNPDeviceID, ' +
        'ConfigManagerErrorCode FROM Win32_PnPEntity ' +
        'WHERE Caption LIKE "%(COM%)"',
        'WQL',
        WbemFlagForwardOnly
      );

      for WmiObject in Iterator.Enumerate(ObjectSet) do
      begin
        AppendWmiSnapshotProperty(
          ASnapshot,
          'Caption',
          OleVariantToText(WmiObject.Caption)
        );
        AppendWmiSnapshotProperty(
          ASnapshot,
          'Manufacturer',
          OleVariantToText(WmiObject.Manufacturer)
        );
        AppendWmiSnapshotProperty(
          ASnapshot,
          'DeviceID',
          OleVariantToText(WmiObject.DeviceID)
        );
        AppendWmiSnapshotProperty(
          ASnapshot,
          'PNPDeviceID',
          OleVariantToText(WmiObject.PNPDeviceID)
        );
        AppendWmiSnapshotProperty(
          ASnapshot,
          'ConfigManagerErrorCode',
          OleVariantToText(WmiObject.ConfigManagerErrorCode)
        );
        ASnapshot := ASnapshot + LineEnding;
      end;
      Result := Trim(ASnapshot) <> '';
    except
      on E: Exception do
      begin
        ASnapshot := '';
        Result := False;
      end;
    end;
  finally
    VarClear(Iterator.IterItem);
    Iterator.OEnum := nil;
    VarClear(Iterator.MainObj);
    VarClear(WmiObject);
    VarClear(ObjectSet);
    VarClear(Service);
    VarClear(Locator);
    CoUninitialize;
  end;
  {$ENDIF}
end;

function TUnixSerialDeviceCollector.CanOpenDevice(
  const ADevice: string
): Boolean;
{$IFDEF UNIX}
var
  DeviceHandle: cint;
{$ENDIF}
begin
  Result := False;
  {$IFDEF UNIX}
  DeviceHandle := fpOpen(
    ADevice,
    O_RdWr or O_NonBlock or O_NoCtty
  );
  if DeviceHandle < 0 then
    Exit;
  fpClose(DeviceHandle);
  Result := True;
  {$ENDIF}
end;

procedure TUnixSerialDeviceCollector.EnumerateDeviceNames(
  ADevices: TStrings
);
begin
  {$IFDEF UNIX}
  FindAllFiles(ADevices, '/dev', 'ttyAM*', False, faAnyFile);
  {$ENDIF}
end;

function TUnixSerialDeviceCollector.Collect(
  const AOptions: TSerialDeviceEnumerationOptions
): TSerialDeviceInfoArray;
var
  Device: TSerialDeviceInfo;
  DeviceNames: TStringList;
  I: Integer;
  RawDeviceNames: TStringList;
begin
  Result := nil;
  RawDeviceNames := TStringList.Create;
  DeviceNames := TStringList.Create;
  try
    RawDeviceNames.CaseSensitive := True;
    DeviceNames.CaseSensitive := True;
    EnumerateDeviceNames(RawDeviceNames);
    NormalizeDeviceNames(RawDeviceNames, DeviceNames);
    for I := 0 to DeviceNames.Count - 1 do
    begin
      if (sdeoAccessibleOnly in AOptions) and
        not CanOpenDevice(DeviceNames[I]) then
        Continue;
      Device := Default(TSerialDeviceInfo);
      Device.Device := DeviceNames[I];
      AddDevice(Result, Device);
    end;
  finally
    DeviceNames.Free;
    RawDeviceNames.Free;
  end;
end;

function MacOSCuAlias(const ADevice: string): string;
const
  TtyPrefix = '/dev/tty.';
begin
  if StartsStr(TtyPrefix, ADevice) then
    Result := '/dev/cu.' + Copy(ADevice, Length(TtyPrefix) + 1, MaxInt)
  else
    Result := '';
end;

procedure SelectCanonicalMacOSDeviceNames(
  const ASource, ADestination: TStringList
);
var
  CuAlias: string;
  I: Integer;
  NormalizedSource: TStringList;
begin
  NormalizedSource := TStringList.Create;
  try
    NormalizedSource.CaseSensitive := True;
    NormalizeDeviceNames(ASource, NormalizedSource);
    ADestination.Clear;
    for I := 0 to NormalizedSource.Count - 1 do
    begin
      CuAlias := MacOSCuAlias(NormalizedSource[I]);
      if (CuAlias <> '') and (NormalizedSource.IndexOf(CuAlias) >= 0) then
        Continue;
      ADestination.Add(NormalizedSource[I]);
    end;
    ADestination.CustomSort(@NaturalSortDeviceNames);
  finally
    NormalizedSource.Free;
  end;
end;

procedure TMacOSSerialDeviceCollector.EnumerateDeviceNames(
  ADevices: TStrings
);
begin
  {$IFDEF Darwin}
  FindAllFiles(ADevices, '/dev', 'cu.*', False, faAnyFile);
  FindAllFiles(ADevices, '/dev', 'tty.*', False, faAnyFile);
  {$ENDIF}
end;

function TMacOSSerialDeviceCollector.ReadSystemProfilerSnapshot(
  out ASnapshot: string
): Boolean;
begin
  ASnapshot := '';
  Result := False;
  {$IFDEF Darwin}
  Result := RunCommand(
    'system_profiler',
    ['SPUSBDataType'],
    ASnapshot,
    [poStderrToOutput]
  ) and (Trim(ASnapshot) <> '');
  {$ENDIF}
end;

function TMacOSSerialDeviceCollector.Collect(
  const AOptions: TSerialDeviceEnumerationOptions
): TSerialDeviceInfoArray;
var
  CanonicalDeviceNames: TStringList;
  Device: TSerialDeviceInfo;
  I: Integer;
  RawDeviceNames: TStringList;
  SelectedDeviceNames: TStringList;
  Snapshot: string;
begin
  Result := nil;
  RawDeviceNames := TStringList.Create;
  CanonicalDeviceNames := TStringList.Create;
  SelectedDeviceNames := TStringList.Create;
  try
    RawDeviceNames.CaseSensitive := True;
    CanonicalDeviceNames.CaseSensitive := True;
    SelectedDeviceNames.CaseSensitive := True;
    EnumerateDeviceNames(RawDeviceNames);
    SelectCanonicalMacOSDeviceNames(
      RawDeviceNames,
      CanonicalDeviceNames
    );

    for I := 0 to CanonicalDeviceNames.Count - 1 do
      if not (sdeoAccessibleOnly in AOptions) or
        CanOpenDevice(CanonicalDeviceNames[I]) then
        SelectedDeviceNames.Add(CanonicalDeviceNames[I]);

    Snapshot := '';
    if SelectedDeviceNames.Count > 0 then
      try
        if not ReadSystemProfilerSnapshot(Snapshot) then
          Snapshot := '';
      except
        on E: Exception do
          Snapshot := '';
      end;

    for I := 0 to SelectedDeviceNames.Count - 1 do
    begin
      Device := Default(TSerialDeviceInfo);
      Device.Device := SelectedDeviceNames[I];
      if Snapshot <> '' then
        try
          Device := ParseMacOSSystemProfilerDevice(
            Device.Device,
            Snapshot
          );
        except
          on E: Exception do
            Device.Device := SelectedDeviceNames[I];
        end;
      AddDevice(Result, Device);
    end;
  finally
    SelectedDeviceNames.Free;
    CanonicalDeviceNames.Free;
    RawDeviceNames.Free;
  end;
end;

end.
