unit LazSerialCommon;

interface

uses
  {LazSynaSer,}
  Classes, SysUtils, LazStringUtils, Registry, math, Dialogs, StrUtils
  {$ifNdef windows}, process {$endif};

resourcestring
  lngAddedPorts = 'Added ports: ';
  lngRemovedPorts = 'Removed ports: ';
  lngNoDevicesAvailable =  'No devices available';
  lngErrorSign = #$E2 + #$9A + #$A0;
  lngDuplicated = 'Duplicated';
  lngOR = ' OR ';
  lngSerNo = 'Ser№';

  lngBuiltInSerial =                        'Built-in Serial';
  lngBluetoothSerial =                      'Bluetooth Serial';
  lngVirtualDevice =                        'Virtual device';
  lngUSBSerialUnknown =                     'USB Serial (unknown)';
  lngUSBSerialFTDI =                        'USB FTDI';
  lngUSBSerialFT232 =                       'USB FT232';
  lngUSBSerialProlific =                    'USB Prolific';
  lngUSBSerialCH34x =                       'USB CH34x';
  lngUSBSerialCH340 =                       'USB CH340';
  lngUSBSerialCH341 =                       'USB CH341';
  lngUSBSerialCH343 =                       'USB CH343';
  lngUSBSerialSTM =                         'USB STM';
  lngUSBSiliconLabs =                       'USB Silicon Labs';
  lngUSBSiliconLabsCP210x =                 'USB Silicon Labs CP210x';
  lngUSBSerialArduino =                     'USB Arduino';
  lngUSBSerialArduinoISP =                  'USB Arduino ISP';
  lngUSBSerialArduinoLeonardo =             'USB Arduino Leonardo';
  lngUSBSerialArduinoMega_ADK_R3 =          'USB Arduino Mega ADK R3';
  lngUSBSerialArduinoSerial_R3 =            'USB Arduino Serial R3';
  lngUSBSerialArduinoMega_2560_R3 =         'USB Arduino Mega 2560 R3';
  lngUSBSerialArduinoUno_R3 =               'USB Arduino Uno R3';
  lngUSBSerialArduinoDue =                  'USB Arduino Due';
  lngUSBSerialArduinoMega_ADK =             'USB Arduino Mega ADK';
  lngUSBSerialArduinoSerial_Adapter =       'USB Arduino Serial Adapter';
  lngUSBSerialArduinoDue_Programming_Port = 'USB Arduino Due Programming Port';
  lngUSBSerialArduinoMega_2560 =            'USB Arduino Mega 2560';
  lngUSBSerialArduinoLeonardo_Bootloader =  'USB Arduino Leonardo Bootloader';
  lngUSBSerialArduinoUno =                  'USB Arduino Uno';
  lngMT65xx_Preloader =                     'MT65xx Preloader';
  lngHPun2420MobileBroadbandModuleModem =   'HP un2420 Mobile Broadband Module Modem';
  lngUSBGwInstek =                          'USB GwInstek';

  //Flow Control
  lngNone = 'None';
  lngXonXoff_DTR = 'XonXoff w DTR';
  lngRTS_CTS = 'RTS CTS';
  lngXonXoff = 'XonXoff w/o DTR';
  lngXonXoff_and_RTS_CTS = 'XonXoff RTS CTS';
  lngDTR_DSR = 'DTR DSR';
  lngXonXoff_and_DTR_DSR = 'XonXoff DTR DSR';
  lngDTR = 'DTR';

  //Parity
  lngOdd = 'Odd';
  lngEven = 'Even';
  lngMark = 'Mark';
  lngSpace = 'Space';

type
  Integer1D = array of integer;
  String1D = array of string;
  TSSOption  = (ssoAppendFriendlyNames, ssoUseWMI, ssoHide_tty_usbserial, ssoAppendSerialNumber, ssoAppendErrorCode);
  TSSOptionS = set of tSSOption;
   tVIDPIDID = record
     VID_PID : string;
     ID : String; //TODO: Is this used ?
     EnumKeyName : String;
     SerialN : string;
     ErrorCode : string;
   end;
   tVIDPIDID_1D = array of tVIDPIDID;
   //TFlowControl=(fcNone,fcXonXoff,fcHardware); //ver ≤ 0.6
   //In fcXonXoff is actually XonXoff_and_DTR. For legacy reasons this ambuguous name is kept. Note: usualy XonXoff goes with DTR
   //fcHardware = RTS CTS
   TFlowControl=(fcNone=0, fcXonXoff=1, fcHardware=2, fcXonXoff_no_DTR=3,fcXonXoff_and_RTS_CTS=4, fcDTR_DSR=5, fcXonXoff_and_DTR_DSR=6, fcDTR=7,
                 fcXonXoff_and_DTR=1, fcRTS_CTS = 2);

