unit SerialDeviceCollectorTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerialDevices,
  LazSerialDeviceCollectors;

type
  TSerialDeviceCollectorTests = class(TTestCase)
  private
    function FindFixture(const AFileName: string): string;
    function LoadFixture(const AFileName: string): string;
  published
    procedure LinuxPatternsMatchSupportedPortClasses;
    procedure LinuxPatternsRejectUnsupportedPortClasses;
    procedure BuiltInSerialRequiresExistingDeviceNode;
    procedure CollectorEnrichesDeduplicatesAndNaturalSorts;
    procedure CollectorDefaultModeDoesNotCheckAccessibility;
    procedure CollectorAccessibleOnlyFiltersBeforeEnrichment;
    procedure CollectorPreservesDeviceWhenEnrichmentFails;
    procedure CollectorPreservesDeviceWhenPropertiesAreEmpty;
    procedure CollectorContinuesAfterPropertyProviderException;
    procedure DeviceLookupUsesLinuxCaseSensitiveNames;
    procedure WindowsCollectorDeduplicatesCaseInsensitivelyAndNaturalSorts;
    procedure WindowsCollectorUsesRegistryFallback;
    procedure WindowsCollectorUsesRegistryForInvalidWmiSnapshot;
    procedure WindowsCollectorDoesNotReadRegistryWhenWmiHasPorts;
    procedure WindowsCollectorFiltersAccessibleDevicesAfterEnumeration;
    procedure MacOSCollectorUsesOneSnapshotAndCanonicalAliases;
    procedure MacOSCollectorPreservesDevicesWhenProfilerFails;
    procedure UnixCollectorReturnsDeviceOnlySnapshot;
  end;

implementation

type
  TFakePropertyResponse = class
  public
    Properties: string;
    RaisesException: Boolean;
    Succeeds: Boolean;
  end;

  TFakeLinuxSerialDeviceCollector = class(TLinuxSerialDeviceCollector)
  private
    FAccessibleDevices: TStringList;
    FAccessibilityCheckCount: Integer;
    FDevices: TStringList;
    FReadCount: Integer;
    FResponses: TStringList;
  protected
    function CanOpenDevice(const ADevice: string): Boolean; override;
    procedure EnumerateDeviceNames(ADevices: TStrings); override;
    function ReadDeviceProperties(const ADevice: string;
      out AProperties: string): Boolean; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddAccessibleDevice(const ADevice: string);
    procedure AddDevice(const ADevice: string);
    procedure AddResponse(const ADevice, AProperties: string;
      const ASucceeds: Boolean = True;
      const ARaisesException: Boolean = False);
    property ReadCount: Integer read FReadCount;
    property AccessibilityCheckCount: Integer read FAccessibilityCheckCount;
  end;

  TFakeWindowsSerialDeviceCollector = class(TWindowsSerialDeviceCollector)
  private
    FAccessibleDevices: TStringList;
    FAccessibilityCheckCount: Integer;
    FRegistryDevices: TStringList;
    FRegistryReadCount: Integer;
    FWmiReadCount: Integer;
    FWmiSnapshot: string;
    FWmiSucceeds: Boolean;
  protected
    function CanOpenDevice(const ADevice: string): Boolean; override;
    procedure EnumerateRegistryDeviceNames(ADevices: TStrings); override;
    function ReadWmiSnapshot(out ASnapshot: string): Boolean; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddAccessibleDevice(const ADevice: string);
    procedure AddRegistryDevice(const ADevice: string);
    property AccessibilityCheckCount: Integer
      read FAccessibilityCheckCount;
    property RegistryReadCount: Integer read FRegistryReadCount;
    property WmiReadCount: Integer read FWmiReadCount;
    property WmiSnapshot: string read FWmiSnapshot write FWmiSnapshot;
    property WmiSucceeds: Boolean read FWmiSucceeds write FWmiSucceeds;
  end;

  TFakeMacOSSerialDeviceCollector = class(TMacOSSerialDeviceCollector)
  private
    FDevices: TStringList;
    FProfilerReadCount: Integer;
    FProfilerSnapshot: string;
    FProfilerSucceeds: Boolean;
  protected
    procedure EnumerateDeviceNames(ADevices: TStrings); override;
    function ReadSystemProfilerSnapshot(out ASnapshot: string): Boolean;
      override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddDevice(const ADevice: string);
    property ProfilerReadCount: Integer read FProfilerReadCount;
    property ProfilerSnapshot: string
      read FProfilerSnapshot write FProfilerSnapshot;
    property ProfilerSucceeds: Boolean
      read FProfilerSucceeds write FProfilerSucceeds;
  end;

  TFakeUnixSerialDeviceCollector = class(TUnixSerialDeviceCollector)
  private
    FDevices: TStringList;
  protected
    procedure EnumerateDeviceNames(ADevices: TStrings); override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddDevice(const ADevice: string);
  end;

