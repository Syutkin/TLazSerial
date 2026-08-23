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

function MatchesLinuxSerialDevicePattern(const ADevice: string): Boolean;
function IsLinuxBuiltInSerialDevice(const ATypeValue: string;
  const ADeviceExists: Boolean): Boolean;

implementation

uses
  FileUtil, StrUtils, SysUtils, LazSerialDeviceParsers
  {$IFDEF Linux}
  , BaseUnix, Process
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

end.