const
  Cr = #$0d;
  Lf = #$0a;
  CrLf = Cr + Lf;
  Tab = #9;
  cSerialChunk = 8192;

procedure FindAddedPorts (const OldPorts: TStringList; const NewPorts: TStringList; out AddedPorts: TStringList);
procedure FindRemovedPorts (const OldPorts: TStringList; const NewPorts: TStringList; out RemovedPorts: TStringList);
procedure SortPorts(aDeviceList : tStringList);
function GetFriendlyName (aDevice: string; AppendSerNum: Boolean = True{$ifdef windows}; Details: string=''; AppendErrorCode : Boolean = True{$endif}): string;
{$ifdef windows}
function GetFriendlyNameDevID(Device: string; Details: string; AppendSerNum: boolean; AppendError : Boolean {= True}) : string;
{$endif}
function SearchStringList(aStringList: TStringList; SoughtString: string; CaseSensitive : Boolean = false): integer;
{$IF FPC_FULLVERSION >= 30002}
function NaturalSortCompare(List: TStringList; Index1, Index2: Integer): Integer;
{$endif}

implementation

//TODO: Add support for VENxxxx / DEVxxxx
function VID_PID_ToString(aVID_PID: String): string;
var
  VID: string = '';
begin
  Result := aVID_PID;
  if (aVID_PID = '') then exit;
  case lowercase(aVID_PID) of
    'vid_0403pid_6001' : exit (lngUSBSerialFT232);
    'vid_1a86pid_7523' : exit (lngUSBSerialCH340);
    'vid_1a86pid_5523' : exit (lngUSBSerialCH341);
    'vid_1a86pid_55d3' : exit (lngUSBSerialCH343);
    'vid_067bpid_2303' : exit (lngUSBSerialProlific);
    'vid_0483pid_5740' : exit (lngUSBSerialSTM);
    'vid_2341pid_0049' : exit (lngUSBSerialArduinoISP);
    'vid_2341pid_8036' : exit (lngUSBSerialArduinoLeonardo);
    'vid_2341pid_0044' : exit (lngUSBSerialArduinoMega_ADK_R3);
    'vid_2341pid_0045' : exit (lngUSBSerialArduinoSerial_R3);
    'vid_2341pid_0042' : exit (lngUSBSerialArduinoMega_2560_R3);
    'vid_2341pid_0043' : exit (lngUSBSerialArduinoUno_R3);
    'vid_2341pid_003e' : exit (lngUSBSerialArduinoDue);
    'vid_2341pid_003f' : exit (lngUSBSerialArduinoMega_ADK);
    'vid_2341pid_003b' : exit (lngUSBSerialArduinoSerial_Adapter);
    'vid_2341pid_003d' : exit (lngUSBSerialArduinoDue_Programming_Port);
    'vid_2341pid_0010' : exit (lngUSBSerialArduinoMega_2560);
    'vid_2341pid_0036' : exit (lngUSBSerialArduinoLeonardo_Bootloader);
    'vid_2341pid_0001' : exit (lngUSBSerialArduinoUno);
    'vid_10c4pid_ea60' : exit (lngUSBSiliconLabsCP210x);
    'vid_2184pid_0040' : exit (lngUSBGwInstek);
    'vid_03F0pid_251D' : exit (lngHPun2420MobileBroadbandModuleModem);
    'vid_0e8dpid_2000' : exit (lngMT65xx_Preloader);
    'btbt'             : exit (lngBluetoothSerial);
    'port'             : exit (lngVirtualDevice);
  end;
  VID := lowercase(LeftStr(aVID_PID,pos('pid',lowercase(aVID_PID))-1));
  case  VID of
    'vid_0403' : exit (lngUSBSerialFTDI);
    'vid_1a86' : exit (lngUSBSerialCH34x);
    'vid_067b' : exit (lngUSBSerialProlific);
    'vid_0483' : exit (lngUSBSerialSTM);
    'vid_2341' : exit (lngUSBSerialArduino);
    'vid_10c4' : exit (lngUSBSiliconLabs);
    'vid_2184' : exit (lngUSBGwInstek);
  end;
