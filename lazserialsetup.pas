(******************************************************
 * lazSerialSetup                                     *
 *                                                    *
 * written by Jurassic Pork  O3/2013                  *
 * based on TComport TcomSetupFrm                     *
 *****************************************************)

unit lazserialsetup;

{$mode objfpc}{$H+}



interface

uses
  LCLIntf, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  StdCtrls, ExtCtrls, Buttons, lazSerial,
  SerialSelector, LazSerialCommon;

type
  TComPortSettings = record
    Device: string;
    BaudRate: TBaudRate;
    DataBits: TDataBits;
    StopBits: TStopBits;
    Parity: TParity;
    FlowControl: TFlowControl;
  end;

  // TLazSerial setup dialog

  { TComSetupFrm }

  TComSetupFrm = class(TForm)
    Button1: TButton;
    Button2: TButton;
    SerialSelector1:TSerialSelector;
    ComComboBox2: TComboBox;
    ComComboBox3: TComboBox;
    ComComboBox4: TComboBox;
    ComComboBox5: TComboBox;
    ComComboBox6: TComboBox;
    GroupBox1: TGroupBox;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    Label6: TLabel;
    procedure FormCreate(Sender: TObject);
  private
    { Private declarations }
  public
    procedure LoadSettings(const ASettings: TComPortSettings);
    function ReadSettings: TComPortSettings;
  end;

procedure EditComPort(ComPort: TLazSerial);
procedure ApplyComPortSetupResult(ComPort: TLazSerial;
  SetupForm: TComSetupFrm; const AModalResult: TModalResult);
function ReadComPortSettings(ComPort: TLazSerial): TComPortSettings;

// conversion functions
function StrToBaudRate(Str: string): TBaudRate;
function StrToStopBits(Str: string): TStopBits;
function StrToDataBits(Str: string): TDataBits;
function StrToParity(Str: string): TParity;
function StrToFlowControl(Str: string): TFlowControl;
function BaudRateToStr(BaudRate: TBaudRate): string;
function StopBitsToStr(StopBits: TStopBits): string;
function DataBitsToStr(DataBits: TDataBits): string;
function ParityToStr(Parity: TParity): string;
function FlowControlToStr(FlowControl: TFlowControl): string;

implementation

uses lazsynaser;

{$R *.lfm}

const
{$IFDEF UNIX}
  BaudRateStrings: array[TBaudRate] of string =
    ('0', '50', '75', '110', '134', '150', '200', '300', '600', '1200', '1800',
    '2400', '4800', '9600', '19200', '38400', '57600', '115200', '230400'
    {$IFNDEF DARWIN}  // LINUX
       , '460800', '500000', '576000', '921600', '1000000', '1152000', '1500000',
       '2000000', '2500000', '3000000', '3500000', '4000000'
    {$ENDIF}  );
{$ELSE}      // MSWINDOWS
  BaudRateStrings: array[TBaudRate] of string = ('110', '300', '600',
    '1200', '2400', '4800', '9600', '14400', '19200', '38400', '56000', '57600',
    '115200', '128000', '230400', '250000', '256000','460800', '921600');
{$ENDIF}
  StopBitsStrings: array[TStopBits] of string = ('1', '1.5', '2');
  DataBitsStrings: array[TDataBits] of string = ('8', '7', '6', '5');
  ParityBitsStrings: array[TParity] of string = (lngNone, lngOdd, lngEven, lngMark, lngSpace);
  FlowControlStrings: array[TFlowControl] of string = (lngNone, lngXonXoff_DTR,  lngRTS_CTS, lngXonXoff,         lngXonXoff_and_RTS_CTS,  lngDTR_DSR, lngXonXoff_and_DTR_DSR, lngDTR);
 //                                                   fcNone=0, fcXonXoff=1,   fcHardware=2, fcXonXoff_no_DTR=3,fcXonXoff_and_RTS_CTS=4, fcDTR_DSR=5,fcXonXoff_and_DTR_DSR=6,fcDTR=7

procedure StringArrayToList(AList: TStrings; const AStrings: array of string);
var
 Cpt: Integer;
begin
  for Cpt := Low(AStrings) to High(AStrings) do
   AList.Add(AStrings[Cpt]);
end;



// string to baud rate
function StrToBaudRate(Str: string): TBaudRate;
var
  I: Integer;
begin
  for I := Ord(Low(TBaudRate)) to Ord(High(TBaudRate)) do
    if SameText(Str, BaudRateToStr(TBaudRate(I))) then
      Exit(TBaudRate(I));
  Result := br__9600;
end;

// string to stop bits
function StrToStopBits(Str: string): TStopBits;
var
  I: Integer;
begin
  for I := Ord(Low(TStopBits)) to Ord(High(TStopBits)) do
    if SameText(Str, StopBitsToStr(TStopBits(I))) then
      Exit(TStopBits(I));
  Result := sbOne;
end;