constructor TFakeLinuxSerialDeviceCollector.Create;
begin
  inherited Create;
  FAccessibleDevices := TStringList.Create;
  FAccessibleDevices.CaseSensitive := True;
  FDevices := TStringList.Create;
  FResponses := TStringList.Create;
  FResponses.CaseSensitive := True;
end;

destructor TFakeLinuxSerialDeviceCollector.Destroy;
var
  I: Integer;
begin
  for I := 0 to FResponses.Count - 1 do
    FResponses.Objects[I].Free;
  FResponses.Free;
  FDevices.Free;
  FAccessibleDevices.Free;
  inherited Destroy;
end;

procedure TFakeLinuxSerialDeviceCollector.AddAccessibleDevice(
  const ADevice: string
);
begin
  FAccessibleDevices.Add(ADevice);
end;

procedure TFakeLinuxSerialDeviceCollector.AddDevice(const ADevice: string);
begin
  FDevices.Add(ADevice);
end;

procedure TFakeLinuxSerialDeviceCollector.AddResponse(
  const ADevice, AProperties: string;
  const ASucceeds: Boolean;
  const ARaisesException: Boolean
);
var
  Response: TFakePropertyResponse;
begin
  Response := TFakePropertyResponse.Create;
  Response.Properties := AProperties;
  Response.Succeeds := ASucceeds;
  Response.RaisesException := ARaisesException;
  FResponses.AddObject(ADevice, Response);
end;

procedure TFakeLinuxSerialDeviceCollector.EnumerateDeviceNames(
  ADevices: TStrings
);
begin
  ADevices.Assign(FDevices);
end;

function TFakeLinuxSerialDeviceCollector.CanOpenDevice(
  const ADevice: string
): Boolean;
begin
  Inc(FAccessibilityCheckCount);
  Result := FAccessibleDevices.IndexOf(ADevice) >= 0;
end;

function TFakeLinuxSerialDeviceCollector.ReadDeviceProperties(
  const ADevice: string;
  out AProperties: string
): Boolean;
var
  Index: Integer;
  Response: TFakePropertyResponse;
begin
  Inc(FReadCount);
  AProperties := '';
  Index := FResponses.IndexOf(ADevice);
  if Index < 0 then
    Exit(False);

  Response := TFakePropertyResponse(FResponses.Objects[Index]);
  if Response.RaisesException then
    raise Exception.Create('Simulated property provider failure');
  AProperties := Response.Properties;
  Result := Response.Succeeds;
end;

constructor TFakeWindowsSerialDeviceCollector.Create;
begin
  inherited Create;
  FAccessibleDevices := TStringList.Create;
  FAccessibleDevices.CaseSensitive := False;
  FRegistryDevices := TStringList.Create;
  FWmiSucceeds := False;
end;

destructor TFakeWindowsSerialDeviceCollector.Destroy;
begin
  FRegistryDevices.Free;
  FAccessibleDevices.Free;
  inherited Destroy;
end;

procedure TFakeWindowsSerialDeviceCollector.AddAccessibleDevice(
  const ADevice: string
);
begin
  FAccessibleDevices.Add(ADevice);