end;

{$IfDef Linux}
function GetFriendlyNameLinux (PortName: String; AppendSerialNumber: Boolean = True) : String;
var
  RunOutput: string = '';
  StartPos: integer = 0;
  EndPos: integer = 0;
  SNum: string = '';
begin
  Result := '';
  if not RunCommand('udevadm info -q property ' + PortName,RunOutput) then exit;
  StartPos := pos('ID_MODEL_FROM_DATABASE=',RunOutput);
  if (StartPos = 0) then
    if PortName.StartsWith('/dev/ttyS')
      then exit(lngBuiltInSerial)
      else exit;
  StartPos := StartPos + Length('ID_MODEL_FROM_DATABASE=');
  EndPos:= pos(#10,RunOutput,StartPos+1);
  Result := copy(RunOutput,StartPos, EndPos - StartPos);
  if AppendSerialNumber then
  begin
    StartPos := 0;
    StartPos := pos('ID_USB_SERIAL_SHORT=',RunOutput); //Serial devices rarely have serial numbers
    if (StartPos > 0) then
      begin
        StartPos := StartPos + Length('ID_USB_SERIAL_SHORT=');
        EndPos:= pos(#10,RunOutput,StartPos+1);
        SNum := trim(copy(RunOutput,StartPos, EndPos - StartPos));
        if (SNum <> '') then Result := Result + ' ' + SNum;
      end; //if startpos
  end; //if AppendSerialNumber
end;
{$EndIf}

{$ifdef darwin}
//TODO: Currently FT232 are not found
function FindDevice(aString1D: array of string; Device : String) : String;
const
  LeadSpaces : string = '        ';
var
  LineI: integer = 0;
  SectionStart: integer = -1;
  SectionEnd: integer = 0;
  Token : string = '';
  j: integer;
  wdi: integer = 0;
  Vid : string ='';
  Pid : string ='';
begin
  Result := '';
  if Length(aString1D) = 0 then exit;
  //Token might be either the serial number or the Location ID
  Token := copy(Device,rpos('-',Device)+1,MaxInt);

   repeat
    SectionStart := 0;
    for LineI := SectionEnd to High(aString1D) do
      if aString1D[LineI].StartsWith(LeadSpaces,True) and (aString1D[LineI][Length(LeadSpaces)+1] <> ' ')
        then begin SectionStart := LineI; break; end;
    if (SectionStart = 0) then break;

    if Length(aString1D) > (LineI + 2) then
    begin
      for LineI := (LineI + 2) to High(aString1D) do
        if aString1D[LineI] = '' then begin SectionEnd := LineI -1; break; end;
    end;

    if (SectionEnd > SectionStart + 2) then
      For LineI := (SectionStart +2) to SectionEnd do
        if (aString1D[LineI].EndsWith(Token,False) = True)
        or (pos('0x'+ LowerCase(Token),lowercase(aString1D[LineI])) > 0) then
          begin //This is the device, now find the fiendly name
            for j := (SectionStart+2) to SectionEnd do
              if trim(aString1D[j]).StartsWith('Manufacturer:',true) then
                exit(trim(copy(aString1D[j],Pos('manufacturer:',lowercase(aString1D[j]))+ Length('manufacturer:'))));

            //'Vendor ID:' is not present for all devices
            for j := (SectionStart+2) to SectionEnd do
              if trim(aString1D[j]).StartsWith('Vendor ID:',true)
                then begin Vid:= trim(copy(aString1D[j],Pos('vendor id:',lowercase(aString1D[j]))+ Length('vendor id:'))); break; end;
                //then exit(trim(copy(aString1D[j],Pos('vendor id:',lowercase(aString1D[j]))+ Length('vendor id:'))));
            for j := (SectionStart+2) to SectionEnd do
              if trim(aString1D[j]).StartsWith('Product ID:',true)
                then begin Pid:= trim(copy(aString1D[j],Pos('product id:',lowercase(aString1D[j]))+ Length('product id:'))); break; end;
          end;
   inc(wdi); //prevent an endless loop
   until (SectionStart = 0) or (wdi>255);
   //end; //for DevI
   if (Vid <> '') then Vid := StringReplace(Vid,'0x','vid_',[rfReplaceAll,rfIgnoreCase]);
   if (Pid <> '') then Pid := StringReplace(Pid,'0x','pid_',[rfReplaceAll,rfIgnoreCase]);
   result := Vid + Pid;
end;

Function GetFriendlyNameDarwin (PortName: String) : String;
const
  LeadSpace = '        ';
var
  RunOutput: string = '';
begin
  Result := '';
  if not RunCommand('system_profiler SPUSBDataType',RunOutput) then exit;
  Result := FindDevice(RunOutput.Split([Lf]), PortName);
  if Result.startswith('vid',True) then result := VID_PID_ToString(Result);
end;
{$endif}

{$ifdef windows}
//None of the methods of reading key values from registry is reliable,
//Windows readily messes the keys when multiple Serial devices are used


//Retrieves a CustomFrienlyName from the HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM
//Note that these values might not be unique. Use as last resort, if GetCustomFrienlyName_VID_PID returns nothing
function GetCustomFriendlyName_SERIALCOMM(PortName: string; var Unique: Boolean): string;
var
  Registry : TRegistry;
  RegNames : TStringList;
  i: integer;
begin
  Result := '';
  Unique := False;
  RegNames := TStringList.Create;
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    if Registry.OpenKey('\HARDWARE\DEVICEMAP\SERIALCOMM',False) then
    begin
      Registry.GetValueNames(RegNames);
      if (RegNames.Count >0) then
        for i := 0 to RegNames.Count -1 do
          if (registry.ReadString(RegNames[i])= PortName) then
          begin
            if RegNames[i].StartsWith('\Device\VCP',True) then begin Result := lngUSBSerialFTDI; Unique := True; end else
            if RegNames[i].StartsWith('\Device\ProlificSerial',True) then begin Result := lngUSBSerialProlific ; Unique := True; end else
            if RegNames[i].StartsWith('\Device\Silabser',True) then begin Result := lngUSBSiliconLabs; Unique := True; end else
            if RegNames[i].StartsWith('\Device\BthModem',True) then begin Result := lngBluetoothSerial ; Unique := True; end else
            if RegNames[i].StartsWith('\Device\USBSER',True) then Result := lngUSBSerialUnknown else //Might be USBSerialSTM or Arduino Leonardo or maybe even sth. else
            if RegNames[i].StartsWith('\Device\Serial',True) then
            begin //\Device\Serial
              if uppercase(PortName) = 'COM1' then
                Result := lngBuiltInSerial else
                Result := lngUSBSerialCH340;
            end;//\Device\Serial
            Break;
          end; //if
    end; //registry Open
  finally
    Registry.Free;
  end;
  RegNames.Free;
end;

procedure InitVIDPIDID(var aVIDPIDID : tVIDPIDID);
begin
  aVIDPIDID.VID_PID := '';
  aVIDPIDID.ID := '';
  aVIDPIDID.EnumKeyName := '';
  aVIDPIDID.SerialN := '';
  aVIDPIDID.ErrorCode := '0';
end;

//Get the VID, PID, etc. data for the serial device from HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\COM Name Arbiter\Devices
//There are chances, that the device is listed there but values in COM Name Arbiter might not be updated, probably SearchVID_PID returns more reliable data
function GetVID_PID_Arbiter (PortName : string) : tVIDPIDID;
var
  Registry : TRegistry;
  Contents : array of String;
  PortType: String = '';
begin
  InitVIDPIDID(Result);
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    //NOTE: Devices might be missing from HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\COM Name Arbiter\Devices
    if Registry.OpenKey('\SYSTEM\ControlSet001\Control\COM Name Arbiter\Devices',False) then
    begin
      Contents := Registry.ReadString(PortName).Split(['#']);
      if (Length(Contents) > 2) then
      begin
        PortType := Copy(Contents[0],5,MaxInt) ;
        Result.VID_PID := Contents[1];
        Result.ID := Contents[2];
        Result.EnumKeyName := '\SYSTEM\ControlSet001\Enum\' + PortType + '\' + Result.VID_PID + '\' + Result.ID;
      end; //if
    end; //registry
  finally
    Registry.free;
  end;
end;

function GetVID_PIDS_Serial(DeviceID: string): tVIDPIDID;
var
  mRegPos: string = '';
  SupportsSerial: Boolean = False;
begin
  InitVIDPIDID(Result);
  if DeviceID.StartsWith('BTHENUM',true) then exit;
  mRegPos := DeviceID.Replace('+PID','&PID',[rfIgnoreCase]);
  mRegPos := Copy(mRegPos,Pos('\',mRegPos)+1,MaxInt);
  mRegPos := LeftStr(mRegPos,Pos('\',mRegPos)-1);

  if mRegPos.StartsWith('vid_10c4',True)
  or mRegPos.StartsWith('vid_0483',True)
  or mRegPos.StartsWith('vid_0403',True)
    then SupportsSerial := True;

  if (pos('+',mRegPos) > 0) then
  begin
    Result.SerialN := copy(mRegPos,pos('+',mRegPos)+1,MaxInt);
    if DeviceID.StartsWith('ftdibus',True) and Result.SerialN.EndsWith('a',True) then
       Result.SerialN := LeftStr(Result.SerialN,Length(Result.SerialN) -1); //The end of the serial № of FTDI devices is terminated with 'a#'. Maybe valid for other devices, which support serial numbers.
    Result.VID_PID := (LeftStr(mRegPos,pos('+',mRegPos)-1)).Replace('&','');
  end
  else
  begin
    if (mRegPos.CountChar('&')<2)
      then Result.VID_PID := mRegPos.Replace('&','')
      else Result.VID_PID := mRegPos.Split(['&'])[0] + mRegPos.Split(['&'])[1];
  end;

  if (Result.SerialN = '') and (SupportsSerial = True) and (DeviceID.CountChar('\') = 2) then
    Result.SerialN := DeviceID.Split(['\'])[2]; //STM *pills and Silicon Labs (CP2102...) use this way

  Result.EnumKeyName := mRegPos;
end;

//When Windows assigns the same COM number to more than one device, the friendly data is not retrieved properly. This should never happen, but Windows does it.
//AppendError - appends Error code is <> 0
function GetFriendlyNameDevID(Device: string; Details: string; AppendSerNum: boolean; AppendError : Boolean {= True}) : string;
var
  Registry : TRegistry;
  LineI : integer = 0;
  DetArray : array of string;
  DeviceID : string;
  SerialN: string = '';
  Duplicated : Boolean = false;
  ResultI : string = ''; //Result from te current loop
  ItemDetails: String1D;
  ErrorCode : string = '0';
begin
  Result := '';
  if (Device = '') or (Details = '') then exit;
  DetArray := Details.Split([#13]);
  for LineI := 0 to high(DetArray) do
    begin
      ResultI := '';
      Duplicated := False;
      if (Result <> '') then
        Duplicated := True; //Windows has assigned the same name to multiple devices
      if DetArray[LineI].StartsWith(Device+Tab,true) then
      begin
        ItemDetails := DetArray[LineI].Split([Tab]);
        if (Length(ItemDetails) > 0) then
          DeviceID := ItemDetails[1]; // Copy(DetArray[LineI],length(Device)+2,MaxInt);
        if (Length(ItemDetails) > 1) then
          ErrorCode := ItemDetails[2];

        SerialN := GetVID_PIDS_Serial(DeviceID).SerialN;
        ResultI := VID_PID_ToString(GetVID_PIDS_Serial(DeviceID).VID_PID); //Separate the multiple devices with Tab (#09)

        if (ResultI = '') or (ResultI = GetVID_PIDS_Serial(DeviceID).VID_PID) then
        begin
          Registry := TRegistry.Create(KEY_READ);
          try
            Registry.RootKey := HKEY_LOCAL_MACHINE;
            if  Registry.OpenKey('SYSTEM\ControlSet001\Enum\' + DeviceId,false)  then
              ResultI := Registry.ReadString('FriendlyName');
              if ResultI.EndsWith(' ('+Device+')') then
                ResultI := LeftStr(ResultI,length(ResultI)- length(' ('+Device+')'));
          finally
            Registry.Free;
          end; //try
        end; //if Result
        if ((SerialN <> '') and (AppendSerNum = true))
          then ResultI :=  ResultI + ' ' + lngSerNo + SerialN;
        if (AppendError = True) and (ErrorCode <> '0')
          then ResultI :=  ResultI + lngErrorSign + ErrorCode;
      end; //if detarray
      if (ResultI <> '') then
        Result := BoolToStr(Duplicated, Result + lngOr + ResultI + lngErrorSign + lngDuplicated,ResultI); //separate data for duplicated COM ports with TAB  (#09)
    end; //for lineI
end;


//Us if the device is NOT listed in HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\COM Name Arbiter\Devices
Function SearchVID_PID(Device: string): tVIDPIDID_1D;

  Procedure GetUSBKeys(aStringList: tstringlist; DeviceType: String);
  var
    Registry : TRegistry;
  begin
   Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_LOCAL_MACHINE;
      if Registry.OpenKey('\SYSTEM\ControlSet001\Enum\' + DeviceType +'\',False) then
        Registry.GetKeyNames(aStringList);
    finally
      Registry.Free;
    end; //try
  end;

  Procedure GetUSBSubKeys(aStringList: tstringlist; Key: string; DeviceType: String);
  var
    Registry : TRegistry;
  begin
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_LOCAL_MACHINE;
      if Registry.OpenKey('\SYSTEM\ControlSet001\Enum\' + DeviceType +'\' + Key,False) then
        Registry.GetKeyNames(aStringList);
    finally
      Registry.Free;
    end; //try
  end;//Procedure GetUSBSubKeys

const
  DeviceType : array of string = ('USB','FTDIBUS','BTHENUM'); //TODO: Shall the entire ENUM be searched? //TODO: 'BTHENUM' do NOT have Vid_Pid but some other number
var
  Registry : TRegistry;
  USBKeys : TStringList;
  SubKeys: TStringList;
  i: integer = 0;
  j: integer = 0;
  DTypeIndex: integer = 0;
  PortName : string ='';
  Found : boolean = False;
begin
  SetLength (Result,0);

  USBKeys := TStringList.Create;
  SubKeys := TStringList.Create;
  for DTypeIndex := 0 to high(DeviceType) do
  begin
    GetUSBKeys(USBKeys, DeviceType[DTypeIndex]);
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_LOCAL_MACHINE;
      if (USBKeys.Count > 0) then
      for i:=0 to (USBKeys.Count-1) do
      begin
        GetUSBSubKeys(SubKeys,USBKeys.Strings[i],DeviceType[DTypeIndex]);
        Found := False;
        if (SubKeys.Count > 0) then
          for j:= 0 to (SubKeys.Count-1) do
          begin
            if Registry.OpenKey('\SYSTEM\ControlSet001\Enum\' + DeviceType[DTypeIndex] + '\'+ USBKeys.Strings[i] +'\'+SubKeys.Strings[j]+'\Device Parameters',False) then
              begin
               PortName := '';
               PortName := Registry.ReadString('PortName');
               if (PortName <> '') then
                 if (LowerCase(PortName) = LowerCase(Device)) then
                   if Registry.OpenKey('\SYSTEM\ControlSet001\Enum\' + DeviceType[DTypeIndex] + '\'+ USBKeys.Strings[i] +'\'+SubKeys.Strings[j],False) then
                     begin
                       SetLength(Result,Length(Result)+1);
                       InitVIDPIDID(Result[high(Result)]);
                       if (DeviceType[DTypeIndex] = 'BTHENUM')
                         then Result[high(Result)].VID_PID := 'BT&BT' //'BTHENUM' does not have VID_PID
                         else Result[high(Result)].VID_PID := USBKeys.Strings[i];
                       Result[high(Result)].EnumKeyName :=  '\SYSTEM\ControlSet001\Enum\' + DeviceType[DTypeIndex] + '\' + USBKeys.Strings[i] {+ TODO: Is there anything more?} ;
                       Found := True;
                     end;
              end; //Registry.OpenKey
              if Found then break;
          end; //for j
  //      if Found then break;
      end; //for i
{      if found then
      begin
       if (DeviceType[DTypeIndex] = 'BTHENUM')
         then
           Result.VID_PID := 'BT&BT' //'BTHENUM' does not have VID_PID
         else
         Result.VID_PID := USBKeys.Strings[i];
      //Result.ID  ; //TODO: add sth. here if needed
        Result.EnumKeyName :=  '\SYSTEM\ControlSet001\Enum\' + DeviceType[DTypeIndex] + '\' + USBKeys.Strings[i] {+ TODO: Is there anything more?} ;
      end; //if Found }
    finally
      Registry.free; //Sometimes crashes here
    end;
    if Found then break;
  end; //for DTtypeIndex
  USBKeys.Free;
  SubKeys.Free;
end;

//Finds the most probable value between GetVID_PID_Arbiter and SearchVID_PID
//If a single entry is found in HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Enum then it is the result.
//If multiple values are found there, the entry is also sought in HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\COM Name Arbiter\Devices
//If one of the entries from Enum is the same as the one from Arbiter, it is returned.
function GetVID_PID(PortName : string): tVIDPIDID;
var
  msVID_PID_DATA : tVIDPIDID_1D; //sought data
  meVID_PID_DATA : tVIDPIDID; //data from Enum
  i : integer;
begin
  InitVIDPIDID(Result);
  InitVIDPIDID(meVID_PID_DATA);
  msVID_PID_DATA := SearchVID_PID(PortName);
  if (Length(msVID_PID_DATA) = 1) then Exit(msVID_PID_DATA[0]);

  meVID_PID_DATA := GetVID_PID_Arbiter(PortName);

  if (Length(msVID_PID_DATA)=0) and (meVID_PID_DATA.VID_PID = '') then exit; //Device not found at all
  if (Length(msVID_PID_DATA) >1) and (meVID_PID_DATA.VID_PID <> '') then
    for i := 0 to high(msVID_PID_DATA) do
      if lowercase(msVID_PID_DATA[i].VID_PID) = (LowerCase(meVID_PID_DATA.VID_PID))
        then Exit(meVID_PID_DATA); //Otherwise empty result is returned
end;



//Retrieves a CustomFrienlyName from the VID_PID of the device.
//Note that VID and PID might not be available
function GetCustomFriendlyName_VID_PID(PortName : string): string;
var
  arrVID_PID : array of String;
  mVID_PID : string;
  mVID_PID_DATA : tVIDPIDID; //data from Enum}
begin
  Result := '';
  mVID_PID_DATA := GetVID_PID(PortName);
  arrVID_PID := mVID_PID_DATA.VID_PID.Split(['+','&']);
  if (Length(arrVID_PID)<2) then exit;
  mVID_PID := arrVID_PID[0] + arrVID_PID[1];
  Result := VID_PID_ToString(mVID_PID);
end;

function GetCustomFriendlyName_VendorID(VendorID : string): string;
begin
  Result := VendorID;
  case lowercase(VendorID) of
    '0x0403' : exit (lngUSBSerialFTDI);
    '0x0403  (Future Technology Devices International Limited)' : exit (lngUSBSerialFTDI);
    '0x1a86' : exit (lngUSBSerialCH340);
  end;
end;

//HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Enum
function GetComFriendlyName_Enum (PortName : string) : String;
var
  Registry : TRegistry;
  mVID_PID_DATA : tVIDPIDID;
begin
  Result := '';
  mVID_PID_DATA := GetVID_PID(PortName);
  if (mVID_PID_DATA.EnumKeyName = '') then exit;
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    if Registry.OpenKey(mVID_PID_DATA.EnumKeyName,False) then
    begin
      Result := Registry.ReadString('FriendlyName');
      //Usually friendly names in Windows duplicate the name of the port at the end
      if Result.EndsWith(' (' + PortName + ')',False) then
        Result := LeftStr(Result, max(0,length(Result)-length(' (' + PortName + ')')));  //Remove the name of the port
    end;//if Registry.OpenKey
  finally
    Registry.Free;
  end; //try
end;
//TODO: HKEY_LOCAL_MACHINE\SYSTEM\Setup\Upgrade\PnP\CurrentControlSet\Control\DeviceMigration\Devices\USB\VID_0483&PID_5740\4E874D504800   \BusDeviceDesc might provide better data
{$endif}

{$ifdef darwin}
//Removes devices starting with /dev/tty.usbserial if duplicated by devices starting with /dev/cu.usbserial
procedure RemoveTTY(var aDeviceList: TStringList);
var
  i : integer;
begin
  if (aDeviceList.Count = 0) then exit;

  for i:= aDeviceList.Count -1 downto 0 do
  begin
    if ((aDeviceList.Strings[i].StartsWith ('/dev/tty.usbserial',false) = true)
    or (aDeviceList.Strings[i].StartsWith ('/dev/tty.usbmodem',false) = true)) then
     aDeviceList.delete(i);
  end;
end;
{$endif} //darwin


procedure FindAddedPorts (const OldPorts: TStringList; const NewPorts: TStringList; out AddedPorts: TStringList);
var
  i, j : integer;
  PortFound : boolean = False;
begin
  if (NewPorts.Count > 0) and (OldPorts.DelimitedText = NewPorts.DelimitedText) then exit; //Sometimes UpdateComPorts is executed more than once

  AddedPorts.Clear;
  AddedPorts.StrictDelimiter := True;
  AddedPorts.Delimiter := Cr;

  for i:= 0 to (NewPorts.Count - 1) do
  begin
    PortFound := False;
    if (OldPorts.Count > 0) then
      for j:= 0 to (OldPorts.Count -1 ) do
      begin
        if NewPorts.Strings[i] = OldPorts.Strings[j] then
        begin
          PortFound := True;
//          FRemovedPorts := '';
          break;
        end;
      end; //for j
    if not PortFound then
      AddedPorts.Add(NewPorts.Strings[i])  ;
  end;  //for i
end;

procedure FindRemovedPorts (const OldPorts: TStringList; const NewPorts: TStringList; out RemovedPorts: TStringList);
var
  i, j : integer;
  PortFound : boolean = False;
begin
  if (NewPorts.Count > 0) and (OldPorts.DelimitedText = NewPorts.DelimitedText) then exit; //Sometimes UpdateComPorts is executed more than once

  RemovedPorts.Clear;
  RemovedPorts.StrictDelimiter := True;
  RemovedPorts.Delimiter := Cr;
  if (OldPorts.Count < 1) then exit;
  for i:= 0 to (OldPorts.Count - 1) do
  begin
    PortFound := False;
    if (NewPorts.Count < 1)
      then PortFound := False
    else
      for j:= 0 to (NewPorts.Count - 1) do
      begin
        if OldPorts.Strings[i] = NewPorts.Strings[j] then
        begin
          PortFound := True;
//        FAddedPorts := '';
          break;
        end;
      end; //for j
    if not PortFound then
      RemovedPorts.Add(OldPorts.Strings[i]);
  end;  //for i
end;

//The head multiplatform routine, which decides which subroutine to use
//function GetFriendlyName (aDevice: string; Details : string = ''): string;
function GetFriendlyName (aDevice: string; AppendSerNum: Boolean = True{$ifdef windows}; Details: string=''; AppendErrorCode : Boolean = True{$endif}): string;
var
  Unique: boolean = false;
begin
  {$ifdef windows}
  //This is the most reliable method, the ones below are in case it fails.
  if (Details <> '') then
    begin
      Result := GetFriendlyNameDevID(aDevice, Details,AppendSerNum,AppendErrorCode);
      if (Result <> '') then exit;
    end;

  Result := GetCustomFriendlyName_SERIALCOMM(aDevice,Unique);
  if (Unique = False) then
  begin
    //Try all 3 methods, hopefully some of them will provide a result
    //None of them is reliable
    Result := GetCustomFriendlyName_VID_PID(aDevice);
    if (Result = '') then
      Result := GetComFriendlyName_Enum (aDevice);
    if (Result = '') then
      Result := GetCustomFriendlyName_SERIALCOMM(aDevice,Unique);
  end; //if (Unique = False)
  {$endif}
  {$ifdef linux}
  Result := GetFriendlyNameLinux(aDevice,AppendSerNum);
  {$endif}
  {$ifdef darwin}
  Result := GetFriendlyNameDarwin(aDevice);
  {$endif}
  {$ifNdef linux}
  {$ifNdef windows}
  {$ifNdef darwin}
  aDeviceListFriend.Append(aDevice);
  {$endif}
  {$endif}
  {$endif}
end;


//TODO: This might cause issues on Linux
function SearchStringList(aStringList: TStringList; SoughtString: string; CaseSensitive : Boolean = false): integer;
var
  i: integer;
  mSoughtString : string = '';
begin
  Result := -1;
  if (aStringList.Count = 0) then exit;
  if not CaseSensitive
    then mSoughtString := LowerCase(SoughtString)
    else mSoughtString := SoughtString;
  for i:=0 to aStringList.Count -1 do
    if CaseSensitive  then
      begin
        if (mSoughtString = aStringList[i]) then exit(i)
      end
      else if (mSoughtString = lowercase(aStringList[i])) then exit(i);
end;


{$IF FPC_FULLVERSION >= 30002}
function NaturalSortCompare(List: TStringList; Index1, Index2: Integer): Integer;
begin
  Result := NaturalCompareText(List[Index1], List[Index2]);
end;
{$endif}

procedure SortPorts(aDeviceList : tStringList);
begin
  {$ifdef darwin}aDeviceList.Sort;{$endif}
  {$ifdef windows}{$IF FPC_FULLVERSION >= 30002}aDeviceList.CustomSort(@NaturalSortCompare);{$endif}{$endif}
  {$ifdef linux}{$IF FPC_FULLVERSION >= 30002}aDeviceList.CustomSort(@NaturalSortCompare);{$endif}{$endif}
end;
end.