// string to data bits
function StrToDataBits(Str: string): TDataBits;
var
  I: Integer;
begin
  for I := Ord(Low(TDataBits)) to Ord(High(TDataBits)) do
    if SameText(Str, DataBitsToStr(TDataBits(I))) then
      Exit(TDataBits(I));
  Result := db8bits;
end;

// string to parity
function StrToParity(Str: string): TParity;
var
  I: Integer;
begin
  for I := Ord(Low(TParity)) to Ord(High(TParity)) do
    if SameText(Str, ParityToStr(TParity(I))) then
      Exit(TParity(I));
  Result := pNone;
end;

// string to flow control
function StrToFlowControl(Str: string): TFlowControl;
var
  I: Integer;
begin
  for I := Ord(Low(TFlowControl)) to Ord(High(TFlowControl)) do
    if SameText(Str, FlowControlToStr(TFlowControl(I))) then
      Exit(TFlowControl(I));
  Result := fcNone;
end;

// baud rate to string
function BaudRateToStr(BaudRate: TBaudRate): string;
begin
  Result := BaudRateStrings[BaudRate];
end;

// stop bits to string
function StopBitsToStr(StopBits: TStopBits): string;
begin
  Result := StopBitsStrings[StopBits];
end;

// data bits to string
function DataBitsToStr(DataBits: TDataBits): string;
begin
  Result := DataBitsStrings[DataBits];
end;

// parity to string
function ParityToStr(Parity: TParity): string;
begin
  Result := ParityBitsStrings[Parity];
end;

// flow control to string
function FlowControlToStr(FlowControl: TFlowControl): string;
begin
  Result := FlowControlStrings[FlowControl];
end;

procedure EditComPort(ComPort: TLazSerial);
var
  SetupForm: TComSetupFrm;
begin
  SetupForm := TComSetupFrm.Create(nil);
  try
    SetupForm.LoadSettings(ReadComPortSettings(ComPort));
    ApplyComPortSetupResult(ComPort, SetupForm, SetupForm.ShowModal);
  finally
    SetupForm.Free;
  end;
end;

function ReadComPortSettings(ComPort: TLazSerial): TComPortSettings;
begin
  Result.Device := ComPort.Device;
  Result.BaudRate := ComPort.BaudRate;
  Result.DataBits := ComPort.DataBits;
  Result.StopBits := ComPort.StopBits;
  Result.Parity := ComPort.Parity;
  Result.FlowControl := ComPort.FlowControl;
end;

procedure ApplyComPortSetupResult(ComPort: TLazSerial;
  SetupForm: TComSetupFrm; const AModalResult: TModalResult);
var
  Settings: TComPortSettings;
begin
  if AModalResult <> mrOK then
    Exit;
  Settings := SetupForm.ReadSettings;
  ComPort.Close;
  ComPort.Device := Settings.Device;
  ComPort.BaudRate := Settings.BaudRate;
  ComPort.DataBits := Settings.DataBits;
  ComPort.StopBits := Settings.StopBits;
  ComPort.Parity := Settings.Parity;
  ComPort.FlowControl := Settings.FlowControl;
end;

{ TComSetupFrm }


procedure TComSetupFrm.FormCreate(Sender: TObject);
begin
  SerialSelector1.ShowHint := true;
  ComComboBox2.Items.Clear;
  ComComboBox3.Items.Clear;
  ComComboBox4.Items.Clear;
  ComComboBox5.Items.Clear;
  ComComboBox6.Items.Clear;
  StringArrayToList(ComComboBox2.Items,BaudRateStrings) ;
  StringArrayToList(ComComboBox3.Items,DataBitsStrings) ;
  StringArrayToList(ComComboBox4.Items,StopBitsStrings) ;
  StringArrayToList(ComComboBox5.Items,ParityBitsStrings) ;
  StringArrayToList(ComComboBox6.Items,FlowControlStrings) ;
end;

procedure TComSetupFrm.LoadSettings(const ASettings: TComPortSettings);
begin
  SerialSelector1.Device := ASettings.Device;
  ComComboBox2.Text := BaudRateToStr(ASettings.BaudRate);
  ComComboBox3.Text := DataBitsToStr(ASettings.DataBits);
  ComComboBox4.Text := StopBitsToStr(ASettings.StopBits);
  ComComboBox5.Text := ParityToStr(ASettings.Parity);
  ComComboBox6.Text := FlowControlToStr(ASettings.FlowControl);
end;

function TComSetupFrm.ReadSettings: TComPortSettings;
begin
  Result.Device := SerialSelector1.Device;
  Result.BaudRate := StrToBaudRate(ComComboBox2.Text);
  Result.DataBits := StrToDataBits(ComComboBox3.Text);
  Result.StopBits := StrToStopBits(ComComboBox4.Text);
  Result.Parity := StrToParity(ComComboBox5.Text);
  Result.FlowControl := StrToFlowControl(ComComboBox6.Text);
end;

end.
