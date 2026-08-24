{ LazSerial
Serial Port Component for Lazarus 
by Jurassic Pork  03/2013 03/2021
This library is Free software; you can rediStribute it and/or modify it
  under the terms of the GNU Library General Public License as published by
  the Free Software Foundation; either version 2 of the License, or (at your
  option) any later version.

  This program is diStributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; withOut even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU Library General Public License
  for more details.

  You should have received a Copy of the GNU Library General Public License
  along with This library; if not, Write to the Free Software Foundation,
  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. }

{ Based on }
{ SdpoSerial v0.1.4
  CopyRight (C) 2006-2010 Paulo Costa
   paco@fe.up.pt
} 
{ Synaser library  by Lukas Gebauer }
{ TcomPort component }


{ features :
Changed :  baudrate values.
            stop bits  new value : 1.5
new event : onstatus
new property FRcvLineCRLF : if this property is true, you use RecvString
in place of RecvPacket when you read data from the port.

new procedure  ShowSetupDialog to open a port settings form :
the device combobox contain the enumerated ports.
new procedure to enumerate real serial port on linux ( in synaser).

Demo : a simulator of gps serial port + serial port receiver :
you can send NMEA frames ( GGA GLL RMC°) to the opened serial port
(start gps simulator). You can change speed and heading.
In the memo you can see what is received from  the opened serial port.
In the status bar you can see the status events.

}


unit LazSerial;

{$mode objfpc}{$H+}

interface

uses
{$IFDEF UNIX}
  Classes,
{$IFDEF UseCThreads}
  cthreads,
{$ENDIF}
{$ELSE}
  Windows, Classes,
{$ENDIF}
  SysUtils, SyncObjs, lazsynaser,  LResources, Forms, Controls, Graphics, Dialogs,
  PropEdits, SerialWatcher, LazSerialCommon, LazSerialTransport;


type
{$IFDEF UNIX}
  TBaudRate=(br_____0, br____50, br____75, br___110, br___134, br___150,
             br___200, br___300, br___600, br__1200, br__1800, br__2400,
             br__4800, br__9600, br_19200, br_38400, br_57600, br115200,
             br230400
   {$IFNDEF DARWIN}   // LINUX
             , br460800, br500000, br576000, br921600, br1000000, br1152000,
             br1500000, br2000000, br2500000, br3000000, br3500000, br4000000
   {$ENDIF} );
{$ELSE}      // MSWINDOWS
   TBaudRate=(br___110,br___300, br___600, br__1200, br__2400, br__4800,
           br__9600,br_14400, br_19200, br_38400,br_56000, br_57600,
           br115200,br128000, br230400, br250000, br256000, br460800, br921600);
{$ENDIF}
  TDataBits=(db8bits,db7bits,db6bits,db5bits);
  TParity=(pNone,pOdd,pEven,pMark,pSpace);
  //TFlowControl moved to LazSerialCommon
  TStopBits=(sbOne,sbOneAndHalf,sbTwo);

  TModemSignal = (msRI,msCD,msCTS,msDSR);
  TModemSignals = Set of TModemSignal;
  TStatusEvent = procedure(Sender: TObject; Reason: THookSerialReason; const Value: string) of object;

const
{$IFDEF UNIX}
    ConstsBaud: array[TBaudRate] of integer=
    (0, 50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600,
    19200, 38400, 57600, 115200, 230400
    {$IFNDEF DARWIN}  // LINUX
       , 460800, 500000, 576000, 921600, 1000000, 1152000, 1500000, 2000000,
       2500000, 3000000, 3500000, 4000000
    {$ENDIF}  );
{$ELSE}      // MSWINDOWS
    ConstsBaud: array[TBaudRate] of integer=
    (110, 300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 38400, 56000, 57600,
    115200, 128000, 230400, 250000, 256000, 460800, 921600);
{$ENDIF}

  ConstsBits: array[TDataBits] of integer=(8, 7 , 6, 5);
  ConstsParity: array[TParity] of char=('N', 'O', 'E', 'M', 'S');
  ConstsStopBits: array[TStopBits] of integer=(SB1,SB1AndHalf,SB2);