end;

procedure TFakeWindowsSerialDeviceCollector.AddRegistryDevice(
  const ADevice: string
);
begin
  FRegistryDevices.Add(ADevice);
end;

function TFakeWindowsSerialDeviceCollector.CanOpenDevice(
  const ADevice: string
): Boolean;
begin
  Inc(FAccessibilityCheckCount);
  Result := FAccessibleDevices.IndexOf(ADevice) >= 0;
end;

procedure TFakeWindowsSerialDeviceCollector.EnumerateRegistryDeviceNames(
  ADevices: TStrings
);
begin
  Inc(FRegistryReadCount);
  ADevices.Assign(FRegistryDevices);
end;

function TFakeWindowsSerialDeviceCollector.ReadWmiSnapshot(
  out ASnapshot: string
): Boolean;
begin
  Inc(FWmiReadCount);
  ASnapshot := FWmiSnapshot;
  Result := FWmiSucceeds;
end;

constructor TFakeMacOSSerialDeviceCollector.Create;
begin
  inherited Create;
  FDevices := TStringList.Create;
  FProfilerSucceeds := False;
end;

destructor TFakeMacOSSerialDeviceCollector.Destroy;
begin
  FDevices.Free;
  inherited Destroy;
end;

procedure TFakeMacOSSerialDeviceCollector.AddDevice(const ADevice: string);
begin
  FDevices.Add(ADevice);
end;

procedure TFakeMacOSSerialDeviceCollector.EnumerateDeviceNames(
  ADevices: TStrings
);
begin
  ADevices.Assign(FDevices);
end;

function TFakeMacOSSerialDeviceCollector.ReadSystemProfilerSnapshot(
  out ASnapshot: string
): Boolean;
begin
  Inc(FProfilerReadCount);
  ASnapshot := FProfilerSnapshot;
  Result := FProfilerSucceeds;
end;

constructor TFakeUnixSerialDeviceCollector.Create;
begin
  inherited Create;
  FDevices := TStringList.Create;
end;

destructor TFakeUnixSerialDeviceCollector.Destroy;
begin
  FDevices.Free;
  inherited Destroy;
end;

procedure TFakeUnixSerialDeviceCollector.AddDevice(const ADevice: string);
begin
  FDevices.Add(ADevice);
end;

procedure TFakeUnixSerialDeviceCollector.EnumerateDeviceNames(
  ADevices: TStrings
);
begin
  ADevices.Assign(FDevices);
end;

function TSerialDeviceCollectorTests.FindFixture(
  const AFileName: string
): string;
var
  Candidate: string;
  Directory: string;
  I: Integer;
begin
  Directory := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  for I := 0 to 8 do
  begin
    Candidate := IncludeTrailingPathDelimiter(Directory) +
      'fixtures' + DirectorySeparator + AFileName;
    if FileExists(Candidate) then
      Exit(Candidate);
    Directory := ExtractFileDir(Directory);
  end;
  raise Exception.CreateFmt('Could not find test fixture %s', [AFileName]);
end;

function TSerialDeviceCollectorTests.LoadFixture(
  const AFileName: string
): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FindFixture(AFileName));
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.LinuxPatternsMatchSupportedPortClasses;
begin
  AssertTrue(MatchesLinuxSerialDevicePattern('/dev/ttyAMA0'));
  AssertTrue(MatchesLinuxSerialDevicePattern('/dev/rfcomm1'));
  AssertTrue(MatchesLinuxSerialDevicePattern('/dev/ttyUSB12'));
  AssertTrue(MatchesLinuxSerialDevicePattern('/dev/ttyACM3'));
end;

procedure TSerialDeviceCollectorTests.
  LinuxPatternsRejectUnsupportedPortClasses;
begin
  AssertFalse(MatchesLinuxSerialDevicePattern('/dev/ttyS0'));
  AssertFalse(MatchesLinuxSerialDevicePattern('/dev/ttyusb0'));
  AssertFalse(MatchesLinuxSerialDevicePattern('/tmp/ttyUSB0'));
  AssertFalse(MatchesLinuxSerialDevicePattern('/dev/cu.usbserial-1'));
