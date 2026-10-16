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
  PropEdits, SerialWatcher, LazSerialCommon, LazSerialDevices,
  LazSerialTransport;

const
  { Version of this TLazSerial package, matching LazSerialPort.lpk. It is
    available without creating a serial port or loading a native library.
    Update it together with the package version when releasing TLazSerial. }
  LazSerialPackageVersion = '0.8.1';


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
  TSerialErrorEvent = procedure(Sender: TObject; ErrorCode: Integer;
    const ErrorMessage: string) of object;

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
    FQueuedDelivery: TObject;
    procedure QueueDelivery(ADelivery: TObject);
    procedure QueueReceive;
    procedure QueueStatus(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    procedure QueueFailure(const AErrorCode: Integer;
      const AErrorMessage: string);
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
    FTransportLock: TCriticalSection;
    FTransportDepth: Integer;
    FPendingStatuses: TList;
    FStatusSession: ISerialReaderSession;
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
    FOnError: TSerialErrorEvent;
    FOnRemoved: TNotifyEvent;
    FClosing: Boolean;
    FDestroying: Boolean;
    FReaderSession: ISerialReaderSession;
    ReadThread: TComPortReadThread;

    procedure BeginTransport;
    procedure EndTransport;
    procedure ConfigurePort(ABaudRate: TBaudRate; ACustomBaudRate: Integer;
      ADataBits: TDataBits; AParity: TParity; AStopBits: TStopBits;
      AFlowControl: TFlowControl);
    function ReadModemSignal(ASignal: TModemSignal): Boolean;
    procedure DeviceOpen;
    procedure DeviceClose;

    procedure CheckMainThread(const AOperation: string);
    procedure ComException(str: string);
    procedure ComDisconnected(Sender: TObject);
    procedure DeliverReaderReceive;
    procedure DeliverReaderError(const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure DeliverReaderStatus(Sender: TObject;
      Reason: THookSerialReason; const Value: string);
    procedure SynSerStatus(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    function AppliedBaudrate: integer;
    function CanReadData(const ATimeout: Integer;
      const ACheckError: Boolean = False): Boolean;
    function GetSynSer: TBlockSerial;

  protected
    procedure AdoptWatcherSnapshotForTesting(
      const ADevices: TSerialDeviceInfoArray);
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
    procedure TriggerDisconnected;

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Open;
    // Wait up to SynSer.DeadlockTimeout for queued output, then purge and close.
    // A nonpositive timeout skips waiting; unfinished output reports ErrTimeout.
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
    // Reports a terminal reader error on the main thread after closing the port.
    property OnError: TSerialErrorEvent read FOnError write FOnError;
    // Triggers if the device is removed during an active connection.
    property OnRemoved : TNotifyEvent read FOnRemoved write FOnRemoved;
  end;

{ Returns the version of TLazSerial itself, not TBlockSerial.GetVersion's
  version string for the bundled SynaSer implementation. }
function LazSerialGetVersion: string;
procedure Register;

implementation
uses LazSerialSetup;

function LazSerialGetVersion: string;
begin
  Result := LazSerialPackageVersion;
end;

type
  ISerialReaderFailureSession = interface
    ['{DDAA11B3-5038-4492-AC34-E81CC2105381}']
    procedure DeliverFailure(const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure NotifyFailure(const AErrorCode: Integer;
      const AErrorMessage: string);
  end;

  TSerialReaderEventKind = (srekReceive, srekStatus, srekFailure);

  TSerialReaderSession = class(TInterfacedObject, ISerialReaderSession,
    ISerialReaderFailureSession)
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
    procedure DeliverFailure(const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure NotifyFailure(const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure Detach;
    procedure SignalReader;
    function WaitForReader(const ATimeout: Cardinal): TWaitResult;
  end;

  TSerialReaderEventDelivery = class
  private
    FKind: TSerialReaderEventKind;
    FErrorCode: Integer;
    FReason: THookSerialReason;
    FSender: TObject;
    FSession: ISerialReaderSession;
    FValue: string;
    FReader: TComPortReadThread;
    procedure Deliver;
  public
    constructor CreateReceive(const ASession: ISerialReaderSession);
    constructor CreateStatus(const ASession: ISerialReaderSession;
      ASender: TObject; AReason: THookSerialReason; const AValue: string);
    constructor CreateFailure(const ASession: ISerialReaderSession;
      const AErrorCode: Integer; const AErrorMessage: string);
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

procedure TSerialReaderSession.DeliverFailure(const AErrorCode: Integer;
  const AErrorMessage: string);
var
  Lifetime: ISerialReaderFailureSession;
begin
  if not FActive or (FOwner = nil) then
    Exit;
  Supports(FOwner.FStatusSession, ISerialReaderFailureSession, Lifetime);
  try
    try
      FOwner.Close;
    except
      // Close has released the port; the reader error is the original failure.
      on E: ESynaSerError do ;
    end;
  finally
    // A close-status callback may have destroyed the component.
    if Lifetime <> nil then
      Lifetime.NotifyFailure(AErrorCode, AErrorMessage);
  end;
end;

procedure TSerialReaderSession.NotifyFailure(const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  if FActive and (FOwner <> nil) then
    FOwner.DeliverReaderError(AErrorCode, AErrorMessage);
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

constructor TSerialReaderEventDelivery.CreateFailure(
  const ASession: ISerialReaderSession; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  inherited Create;
  FSession := ASession;
  FKind := srekFailure;
  FErrorCode := AErrorCode;
  FValue := AErrorMessage;
end;

procedure TSerialReaderEventDelivery.Deliver;
var
  Session: ISerialReaderSession;
  FailureSession: ISerialReaderFailureSession;
begin
  Session := FSession;
  // A callback may close the port and free its reader. The running delivery
  // owns itself; only deliveries still waiting in the queue belong to it.
  if FReader <> nil then
    FReader.FQueuedDelivery := nil;
  try
    case FKind of
      srekReceive:
        Session.DeliverReceive;
      srekStatus:
        Session.DeliverStatus(FSender, FReason, FValue);
      srekFailure:
        if Supports(Session, ISerialReaderFailureSession, FailureSession) then
          FailureSession.DeliverFailure(FErrorCode, FValue);
    end;
  finally
    Session.SignalReader;
    Free;
  end;
end;

{ TLazSerial }

procedure TLazSerial.BeginTransport;
begin
  FTransportLock.Acquire;
  Inc(FTransportDepth);
end;

procedure TLazSerial.EndTransport;
var
  Statuses: TList;
  Delivery: TSerialReaderEventDelivery;
  Reader: TComPortReadThread;
  I: Integer;
begin
  Dec(FTransportDepth);
  Statuses := nil;
  Reader := nil;
  if FTransportDepth = 0 then
  begin
    Statuses := FPendingStatuses;
    FPendingStatuses := nil;
    if GetCurrentThreadID <> MainThreadID then
      Reader := ReadThread;
  end;
  FTransportLock.Release;
  if Statuses = nil then
    Exit;
  // Everything below uses local state: a callback can destroy this component.
  try
    for I := 0 to Statuses.Count - 1 do
    begin
      if (Reader <> nil) and Reader.Terminated then
        Break;
      Delivery := TSerialReaderEventDelivery(Statuses[I]);
      Statuses[I] := nil;
      if Reader = nil then
        Delivery.Deliver
      else
      begin
        Reader.QueueDelivery(Delivery);
        Reader.WaitForDelivery;
      end;
    end;
  finally
    for I := 0 to Statuses.Count - 1 do
      TObject(Statuses[I]).Free;
    Statuses.Free;
  end;
end;

procedure TLazSerial.ConfigurePort(ABaudRate: TBaudRate;
  ACustomBaudRate: Integer; ADataBits: TDataBits; AParity: TParity;
  AStopBits: TStopBits; AFlowControl: TFlowControl);
var
  Speed: Integer;
  Lifetime: ISerialReaderSession;
  Serial: TLazSerial;
begin
  Lifetime := FStatusSession;
  try
    BeginTransport;
    try
      if ACustomBaudRate < 0 then
        Speed := ConstsBaud[ABaudRate]
      else
        Speed := ACustomBaudRate;
      try
        if FTransport.IsOpen then
          FTransport.Configure(Speed, ConstsBits[ADataBits],
            ConstsParity[AParity], ConstsStopBits[AStopBits], AFlowControl);
      except
        if not FTransport.IsOpen then
        begin
          FActive := False;
          if FReaderSession <> nil then
            FReaderSession.Cancel;
          if ReadThread <> nil then
            ReadThread.Terminate;
        end;
        raise;
      end;
      FBaudRate := ABaudRate;
      FCustomBaudRate := ACustomBaudRate;
      FDataBits := ADataBits;
      FParity := AParity;
      FStopBits := AStopBits;
      FFlowControl := AFlowControl;
    finally
      EndTransport;
    end;
  except
    // Failed recovery closes the transport. Join its reader outside the lock;
    // a status callback may already have destroyed this component.
    Serial := (Lifetime as TSerialReaderSession).FOwner;
    if (Serial <> nil) and not Serial.FTransport.IsOpen then
      try
        Serial.DeviceClose;
      except
        on E: ESynaSerError do ; // Preserve the configuration error.
      end;
    raise;
  end;
end;

function TLazSerial.ReadModemSignal(ASignal: TModemSignal): Boolean;
begin
  BeginTransport;
  try
    case ASignal of
      msCTS: Result := FTransport.GetCTS;
      msCD: Result := FTransport.GetCarrier;
      msRI: Result := FTransport.GetRing;
      msDSR: Result := FTransport.GetDSR;
    end;
  finally
    EndTransport;
  end;
end;

procedure TLazSerial.Close;
begin
  CheckMainThread('TLazSerial.Close');
  Active:=false;
end;

procedure TLazSerial.DeviceClose;
var
  Delivery: TSerialReaderEventDelivery;
begin
  FClosing := True;
  try
    // Joining a reader must happen before acquiring the transport lock.
    if ReadThread <> nil then
    begin
      ReadThread.FreeOnTerminate := False;
      ReadThread.Terminate;
      if FReaderSession <> nil then
        FReaderSession.Cancel;
      while not ReadThread.Finished do
        Sleep(1);
      Delivery := TSerialReaderEventDelivery(ReadThread.FQueuedDelivery);
      ReadThread.FQueuedDelivery := nil;
      if Delivery <> nil then
      begin
        // Windows WaitFor can dispatch queued calls before the OS thread exits.
        TThread.RemoveQueuedEvents(nil, @Delivery.Deliver);
        Delivery.Free;
      end;
      ReadThread.WaitFor;
      ReadThread.Free;
      ReadThread := nil;
    end;
    FReaderSession := nil;
  except
    FClosing := False;
    raise;
  end;
  BeginTransport;
  try
    FTransport.Close;
  finally
    FActive := FTransport.IsOpen;
    FClosing := False;
    EndTransport;
  end;
end;

constructor TLazSerial.Create(AOwner: TComponent);
begin
  inherited;
  //FHandle:=-1;
  ReadThread := nil;
  FTransportLock := TCriticalSection.Create;
  FStatusSession := TSerialReaderSession.Create(Self);
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
  Result := CanReadData(0);
end;

function TLazSerial.CanReadData(const ATimeout: Integer;
  const ACheckError: Boolean): Boolean;
var
  Serial: TBlockSerial;
  Error: ESynaSerError;
begin
  BeginTransport;
  try
    if not FTransport.IsOpen then
      Exit(False);
    if FRcvLineCRLF then
      Result := FTransport.CanReadLine(ATimeout)
    else
      Result := FTransport.CanRead(ATimeout);
    if ACheckError and not Result then
    begin
      Serial := FTransport.NativeSerial;
      if (Serial <> nil) and (Serial.LastError <> 0) and
        (Serial.LastError <> ErrTimeout) then
      begin
        Error := ESynaSerError.Create(Serial.LastErrorDesc);
        Error.ErrorCode := Serial.LastError;
        Error.ErrorMessage := Serial.LastErrorDesc;
        raise Error;
      end;
    end;
  finally
    EndTransport;
  end;
end;

destructor TLazSerial.Destroy;
begin
  FDestroying := True;
  FStatusSession.Detach;
  FSerialWatcher.OnComDisconnected := nil;
  if FReaderSession <> nil then
    FReaderSession.Detach;
  try
    try
      Close;
    except
      // Close has released the port. A destructor must finish freeing itself.
      on E: ESynaSerError do ;
    end;
  finally
    try
      FTransport.SetStatusHandler(nil);
      FTransport.Free;
    finally
      FReaderSession := nil;
      FStatusSession := nil;
      FTransportLock.Free;
      inherited;
    end;
  end;
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
    try
      FTransport.Close;
    except
      // Cleanup must not replace the error that prevented opening the port.
      on E: ESynaSerError do ;
    end;
    raise;
  end;
end;


function TLazSerial.ReadData: string;
begin
  CheckMainThread('TLazSerial.ReadData');
  BeginTransport;
  try
    result:='';
    if not FTransport.IsOpen then
      ComException('can not read from a closed port.');
    if FRcvLineCRLF then
      Result := FTransport.ReadString(0)
    else
      Result := FTransport.ReadPacket(0);
  finally
    EndTransport;
  end;
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

procedure TLazSerial.AdoptWatcherSnapshotForTesting(
  const ADevices: TSerialDeviceInfoArray);
begin
  CheckMainThread('TLazSerial.AdoptWatcherSnapshotForTesting');
  FSerialWatcher.AdoptSnapshot(ADevices);
end;

procedure TLazSerial.SetActive(state: boolean);
begin
  CheckMainThread('TLazSerial.Active');
  if (state = FActive) and (state or (ReadThread = nil)) then
    Exit;
  if not state then
    DeviceClose
  else
  begin
    if ReadThread <> nil then
      DeviceClose;
    BeginTransport;
    try
      FSerialWatcher.Refresh;
      DeviceOpen;
      FActive := True;
    finally
      EndTransport;
    end;
  end;
end;

procedure TLazSerial.SetBaudRate(br: TBaudRate);
begin
  CheckMainThread('TLazSerial.BaudRate');
  if FCustomBaudRate < 0 then
    ConfigurePort(br, FCustomBaudRate, FDataBits, FParity, FStopBits, FFlowControl)
  else
    FBaudRate := br;
end;

procedure TLazSerial.SetCustomBaudrate(br: Integer);
begin
  CheckMainThread('TLazSerial.CustomBaudRate');
  if FCustomBaudRate = br then
    Exit;
  ConfigurePort(FBaudRate, br, FDataBits, FParity, FStopBits, FFlowControl);
end;

procedure TLazSerial.SetDataBits(db: TDataBits);
begin
  CheckMainThread('TLazSerial.DataBits');
  ConfigurePort(FBaudRate, FCustomBaudRate, db, FParity, FStopBits, FFlowControl);
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
  if FFlowControl = aFlowControl then
    Exit;
  ConfigurePort(FBaudRate, FCustomBaudRate, FDataBits, FParity, FStopBits,
    aFlowControl);
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
  ConfigurePort(FBaudRate, FCustomBaudRate, FDataBits, pr, FStopBits, FFlowControl);
end;

procedure TLazSerial.SetRcvLineCRLF(AValue: Boolean);
begin
  CheckMainThread('TLazSerial.RcvLineCRLF');
  FRcvLineCRLF := AValue;
end;

procedure TLazSerial.SetStopBits(sb: TStopBits);
begin
  CheckMainThread('TLazSerial.StopBits');
  ConfigurePort(FBaudRate, FCustomBaudRate, FDataBits, FParity, sb, FFlowControl);
end;

function TLazSerial.WriteBuffer(var buf; size: integer): integer;
begin
  CheckMainThread('TLazSerial.WriteBuffer');
  BeginTransport;
  try
    if not FTransport.IsOpen then
      ComException('can not write to a closed port.');
    result:= FTransport.SendBuffer(Pointer(@buf), size);
  finally
    EndTransport;
  end;
end;

function TLazSerial.WriteData(data: string): integer;
begin
  CheckMainThread('TLazSerial.WriteData');
  BeginTransport;
  try
    if not FTransport.IsOpen then
      ComException('can not write to a closed port.');
    result:=FTransport.SendString(data);
  finally
    EndTransport;
  end;
end;


function TLazSerial.ModemSignals: TModemSignals;
begin
  CheckMainThread('TLazSerial.ModemSignals');
  BeginTransport;
  try
    result:=[];
    if FTransport.GetCTS then result := result + [ msCTS ];
    if FTransport.GetCarrier then result := result + [ msCD ];
    if FTransport.GetRing then result := result + [ msRI ];
    if FTransport.GetDSR then result := result + [ msDSR ];
  finally
    EndTransport;
  end;
end;

function TLazSerial.GetDSR: boolean;
begin
  CheckMainThread('TLazSerial.GetDSR');
  result := ReadModemSignal(msDSR);
end;

function TLazSerial.GetCTS: boolean;
begin
  CheckMainThread('TLazSerial.GetCTS');
  result := ReadModemSignal(msCTS);
end;

function TLazSerial.GetRing: boolean;
begin
  CheckMainThread('TLazSerial.GetRing');
  result := ReadModemSignal(msRI);
end;

function TLazSerial.GetCarrier: boolean;
begin
  CheckMainThread('TLazSerial.GetCarrier');
  result := ReadModemSignal(msCD);
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
  BeginTransport;
  try
    FTransport.SetDTR(OnOff);
  finally
    EndTransport;
  end;
end;


procedure TLazSerial.SetRTS(OnOff: boolean);
begin
  CheckMainThread('TLazSerial.SetRTS');
  BeginTransport;
  try
    FTransport.SetRTS(OnOff);
  finally
    EndTransport;
  end;
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
var
  Delivery: TSerialReaderEventDelivery;
  Session: ISerialReaderSession;
begin
  if FDestroying then
    Exit;
  if FTransportDepth > 0 then
  begin
    if GetCurrentThreadID = MainThreadID then
      Session := FStatusSession
    else
      Session := FReaderSession;
    if FPendingStatuses = nil then
      FPendingStatuses := TList.Create;
    Delivery := TSerialReaderEventDelivery.CreateStatus(Session, Sender, Reason, Value);
    try
      FPendingStatuses.Add(Delivery);
    except
      Delivery.Free;
      raise;
    end;
    Exit;
  end;
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

procedure TComPortReadThread.QueueDelivery(ADelivery: TObject);
var
  Delivery: TSerialReaderEventDelivery;
begin
  Delivery := TSerialReaderEventDelivery(ADelivery);
  Delivery.FReader := Self;
  // Ordinary deliveries wait for completion; a failure ends the reader.
  FQueuedDelivery := Delivery;
  try
    TThread.Queue(nil, @Delivery.Deliver);
  except
    FQueuedDelivery := nil;
    Delivery.Free;
    raise;
  end;
end;

procedure TComPortReadThread.QueueReceive;
begin
  if Terminated then
    Exit;
  QueueDelivery(TSerialReaderEventDelivery.CreateReceive(FSession));
  WaitForDelivery;
end;

procedure TComPortReadThread.QueueStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Terminated then
    Exit;
  QueueDelivery(TSerialReaderEventDelivery.CreateStatus(
    FSession,
    Sender,
    Reason,
    Value
  ));
  WaitForDelivery;
end;

procedure TComPortReadThread.TerminatedSet;
begin
  inherited TerminatedSet;
  if FSession <> nil then
    FSession.SignalReader;
end;

procedure TComPortReadThread.QueueFailure(const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  if Terminated then
    Exit;
  QueueDelivery(TSerialReaderEventDelivery.CreateFailure(FSession,
    AErrorCode, AErrorMessage));
  // Exit without waiting: the main thread must be able to join this reader.
end;

procedure TComPortReadThread.Execute;
begin
  try
    while not Terminated do begin
      try
        if Owner.CanReadData(10, True) then
          QueueReceive
        else if not Terminated then
          FSession.WaitForReader(1);
      except
        on E: ESynaSerError do
        begin
          if E.ErrorCode = ErrTimeout then
            Continue;
          QueueFailure(E.ErrorCode, E.ErrorMessage);
          Exit;
        end;
        on E: Exception do
        begin
          QueueFailure(0, E.Message);
          Exit;
        end;
      end;
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

procedure TLazSerial.DeliverReaderError(const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  if not FDestroying and Assigned(FOnError) then
    FOnError(Self, AErrorCode, AErrorMessage);
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