type
  ELazSerialThreadError = class(Exception);

  TLazSerial = class;

  ISerialReaderSession = interface
    procedure Cancel;
    procedure DeliverReceive;
    procedure DeliverStatus(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    procedure Detach;
    procedure SignalReader;
    function WaitForReader(const ATimeout: Cardinal): TWaitResult;
  end;

  TComPortReadThread=class(TThread)
  private
    FSession: ISerialReaderSession;
    procedure QueueReceive;
    procedure QueueStatus(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    procedure WaitForDelivery;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    Owner: TLazSerial;
    constructor Create(AOwner: TLazSerial;
      const ASession: ISerialReaderSession);
  published
    property Terminated;
  end;

  { TLazSerial }

  TLazSerial = class(TComponent)
  private
    FActive: boolean;
    FTransport: TLazSerialTransport;
    FDevice: string;

    FSerialWatcher : TSerialWatcher;

    FBaudRate: TBaudRate;
    FCustomBaudRate : Integer;
    FDataBits: TDataBits;
    FParity: TParity;
    FStopBits: TStopBits;
    
    //FSoftflow, FHardflow: boolean;
    FFlowControl: TFlowControl;
    FRcvLineCRLF : Boolean;

    FOnRxData: TNotifyEvent;
    FOnStatus: TStatusEvent;
    FOnRemoved: TNotifyEvent;
    FClosing: Boolean;
    FDestroying: Boolean;
    FReaderSession: ISerialReaderSession;
    ReadThread: TComPortReadThread;

    procedure DeviceOpen;
    procedure DeviceClose;

    procedure CheckMainThread(const AOperation: string);
    procedure ComException(str: string);
    procedure ComDisconnected(Sender: TObject);
    procedure DeliverReaderReceive;
    procedure DeliverReaderStatus(Sender: TObject;
      Reason: THookSerialReason; const Value: string);
    procedure SynSerStatus(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    procedure TriggerDisconnected;
    function AppliedBaudrate: integer;
    function GetSynSer: TBlockSerial;

  protected
    procedure ReplaceTransportForTesting(ATransport: TLazSerialTransport);
    procedure SetActive(state: boolean);
    procedure SetBaudRate(br: TBaudRate);
    procedure SetCustomBaudrate(br: Integer);
    procedure SetDataBits(db: TDataBits);
    procedure SetParity(pr: TParity);
    procedure SetFlowControl(aFlowControl: TFlowControl);
    procedure SetStopBits(sb: TStopBits);
    procedure SetDevice(const ADevice: string);
    procedure SetRcvLineCRLF(AValue: Boolean);

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Open;
    procedure Close;
    // show a port settings dialog form
    procedure ShowSetupDialog;
    // read data from port
    function DataAvailable: boolean;
    function ReadData: string;
//    function ReadBuffer(var buf; size: integer): integer;

    // write data to port
    function WriteData(data: string): integer;
    function WriteBuffer(var buf; size: integer): integer;

    // read pin states
    function ModemSignals: TModemSignals;
    function GetDSR: boolean;
    function GetCTS: boolean;
    function GetRing: boolean;
    function GetCarrier: boolean;

    // set pin states
//    procedure SetRTSDTR(RtsState, DtrState: boolean);
    procedure SetDTR(OnOff: boolean);
    procedure SetRTS(OnOff: boolean);
//  procedure SetBreak(OnOff: boolean);

  published
    property Active: boolean read FActive write SetActive;
    // Will be overridden by CustomBaudRate if its value is ≥ 0.
    property BaudRate: TBaudRate read FBaudRate write SetBaudRate; // default br115200;
    // If < 0 the value of BaudRate is used instead.
    property CustomBaudRate: integer read FCustomBaudRate write SetCustomBaudrate; //default -1
    property DataBits: TDataBits read FDataBits write SetDataBits;
    property Parity: TParity read FParity write SetParity;
    //fcHardware (legacy name) = fcRTS_CTS; fcXonXoff (legacy name) = fcXonXoff_and_DTR. The real XonXoff is named fcXonXoff_no_DTR
    property FlowControl: TFlowControl read FFlowControl write SetFlowControl;
    property StopBits: TStopBits read FStopBits write SetStopBits;
    
    property SynSer: TBlockSerial read GetSynSer;
    property Device: string read FDevice write SetDevice;
    property RcvLineCRLF: Boolean read FRcvLineCRLF write SetRcvLineCRLF;

    property OnRxData: TNotifyEvent read FOnRxData write FOnRxData;
    property OnStatus: TStatusEvent read FOnStatus write FOnStatus;
    // Triggers if the device is removed during an active connection.
    property OnRemoved : TNotifyEvent read FOnRemoved write FOnRemoved;
  end;

procedure Register;

implementation
uses LazSerialSetup;

type
  TSerialReaderEventKind = (srekReceive, srekStatus);

  TSerialReaderSession = class(TInterfacedObject, ISerialReaderSession)
  private
    FActive: Boolean;
    FCompletionEvent: TEvent;
    FOwner: TLazSerial;
  public
    constructor Create(AOwner: TLazSerial);
    destructor Destroy; override;
    procedure Cancel;
    procedure DeliverReceive;
    procedure DeliverStatus(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    procedure Detach;
    procedure SignalReader;
    function WaitForReader(const ATimeout: Cardinal): TWaitResult;
  end;

  TSerialReaderEventDelivery = class
  private
    FKind: TSerialReaderEventKind;
    FReason: THookSerialReason;
    FSender: TObject;
    FSession: ISerialReaderSession;
    FValue: string;
    procedure Deliver;
  public
    constructor CreateReceive(const ASession: ISerialReaderSession);
    constructor CreateStatus(const ASession: ISerialReaderSession;
      ASender: TObject; AReason: THookSerialReason; const AValue: string);
  end;

constructor TSerialReaderSession.Create(AOwner: TLazSerial);
begin
  inherited Create;
  FOwner := AOwner;
  FActive := True;
  FCompletionEvent := TEvent.Create(nil, False, False, '');
end;

destructor TSerialReaderSession.Destroy;
begin
  FCompletionEvent.Free;
  inherited Destroy;
end;

procedure TSerialReaderSession.Cancel;
begin
  FActive := False;
  SignalReader;
end;

procedure TSerialReaderSession.DeliverReceive;
var
  Serial: TLazSerial;
begin
  if not FActive then
    Exit;
  Serial := FOwner;
  if Serial <> nil then
    Serial.DeliverReaderReceive;
end;

procedure TSerialReaderSession.DeliverStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
var
  Serial: TLazSerial;
begin
  if not FActive then
    Exit;
  Serial := FOwner;
  if Serial <> nil then
    Serial.DeliverReaderStatus(Sender, Reason, Value);
end;

procedure TSerialReaderSession.Detach;
begin
  FOwner := nil;
  Cancel;
end;

procedure TSerialReaderSession.SignalReader;
begin
  FCompletionEvent.SetEvent;
end;

function TSerialReaderSession.WaitForReader(
  const ATimeout: Cardinal
): TWaitResult;
begin
  Result := FCompletionEvent.WaitFor(ATimeout);
end;

constructor TSerialReaderEventDelivery.CreateReceive(
  const ASession: ISerialReaderSession
);
begin
  inherited Create;
  FSession := ASession;
  FKind := srekReceive;
end;

constructor TSerialReaderEventDelivery.CreateStatus(
  const ASession: ISerialReaderSession;
  ASender: TObject;
  AReason: THookSerialReason;
  const AValue: string
);
begin
  inherited Create;
  FSession := ASession;
  FKind := srekStatus;
  FSender := ASender;
  FReason := AReason;
  FValue := AValue;
end;

procedure TSerialReaderEventDelivery.Deliver;
var
  Session: ISerialReaderSession;
begin
  Session := FSession;
  try
    case FKind of
      srekReceive:
        Session.DeliverReceive;
      srekStatus:
        Session.DeliverStatus(FSender, FReason, FValue);
    end;
  finally
    Session.SignalReader;
    Free;
  end;
end;

{ TLazSerial }

procedure TLazSerial.Close;
begin
  CheckMainThread('TLazSerial.Close');
  Active:=false;
end;

procedure TLazSerial.DeviceClose;
begin
  FClosing := True;
  try
    // Stop the reader before flushing or closing the handle it uses.
    if ReadThread <> nil then
    begin
      ReadThread.FreeOnTerminate := False;
      ReadThread.Terminate;
      if FReaderSession <> nil then
        FReaderSession.Cancel;
      while not ReadThread.Finished do
        Sleep(1);
      ReadThread.WaitFor;
      ReadThread.Free;
      ReadThread := nil;
    end;
    FReaderSession := nil;

    FTransport.Close;
  finally
    FClosing := False;
  end;
end;

constructor TLazSerial.Create(AOwner: TComponent);
begin
  inherited;
  //FHandle:=-1;
  ReadThread := nil;
  FTransport := TLazSynapseSerialTransport.Create;
  //FHardflow:=false;
  //FSoftflow:=false;
  FFlowControl := fcNone;
  FSerialWatcher := TSerialWatcher.Create(Self);
  FSerialWatcher.OnComDisconnected := @ComDisconnected;
  FCustomBaudRate := -1;
  FClosing := False;
  FDestroying := False;
  FReaderSession := nil;
  {$IFDEF LINUX}
  FDevice:='/dev/ttyS0';
  {$ELSE}
  FDevice:='COM1'; //TODO: Set to the first available device, if a device is available
  {$ENDIF}
  FRcvLineCRLF := False;;
//  FBaudRate:=br115200;
end;

function TLazSerial.DataAvailable: boolean;
begin
  CheckMainThread('TLazSerial.DataAvailable');
  if not FTransport.IsOpen then begin
    result:=false;
    exit;
  end;
  result:=FTransport.CanRead(0);
end;

destructor TLazSerial.Destroy;
begin
  FDestroying := True;
  FSerialWatcher.OnComDisconnected := nil;
  if FReaderSession <> nil then
    FReaderSession.Detach;
  Close;
  FTransport.SetStatusHandler(nil);
  FTransport.Free;
  FReaderSession := nil;
  inherited;
end;

procedure TLazSerial.Open;
begin
  CheckMainThread('TLazSerial.Open');
  Active:=true;
end;

procedure TLazSerial.ShowSetupDialog;
begin
  CheckMainThread('TLazSerial.ShowSetupDialog');
  EditComPort(Self);
end;

function TLazSerial.AppliedBaudrate: integer;
begin
  if (FCustomBaudRate < 0)
    then Result := ConstsBaud[FBaudRate]
    else Result := FCustomBaudRate;
end;

function TLazSerial.GetSynSer: TBlockSerial;
begin
  CheckMainThread('TLazSerial.SynSer');
  Result := FTransport.NativeSerial;
end;

procedure TLazSerial.DeviceOpen;
begin
  FTransport.SetStatusHandler(@SynSerStatus);
  try
    FTransport.Connect(FDevice);
    if not FTransport.IsOpen then
      raise Exception.Create('Could not open device ' +
        FTransport.DeviceName);
    FTransport.Configure(AppliedBaudrate,
                         ConstsBits[FDataBits],
                         ConstsParity[FParity],
                         ConstsStopBits[FStopBits],
                         FFlowControl);

    FReaderSession := TSerialReaderSession.Create(Self);
    ReadThread := TComPortReadThread.Create(Self, FReaderSession);
    ReadThread.Start;
  except
    FReaderSession := nil;
    FreeAndNil(ReadThread);
    FTransport.Close;
    raise;
  end;
end;


function TLazSerial.ReadData: string;
begin
  CheckMainThread('TLazSerial.ReadData');
  result:='';
  if not FTransport.IsOpen then
    ComException('can not read from a closed port.');
  if FRcvLineCRLF then
  result:=FTransport.ReadString(0)
  else
  result:=FTransport.ReadPacket(0);
end;

procedure TLazSerial.ReplaceTransportForTesting(
  ATransport: TLazSerialTransport);
begin
  CheckMainThread('TLazSerial.ReplaceTransportForTesting');
  if ATransport = nil then
    raise EArgumentNilException.Create('ATransport');
  if FActive or (ReadThread <> nil) then
    raise EInvalidOperation.Create(
      'Cannot replace the transport of an active serial connection');
  FTransport.SetStatusHandler(nil);
  FTransport.Free;
  FTransport := ATransport;
end;

procedure TLazSerial.SetActive(state: boolean);
begin
  CheckMainThread('TLazSerial.Active');
  if state=FActive then exit;

  if state then
  begin
    FSerialWatcher.Refresh;
    DeviceOpen;
  end
  else
    DeviceClose;

  FActive:=state;
end;

procedure TLazSerial.SetBaudRate(br: TBaudRate);
begin
  CheckMainThread('TLazSerial.BaudRate');
  FBaudRate:=br;
  if (FCustomBaudRate > -1) then exit;
  if FTransport.IsOpen then begin
    FTransport.Configure(ConstsBaud[FBaudRate], ConstsBits[FDataBits],
      ConstsParity[FParity], ConstsStopBits[FStopBits], FFlowControl);
  end;
end;

procedure TLazSerial.SetCustomBaudrate(br: Integer);
begin
  CheckMainThread('TLazSerial.CustomBaudRate');
  if (FCustomBaudRate = br) then exit;
  FCustomBaudRate := br;
  if (FCustomBaudRate < 0)
    then SetBaudRate(FBaudRate)
    else if FTransport.IsOpen then
      FTransport.Configure(FCustomBaudRate, ConstsBits[FDataBits],
        ConstsParity[FParity], ConstsStopBits[FStopBits], FFlowControl);
end;

procedure TLazSerial.SetDataBits(db: TDataBits);
begin
  CheckMainThread('TLazSerial.DataBits');
  FDataBits:=db;
  if FTransport.IsOpen then begin
    FTransport.Configure(AppliedBaudrate, ConstsBits[FDataBits],
      ConstsParity[FParity], ConstsStopBits[FStopBits], FFlowControl);
  end;
end;

procedure TLazSerial.SetDevice(const ADevice: string);
begin
  CheckMainThread('TLazSerial.Device');
  FDevice := ADevice;
end;

{procedure TLazSerial.SetFlowControl_obsolete(fc: TFlowControl);
begin
  case fc of
    fcNone     : begin FSoftflow:=false; FHardflow:=false; end;
    fcXonXoff  : begin FSoftflow:=true;  FHardflow:=false; end;
    fcHardware : begin FSoftflow:=false; FHardflow:=true;  end;
  end;

  {if (fc = fcNone) then begin
    FSoftflow:=false; FHardflow:=false;
  end else if (fc = fcXonXoff) then begin
    FSoftflow:=true; FHardflow:=false;
  end else if fc=fcHardware then begin
    FSoftflow:=false; FHardflow:=true;
  end;}

  if FSynSer.Handle<>INVALID_HANDLE_VALUE then begin
    FSynSer.Config(AppliedBaudrate, ConstsBits[FDataBits], ConstsParity[FParity],
                   ConstsStopBits[FStopBits], FSoftflow, FHardflow);
  end;
  FFlowControl:=fc;
end;}

procedure TLazSerial.SetFlowControl(aFlowControl: TFlowControl);
begin
  CheckMainThread('TLazSerial.FlowControl');
  if (FFlowControl = aFlowControl) then exit;
  FFlowControl := aFlowControl;
  if FTransport.IsOpen then
    FTransport.Configure(AppliedBaudrate, ConstsBits[FDataBits],
      ConstsParity[FParity], ConstsStopBits[FStopBits], FFlowControl);
end;


{
procedure TLazSerial.SetFlowControl(fc: TFlowControl);
begin
  if FHandle<>-1 then begin
    if fc=fcNone then CurTermIO.c_cflag:=CurTermIO.c_cflag and (not CRTSCTS)
    else CurTermIO.c_cflag:=CurTermIO.c_cflag or CRTSCTS;
    tcsetattr(FHandle,TCSADRAIN,CurTermIO);
  end;
  FFlowControl:=fc;
end;
}
procedure TLazSerial.SetParity(pr: TParity);
begin
  CheckMainThread('TLazSerial.Parity');
  FParity:=pr;
  if FTransport.IsOpen then begin
    FTransport.Configure(AppliedBaudrate, ConstsBits[FDataBits],
      ConstsParity[FParity], ConstsStopBits[FStopBits], FFlowControl);
  end;
end;

procedure TLazSerial.SetRcvLineCRLF(AValue: Boolean);
begin
  CheckMainThread('TLazSerial.RcvLineCRLF');
  FRcvLineCRLF := AValue;
end;

procedure TLazSerial.SetStopBits(sb: TStopBits);
begin
  CheckMainThread('TLazSerial.StopBits');
  FStopBits:=sb;
  if FTransport.IsOpen then begin
    FTransport.Configure(AppliedBaudrate, ConstsBits[FDataBits],
      ConstsParity[FParity], ConstsStopBits[FStopBits], FFlowControl);
  end;
end;

function TLazSerial.WriteBuffer(var buf; size: integer): integer;
begin
  CheckMainThread('TLazSerial.WriteBuffer');
//  if FSynSer.Handle=INVALID_HANDLE_VALUE then
 //   ComException('can not write to a closed port.');
  result:= FTransport.SendBuffer(Pointer(@buf), size);
end;

function TLazSerial.WriteData(data: string): integer;
begin
  CheckMainThread('TLazSerial.WriteData');
  result:=FTransport.SendString(data);
end;


function TLazSerial.ModemSignals: TModemSignals;
begin
  CheckMainThread('TLazSerial.ModemSignals');
  result:=[];
  if FTransport.GetCTS then result := result + [ msCTS ];
  if FTransport.GetCarrier then result := result + [ msCD ];
  if FTransport.GetRing then result := result + [ msRI ];
  if FTransport.GetDSR then result := result + [ msDSR ];
end;

function TLazSerial.GetDSR: boolean;
begin
  CheckMainThread('TLazSerial.GetDSR');
  result := FTransport.GetDSR;
end;

function TLazSerial.GetCTS: boolean;
begin
  CheckMainThread('TLazSerial.GetCTS');
  result := FTransport.GetCTS;
end;

function TLazSerial.GetRing: boolean;
begin
  CheckMainThread('TLazSerial.GetRing');
  result := FTransport.GetRing;
end;

function TLazSerial.GetCarrier: boolean;
begin
  CheckMainThread('TLazSerial.GetCarrier');
  result := FTransport.GetCarrier;
end;

{procedure TLazSerial.SetBreak(OnOff: boolean);
begin
//  if FHandle=-1 then
//    ComException('can not set break state on a closed port.');
//  if OnOff=false then ioctl(FHandle,TIOCCBRK,1)
//  else ioctl(FHandle,TIOCSBRK,0);
end;  }


procedure TLazSerial.SetDTR(OnOff: boolean);
begin
  CheckMainThread('TLazSerial.SetDTR');
  FTransport.SetDTR(OnOff);
end;


procedure TLazSerial.SetRTS(OnOff: boolean);
begin
  CheckMainThread('TLazSerial.SetRTS');
  FTransport.SetRTS(OnOff);
end;

procedure TLazSerial.ComException(str: string);
begin
  raise Exception.Create('ComPort error: '+str);
end;

procedure TLazSerial.CheckMainThread(const AOperation: string);
begin
  if GetCurrentThreadID <> MainThreadID then
    raise ELazSerialThreadError.CreateFmt(
      '%s must be called from the main thread', [AOperation]);
end;

procedure TLazSerial.SynSerStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if FDestroying then
    Exit;
  if (ReadThread <> nil) and
    (GetCurrentThreadID = ReadThread.ThreadID) then
  begin
    ReadThread.QueueStatus(Sender, Reason, Value);
  end
  else if Assigned(FOnStatus) then
    FOnStatus(Sender, Reason, Value);
end;

{ TComPortReadThread }

constructor TComPortReadThread.Create(AOwner: TLazSerial;
  const ASession: ISerialReaderSession);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Owner := AOwner;
  FSession := ASession;
end;

procedure TComPortReadThread.WaitForDelivery;
begin
  while not Terminated do
    if FSession.WaitForReader(100) = wrSignaled then
      Exit;
end;

procedure TComPortReadThread.QueueReceive;
var
  Delivery: TSerialReaderEventDelivery;
begin
  if Terminated then
    Exit;
  Delivery := TSerialReaderEventDelivery.CreateReceive(FSession);
  try
    TThread.Queue(nil, @Delivery.Deliver);
  except
    Delivery.Free;
    raise;
  end;
  WaitForDelivery;
end;

procedure TComPortReadThread.QueueStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
var
  Delivery: TSerialReaderEventDelivery;
begin
  if Terminated then
    Exit;
  Delivery := TSerialReaderEventDelivery.CreateStatus(
    FSession,
    Sender,
    Reason,
    Value
  );
  try
    TThread.Queue(nil, @Delivery.Deliver);
  except
    Delivery.Free;
    raise;
  end;
  WaitForDelivery;
end;

procedure TComPortReadThread.TerminatedSet;
begin
  inherited TerminatedSet;
  if FSession <> nil then
    FSession.SignalReader;
end;

procedure TComPortReadThread.Execute;
begin
  try
    while not Terminated do begin
      if Owner.FTransport.CanRead(100) then
        QueueReceive;
    end;
  finally
    Terminate;
  end;
end;

procedure TLazSerial.DeliverReaderReceive;
begin
  if not FClosing and not FDestroying and Assigned(FOnRxData) then
    FOnRxData(Self);
end;

procedure TLazSerial.DeliverReaderStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if not FClosing and not FDestroying and Assigned(FOnStatus) then
    FOnStatus(Sender, Reason, Value);
end;

//Begin: Handle disconnect detection
procedure TLazSerial.TriggerDisconnected;
begin
  if Active and not FSerialWatcher.ContainsDevice(FDevice) then
  begin
    Active := False;
    if Assigned(FOnRemoved) then
      FOnRemoved(Self);
  end;
end;

procedure TLazSerial.ComDisconnected(Sender: TObject);
begin
  TriggerDisconnected;
end;
//End: Handle disconnect detection

procedure Register;
begin
  RegisterComponents('LazSerial', [TLazSerial]);
  RegisterPropertyEditor(TypeInfo(boolean), TLazSerial, 'Active', THiddenPropertyEditor);
end;

initialization
{$i TLazSerial.lrs}

end.