end;

procedure TSerialDeviceCollectorTests.BuiltInSerialRequiresExistingDeviceNode;
begin
  AssertTrue(IsLinuxBuiltInSerialDevice('4', True));
  AssertTrue(IsLinuxBuiltInSerialDevice(' 4' + LineEnding, True));
  AssertFalse(IsLinuxBuiltInSerialDevice('4', False));
  AssertFalse(IsLinuxBuiltInSerialDevice('0', True));
  AssertFalse(IsLinuxBuiltInSerialDevice('', True));
end;

procedure TSerialDeviceCollectorTests.
  CollectorEnrichesDeduplicatesAndNaturalSorts;
var
  Collector: TFakeLinuxSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeLinuxSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/ttyUSB10');
    Collector.AddDevice('/dev/ttyACM0');
    Collector.AddDevice('/dev/ttyUSB2');
    Collector.AddDevice('/dev/ttyUSB2');
    Collector.AddDevice('');
    Collector.AddResponse(
      '/dev/ttyACM0',
      'ID_VENDOR_FROM_DATABASE=Espressif Systems' + LineEnding +
      'ID_MODEL=USB_JTAG_serial'
    );
    Collector.AddResponse('/dev/ttyUSB2', 'ID_MODEL=Second_adapter');
    Collector.AddResponse('/dev/ttyUSB10', 'ID_MODEL=Tenth_adapter');

    Devices := Collector.Collect;

    AssertEquals(3, Length(Devices));
    AssertEquals('/dev/ttyACM0', Devices[0].Device);
    AssertEquals('Espressif Systems', Devices[0].Vendor);
    AssertEquals('USB JTAG serial', Devices[0].Model);
    AssertEquals('/dev/ttyUSB2', Devices[1].Device);
    AssertEquals('Second adapter', Devices[1].Model);
    AssertEquals('/dev/ttyUSB10', Devices[2].Device);
    AssertEquals('Tenth adapter', Devices[2].Model);
    AssertEquals(3, Collector.ReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  CollectorDefaultModeDoesNotCheckAccessibility;
var
  Collector: TFakeLinuxSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeLinuxSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/ttyUSB0');
    Collector.AddDevice('/dev/ttyUSB1');
    Collector.AddAccessibleDevice('/dev/ttyUSB1');
    Collector.AddResponse('/dev/ttyUSB0', 'ID_MODEL=First_adapter');
    Collector.AddResponse('/dev/ttyUSB1', 'ID_MODEL=Second_adapter');

    Devices := Collector.Collect;

    AssertEquals(2, Length(Devices));
    AssertEquals(0, Collector.AccessibilityCheckCount);
    AssertEquals(2, Collector.ReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  CollectorAccessibleOnlyFiltersBeforeEnrichment;
var
  Collector: TFakeLinuxSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeLinuxSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/ttyUSB0');
    Collector.AddDevice('/dev/ttyUSB1');
    Collector.AddAccessibleDevice('/dev/ttyUSB1');
    Collector.AddResponse('/dev/ttyUSB0', 'ID_MODEL=Filtered_adapter');
    Collector.AddResponse('/dev/ttyUSB1', 'ID_MODEL=Available_adapter');

    Devices := Collector.Collect([sdeoAccessibleOnly]);

    AssertEquals(1, Length(Devices));
    AssertEquals('/dev/ttyUSB1', Devices[0].Device);
    AssertEquals('Available adapter', Devices[0].Model);
    AssertEquals(2, Collector.AccessibilityCheckCount);
    AssertEquals(1, Collector.ReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  CollectorPreservesDeviceWhenEnrichmentFails;
var
  Collector: TFakeLinuxSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeLinuxSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/ttyUSB0');
    Collector.AddResponse('/dev/ttyUSB0', 'ignored', False);

    Devices := Collector.Collect;

    AssertEquals(1, Length(Devices));
    AssertEquals('/dev/ttyUSB0', Devices[0].Device);
    AssertEquals('', Devices[0].Model);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  CollectorPreservesDeviceWhenPropertiesAreEmpty;
var
  Collector: TFakeLinuxSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeLinuxSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/ttyACM0');
    Collector.AddResponse('/dev/ttyACM0', '', True);

    Devices := Collector.Collect;

    AssertEquals(1, Length(Devices));
    AssertEquals('/dev/ttyACM0', Devices[0].Device);
    AssertEquals('', Devices[0].Vendor);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  CollectorContinuesAfterPropertyProviderException;
var
  Collector: TFakeLinuxSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeLinuxSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/ttyUSB0');
    Collector.AddDevice('/dev/ttyUSB1');
    Collector.AddResponse('/dev/ttyUSB0', '', False, True);
    Collector.AddResponse('/dev/ttyUSB1', 'ID_MODEL=Working_adapter');

    Devices := Collector.Collect;

    AssertEquals(2, Length(Devices));
    AssertEquals('/dev/ttyUSB0', Devices[0].Device);
    AssertEquals('', Devices[0].Model);
    AssertEquals('/dev/ttyUSB1', Devices[1].Device);
    AssertEquals('Working adapter', Devices[1].Model);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.DeviceLookupUsesLinuxCaseSensitiveNames;
var
  Devices: TSerialDeviceInfoArray;
begin
  Devices := nil;
  SetLength(Devices, 2);
  Devices[0].Device := '/dev/ttyACM0';
  Devices[1].Device := '/dev/ttyUSB0';

  AssertEquals(1, IndexOfSerialDevice(Devices, '/dev/ttyUSB0'));
  AssertEquals(-1, IndexOfSerialDevice(Devices, '/dev/ttyusb0'));
  AssertTrue(ContainsSerialDevice(Devices, '/dev/ttyACM0'));
  AssertFalse(ContainsSerialDevice(Devices, '/dev/ttyACM1'));
end;

procedure TSerialDeviceCollectorTests.
  WindowsCollectorDeduplicatesCaseInsensitivelyAndNaturalSorts;
var
  Collector: TFakeWindowsSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeWindowsSerialDeviceCollector.Create;
  try
    Collector.WmiSucceeds := True;
    Collector.WmiSnapshot :=
      'Caption=Tenth device (COM10)' + LineEnding + LineEnding +
      'Caption=Second device (COM2)' + LineEnding + LineEnding +
      'Caption=Duplicate device (com2)' + LineEnding;

    Devices := Collector.Collect;

    AssertEquals(2, Length(Devices));
    AssertEquals('COM2', Devices[0].Device);
    AssertEquals('Second device', Devices[0].Model);
    AssertEquals('COM10', Devices[1].Device);
    AssertEquals(0, Collector.RegistryReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.WindowsCollectorUsesRegistryFallback;
var
  Collector: TFakeWindowsSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeWindowsSerialDeviceCollector.Create;
  try
    Collector.AddRegistryDevice('COM10');
    Collector.AddRegistryDevice('com2');
    Collector.AddRegistryDevice('COM2');

    Devices := Collector.Collect;

    AssertEquals(2, Length(Devices));
    AssertEquals('com2', Devices[0].Device);
    AssertEquals('', Devices[0].Vendor);
    AssertEquals('', Devices[0].Model);
    AssertEquals('COM10', Devices[1].Device);
    AssertEquals(1, Collector.WmiReadCount);
    AssertEquals(1, Collector.RegistryReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  WindowsCollectorUsesRegistryForInvalidWmiSnapshot;
var
  Collector: TFakeWindowsSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeWindowsSerialDeviceCollector.Create;
  try
    Collector.WmiSucceeds := True;
    Collector.WmiSnapshot := 'Caption=Device without port';
    Collector.AddRegistryDevice('COM4');

    Devices := Collector.Collect;

    AssertEquals(1, Length(Devices));
    AssertEquals('COM4', Devices[0].Device);
    AssertEquals(1, Collector.RegistryReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  WindowsCollectorDoesNotReadRegistryWhenWmiHasPorts;
var
  Collector: TFakeWindowsSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeWindowsSerialDeviceCollector.Create;
  try
    Collector.WmiSucceeds := True;
    Collector.WmiSnapshot := 'Caption=WMI device (COM3)';
    Collector.AddRegistryDevice('COM8');

    Devices := Collector.Collect;

    AssertEquals(1, Length(Devices));
    AssertEquals('COM3', Devices[0].Device);
    AssertEquals(0, Collector.RegistryReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  WindowsCollectorFiltersAccessibleDevicesAfterEnumeration;
var
  Collector: TFakeWindowsSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeWindowsSerialDeviceCollector.Create;
  try
    Collector.WmiSucceeds := True;
    Collector.WmiSnapshot :=
      'Caption=Unavailable device (COM2)' + LineEnding + LineEnding +
      'Caption=Available device (COM3)' + LineEnding;
    Collector.AddAccessibleDevice('com3');

    Devices := Collector.Collect([sdeoAccessibleOnly]);

    AssertEquals(1, Length(Devices));
    AssertEquals('COM3', Devices[0].Device);
    AssertEquals(2, Collector.AccessibilityCheckCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  MacOSCollectorUsesOneSnapshotAndCanonicalAliases;
var
  Collector: TFakeMacOSSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeMacOSSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/tty.usbserial-ESP123456');
    Collector.AddDevice('/dev/cu.usbserial-ESP123456');
    Collector.AddDevice('/dev/tty.usbserial-ONLYTTY');
    Collector.AddDevice('/dev/cu.usbmodem-00200000');
    Collector.ProfilerSucceeds := True;
    Collector.ProfilerSnapshot := LoadFixture('macos-system-profiler.txt');

    Devices := Collector.Collect;

    AssertEquals(3, Length(Devices));
    AssertEquals('/dev/cu.usbmodem-00200000', Devices[0].Device);
    AssertEquals('USB Modem', Devices[0].Model);
    AssertEquals('/dev/cu.usbserial-ESP123456', Devices[1].Device);
    AssertEquals('USB JTAG/serial debug unit', Devices[1].Model);
    AssertEquals('/dev/tty.usbserial-ONLYTTY', Devices[2].Device);
    AssertEquals('', Devices[2].Model);
    AssertEquals(1, Collector.ProfilerReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.
  MacOSCollectorPreservesDevicesWhenProfilerFails;
var
  Collector: TFakeMacOSSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeMacOSSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/cu.usbserial-UNKNOWN');

    Devices := Collector.Collect;

    AssertEquals(1, Length(Devices));
    AssertEquals('/dev/cu.usbserial-UNKNOWN', Devices[0].Device);
    AssertEquals('', Devices[0].Vendor);
    AssertEquals('', Devices[0].Model);
    AssertEquals('', Devices[0].PersistentId);
    AssertEquals(1, Collector.ProfilerReadCount);
  finally
    Collector.Free;
  end;
end;

procedure TSerialDeviceCollectorTests.UnixCollectorReturnsDeviceOnlySnapshot;
var
  Collector: TFakeUnixSerialDeviceCollector;
  Devices: TSerialDeviceInfoArray;
begin
  Collector := TFakeUnixSerialDeviceCollector.Create;
  try
    Collector.AddDevice('/dev/ttyAM10');
    Collector.AddDevice('/dev/ttyAM2');
    Collector.AddDevice('/dev/ttyAM2');
    Collector.AddDevice('');

    Devices := Collector.Collect;

    AssertEquals(2, Length(Devices));
    AssertEquals('/dev/ttyAM2', Devices[0].Device);
    AssertEquals('', Devices[0].Vendor);
    AssertEquals('', Devices[0].Model);
    AssertEquals('/dev/ttyAM10', Devices[1].Device);
  finally
    Collector.Free;
  end;
end;

initialization
  RegisterTest(TSerialDeviceCollectorTests);

end.
