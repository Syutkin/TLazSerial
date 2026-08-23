//Note: For some Linux distros access to serial ports is disabled by default
//use “sudo chmod a+rw /dev/ttyUSB*” before staring the app.
//or “sudo chmod 777 /dev/ttyUSB*”
//“sudo usermod -a -G dialout $USER” might also help
//https://askubuntu.com/questions/58119/changing-permissions-on-serial-port

unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  LCLTranslator, ExtCtrls, Spin, LCLType,
  LazSerialSetup, LazSerial, LazSynaSer, SerialSelector, LazSerialDevices;

resourcestring
  lngConnect = 'Connect';
  lngDisconnect = 'Disconnect';
  lngDeviceDisconnected = 'Device %s was removed while the connection was active.';
  lngErrorCannotConnect = 'Error: cannot connect to %s.';

type

  { TForm1 }

  TForm1 = class(TForm)
    chkSerialNumber: TCheckBox;
    cmdConnect: TButton;
    cmdSend: TButton;
    CheckBox1: TCheckBox;
    CheckBox3: TCheckBox;
    ComboBox1: TComboBox;
    Edit1: TEdit;
    Label1: TLabel;
    Label2: TLabel;
    LazSerial1:TLazSerial;
    lblCustomBaudrate: TLabel;
    Memo1: TMemo;
    SerialSelector1: TSerialSelector;
    SpinEdit1: TSpinEdit;
    Timer1: TTimer;
    procedure chkSerialNumberChange(Sender: TObject);
    procedure cmdConnectClick(Sender: TObject);
    procedure cmdSendClick(Sender: TObject);
    procedure CheckBox1Change(Sender: TObject);
    procedure CheckBox3Change(Sender: TObject);
    procedure Edit1KeyPress(Sender: TObject; var Key: char);
    procedure FormCreate(Sender: TObject);
    procedure LazSerial1Removed(Sender: TObject);
    procedure LazSerial1RxData(Sender: TObject);
    procedure LazSerial1Status(Sender:TObject;Reason:THookSerialReason;const Value:string);
    procedure Timer1Timer(Sender: TObject);
  private

  public

  end;


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
{  StopBitsStrings: array[TStopBits] of string = ('1', '1.5', '2');
  DataBitsStrings: array[TDataBits] of string = ('8', '7', '6', '5');
  ParityBitsStrings: array[TParity] of string = ('None', 'Odd', 'Even','Mark', 'Space');
  FlowControlStrings: array[TFlowControl] of string = ('None', 'Software', 'HardWare');}

var
  Form1: TForm1;
  ConnectedDevice : string;

implementation

{$R *.lfm}

{ TForm1 }

procedure TForm1.cmdConnectClick(Sender: TObject);
begin
  LazSerial1.CustomBaudRate := SpinEdit1.Value; //This value will be used if it is >= 0, otherwise the value below will be used
  LazSerial1.BaudRate :=  StrToBaudRate(ComboBox1.Text);
  LazSerial1.Device := SerialSelector1.Device;
  if (LazSerial1.Active = False) then
    try
      LazSerial1.Active := True;
    except
      ShowMessage (format(lngErrorCannotConnect,[SerialSelector1.Device]));
    end
  else
    LazSerial1.Active := False;

  if (LazSerial1.Active = True) then
  begin
    ConnectedDevice := LazSerial1.Device;
    cmdConnect.Caption := lngDisconnect;
    cmdSend.Enabled := True;
  end
  else
  begin
    cmdConnect.Caption := lngConnect;
    cmdSend.Enabled := False;
  end;
end;

procedure TForm1.cmdSendClick(Sender: TObject);
begin
  if LazSerial1.Active then LazSerial1.WriteData(Edit1.Text);
end;

procedure TForm1.CheckBox1Change(Sender: TObject);
begin
  SerialSelector1.ShowFriendlyName := CheckBox1.Checked;
  chkSerialNumber.Enabled := CheckBox1.Checked;
end;

procedure TForm1.chkSerialNumberChange(Sender: TObject);
var
  Options: TSerialDeviceDisplayOptions;
begin
  Options := SerialSelector1.DisplayOptions;
  if chkSerialNumber.Checked then
    Include(Options, sddoSerialShort)
  else
    Exclude(Options, sddoSerialShort);
  SerialSelector1.DisplayOptions := Options;
end;

procedure TForm1.CheckBox3Change(Sender: TObject);
begin
  SerialSelector1.ShowHint := CheckBox3.Checked;
end;

procedure TForm1.Edit1KeyPress(Sender: TObject; var Key: char);
begin
 if key = #13 then cmdSendClick(self);
end;

procedure StringArrayToList(AList: TStrings; const AStrings: array of string);
var
 Cpt: Integer;
begin
  for Cpt := Low(AStrings) to High(AStrings) do
   AList.Add(AStrings[Cpt]);
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  CheckBox3.Checked  := SerialSelector1.ShowHint;
  StringArrayToList(ComboBox1.Items,BaudRateStrings) ;
  //Set baudrate to 9 600
  {$ifdef linux}ComboBox1.ItemIndex := 13;
  {$else}ComboBox1.ItemIndex := 6;
  {$endif}
end;

procedure TForm1.LazSerial1Removed(Sender: TObject);
begin
  ShowMessage (format(lngDeviceDisconnected,[ConnectedDevice]));
  LazSerial1.Active := False;
  cmdConnect.Caption := lngConnect;
end;

procedure TForm1.LazSerial1RxData(Sender: TObject);
begin
  Memo1.Lines.Text := Memo1.Lines.Text + LazSerial1.ReadData;
end;

procedure TForm1.LazSerial1Status(Sender:TObject;Reason:THookSerialReason;const Value:string);
begin

end;

procedure TForm1.Timer1Timer(Sender: TObject);
begin
  Label2.Caption := IntToStr(GetTickCount64); //Displays if the app is hanging
end;

end.
