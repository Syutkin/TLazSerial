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
  PropEdits, SerialWatcher, LazSerialCommon, LazSerialStatistics, LazSerialDevices,
  LazSerialReconnect, LazSerialWriteQueue, LazSerialSettings,
  LazSerialTransport, LazSerialWrite, LazSerialRead;

const
  { Version of this TLazSerial package, matching LazSerialPort.lpk. It is
    available without creating a serial port or loading a native library.
    Update it together with the package version when releasing TLazSerial. }
  LazSerialPackageVersion = '0.9.0';


type
  TBaudRate = LazSerialSettings.TBaudRate;
  TDataBits = LazSerialSettings.TDataBits;
  TParity = LazSerialSettings.TParity;
  TStopBits = LazSerialSettings.TStopBits;
  TSerialSettings = LazSerialSettings.TSerialSettings;

  TModemSignal = (msRI,msCD,msCTS,msDSR);
  TModemSignals = Set of TModemSignal;
  TStatusEvent = procedure(Sender: TObject; Reason: THookSerialReason; const Value: string) of object;
  TSerialErrorEvent = procedure(Sender: TObject; ErrorCode: Integer;
    const ErrorMessage: string) of object;

const
{$IFDEF UNIX}
  br_____0 = LazSerialSettings.br_____0;
  br____50 = LazSerialSettings.br____50;
  br____75 = LazSerialSettings.br____75;
  br___110 = LazSerialSettings.br___110;
  br___134 = LazSerialSettings.br___134;
  br___150 = LazSerialSettings.br___150;
  br___200 = LazSerialSettings.br___200;
  br___300 = LazSerialSettings.br___300;
  br___600 = LazSerialSettings.br___600;
  br__1200 = LazSerialSettings.br__1200;
  br__1800 = LazSerialSettings.br__1800;
  br__2400 = LazSerialSettings.br__2400;
  br__4800 = LazSerialSettings.br__4800;
  br__9600 = LazSerialSettings.br__9600;
  br_19200 = LazSerialSettings.br_19200;
  br_38400 = LazSerialSettings.br_38400;
  br_57600 = LazSerialSettings.br_57600;
  br115200 = LazSerialSettings.br115200;
  br230400 = LazSerialSettings.br230400;
{$IFNDEF DARWIN}
  br460800 = LazSerialSettings.br460800;
  br500000 = LazSerialSettings.br500000;
  br576000 = LazSerialSettings.br576000;
  br921600 = LazSerialSettings.br921600;
  br1000000 = LazSerialSettings.br1000000;
  br1152000 = LazSerialSettings.br1152000;
  br1500000 = LazSerialSettings.br1500000;
  br2000000 = LazSerialSettings.br2000000;
  br2500000 = LazSerialSettings.br2500000;
  br3000000 = LazSerialSettings.br3000000;
  br3500000 = LazSerialSettings.br3500000;
  br4000000 = LazSerialSettings.br4000000;
{$ENDIF}
{$ELSE}      // MSWINDOWS
  br___110 = LazSerialSettings.br___110;
  br___300 = LazSerialSettings.br___300;
  br___600 = LazSerialSettings.br___600;
  br__1200 = LazSerialSettings.br__1200;
  br__2400 = LazSerialSettings.br__2400;
  br__4800 = LazSerialSettings.br__4800;
  br__9600 = LazSerialSettings.br__9600;
  br_14400 = LazSerialSettings.br_14400;
  br_19200 = LazSerialSettings.br_19200;
  br_38400 = LazSerialSettings.br_38400;
  br_56000 = LazSerialSettings.br_56000;
  br_57600 = LazSerialSettings.br_57600;
  br115200 = LazSerialSettings.br115200;
  br128000 = LazSerialSettings.br128000;
  br230400 = LazSerialSettings.br230400;
  br250000 = LazSerialSettings.br250000;
  br256000 = LazSerialSettings.br256000;
  br460800 = LazSerialSettings.br460800;
  br921600 = LazSerialSettings.br921600;
{$ENDIF}
  db8bits = LazSerialSettings.db8bits;
  db7bits = LazSerialSettings.db7bits;
  db6bits = LazSerialSettings.db6bits;
  db5bits = LazSerialSettings.db5bits;
  pNone = LazSerialSettings.pNone;
  pOdd = LazSerialSettings.pOdd;
  pEven = LazSerialSettings.pEven;
  pMark = LazSerialSettings.pMark;
  pSpace = LazSerialSettings.pSpace;
  sbOne = LazSerialSettings.sbOne;
  sbOneAndHalf = LazSerialSettings.sbOneAndHalf;
  sbTwo = LazSerialSettings.sbTwo;

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

  TSerialWriteOutcome = LazSerialCommon.TSerialWriteOutcome;
  TSerialStatistics = LazSerialStatistics.TSerialStatistics;
  TSerialCloseReason = LazSerialStatistics.TSerialCloseReason;
  TSerialOpenLineState = LazSerialCommon.TSerialOpenLineState;
  TSerialWriteResult = LazSerialCommon.TSerialWriteResult;
  TSerialWriteCompletedEvent = procedure(Sender: TObject;
    const AResult: TSerialWriteResult) of object;

const
  scrNone = LazSerialStatistics.scrNone;
  scrUserRequest = LazSerialStatistics.scrUserRequest;
  scrDeviceRemoved = LazSerialStatistics.scrDeviceRemoved;
  scrReadError = LazSerialStatistics.scrReadError;
  scrConfigurationError = LazSerialStatistics.scrConfigurationError;
  scrDestroyed = LazSerialStatistics.scrDestroyed;
  olsDefault = LazSerialCommon.olsDefault;
  olsInactive = LazSerialCommon.olsInactive;
  olsActive = LazSerialCommon.olsActive;
  ErrReadBufferOverflow = LazSerialCommon.ErrReadBufferOverflow;
  swoCompleted = LazSerialCommon.swoCompleted;
  swoFailed = LazSerialCommon.swoFailed;
  swoCancelled = LazSerialCommon.swoCancelled;
  swoTimedOut = LazSerialCommon.swoTimedOut;

type

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
    FStatistics: ISerialStatisticsState;
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
    FStatistics: ISerialStatisticsState;
    FBufferedRead: Boolean;
    FReadBufferLimit: Integer;
    FReadOperation: ISerialReadOperation;
    FActive: boolean;
    FTransport: TLazSerialTransport;
    FTransportLock: TCriticalSection;
    FTransportDepth: Integer;
    FPendingStatuses: TList;
    FStatusSession: ISerialReaderSession;
    FDevice: string;
    FConnectedDevice: string;
    FConnectedDeviceTracked: Boolean;
    FConnectionId: QWord;

    FSerialWatcher : TSerialWatcher;
    FReconnect: TSerialReconnect;
    FOnReconnected: TNotifyEvent;
    FOnReconnectFailed: TSerialErrorEvent;

    FBaudRate: TBaudRate;
    FCustomBaudRate : Integer;
    FDataBits: TDataBits;
    FParity: TParity;
    FStopBits: TStopBits;
    
    FFlowControl: TFlowControl;
    FDtrOnOpen: TSerialOpenLineState;
    FRtsOnOpen: TSerialOpenLineState;
    FRcvLineCRLF : Boolean;

    FOnRxData: TNotifyEvent;
    FOnStatus: TStatusEvent;
    FOnError: TSerialErrorEvent;
    FOnRemoved: TNotifyEvent;
    FOnWriteCompleted: TSerialWriteCompletedEvent;
    FOnCloseCompleted: TNotifyEvent;
    FClosingConnectionId: QWord;
    FCloseCallDepth: Integer;
    FCloseNotificationQueued: Boolean;
    FWriteOperation: ISerialWriteOperation;
    FWriteId: QWord;
    FLastWriteId: QWord;
    FWriteSize: Integer;
    FWriteQueue: TSerialWriteQueue;
    FWriteQueueScheduled, FWriteQueueDispatching: Boolean;
    FWriteCloseRequested: Boolean;
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
    procedure OpenConnection(AReconnecting: Boolean);
    procedure ReconnectReady(Sender: TObject);
    procedure ReaderConnectionLost(AErrorCode: Integer);
    function GetAutoReconnect: Boolean;
    procedure SetAutoReconnect(AValue: Boolean);
    function GetReconnectIntervalMs: Cardinal;
    procedure SetReconnectIntervalMs(AValue: Cardinal);
    function GetReconnectMaxAttempts: Cardinal;
    procedure SetReconnectMaxAttempts(AValue: Cardinal);
    function GetReconnectPending: Boolean;

    procedure CheckMainThread(const AOperation: string);
    procedure ComException(str: string);
    procedure ComDisconnected(Sender: TObject);
    procedure DevicesRefreshed(Sender: TObject;
      const ADevices: TSerialDeviceInfoArray);
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
    function GetStatistics: TSerialStatistics;
    function GetClosePending: Boolean;
    procedure ScheduleCloseCompleted;
    procedure DeliverCloseCompleted;
    procedure SetBufferedRead(AValue: Boolean);
    procedure SetReadBufferLimit(AValue: Integer);
    procedure SetDtrOnOpen(AValue: TSerialOpenLineState);
    procedure SetRtsOnOpen(AValue: TSerialOpenLineState);
    function GetWritePending: Boolean;
    procedure CheckWriteIdle(const AOperation: string);
    procedure CheckPortConfiguration(const AOperation: string);
    procedure BufferedReadChanged;
    procedure WriteFinished(const AResult: TSerialWriteResult);
    procedure StartWriteOperation(const AData: AnsiString; AId: QWord;
      ATimeoutMs: Cardinal);
    procedure StartQueuedWrite(const ARequest: TSerialQueuedWrite);
    procedure ScheduleWriteQueue;
    procedure ProcessWriteQueue;
    function GetWriteQueueEnabled: Boolean;
    procedure SetWriteQueueEnabled(AValue: Boolean);
    function GetWriteQueueByteLimit: Integer;
    procedure SetWriteQueueByteLimit(AValue: Integer);
    function GetWriteQueueItemLimit: Integer;
    procedure SetWriteQueueItemLimit(AValue: Integer);
    function GetPendingWriteCount: Integer;
    function GetPendingWriteBytes: SizeInt;

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

    // Main-thread value snapshot; reading it never accesses the driver.
    function GetSettings: TSerialSettings;
    // Apply the complete data format in one configuration operation.
    // Existing configuration restrictions and rollback behavior apply.
    procedure ApplySettings(const ASettings: TSerialSettings);
    procedure Open;
    // Wait up to SynSer.DeadlockTimeout for queued output, then purge and close.
    // A nonpositive timeout skips waiting; unfinished output reports ErrTimeout.
    // A pending asynchronous write is cancelled and closed in the background;
    // buffered receive also closes in the background. Wait for ClosePending
    // and WritePending to clear, or handle OnCloseCompleted before reopening.
    procedure Close;
    // show a port settings dialog form
    procedure ShowSetupDialog;
    // read data from port
    function DataAvailable: boolean;
    function ReadData: string;
    // Buffered mode only. True includes a completed empty line; False clears
    // AData. An oversized line raises ESynaSerError/ErrMaxBuffer.
    function TryReadData(out AData: string): Boolean;
    // Requires BufferedRead=True and RcvLineCRLF=False. True also represents
    // an empty result; the exact terminator is consumed but excluded from Data.
    // Wrong modes raise EInvalidOperation naming the required setting.
    // MaxLength includes the terminator. ErrMaxBuffer preserves unread bytes.
    function TryReadUntil(const ATerminator: RawByteString;
      out AData: RawByteString; AMaxLength: Integer = 4096): Boolean;
    property ClosePending: Boolean read GetClosePending;
    // Waiting for the saved device, native cleanup or a retry; Active is False.
    property ReconnectPending: Boolean read GetReconnectPending;
    // Main-thread memory snapshot, available during I/O and after closing.
    property Statistics: TSerialStatistics read GetStatistics;

    // write data to port
    function WriteData(data: string): integer;
    function WriteBuffer(var buf; size: integer): integer;
    function WriteDataAsync(const AData: string;
      const ATimeoutMs: Cardinal): QWord;
    // Requests cancellation; queue mode also cancels every waiting entry.
    // WritePending stays true through native cleanup and result delivery.
    procedure CancelWrite;
    property WritePending: Boolean read GetWritePending;
    // Includes active, waiting and not-yet-delivered queue results.
    property PendingWriteCount: Integer read GetPendingWriteCount;
    property PendingWriteBytes: SizeInt read GetPendingWriteBytes;

    // read pin states
    function ModemSignals: TModemSignals;
    function GetDSR: boolean;
    function GetCTS: boolean;
    function GetRing: boolean;
    function GetCarrier: boolean;

    // set pin states
    procedure SetDTR(OnOff: boolean);
    procedure SetRTS(OnOff: boolean);

  published
    // Optional FIFO for WriteDataAsync. Change queue settings only when idle.
    property WriteQueueEnabled: Boolean read GetWriteQueueEnabled write SetWriteQueueEnabled default False;
    property WriteQueueByteLimit: Integer read GetWriteQueueByteLimit write SetWriteQueueByteLimit default DefaultWriteQueueByteLimit;
    property WriteQueueItemLimit: Integer read GetWriteQueueItemLimit write SetWriteQueueItemLimit default DefaultWriteQueueItemLimit;
    // Restore a previously opened, identifiable device after confirmed removal.
    // Manual Close/Active=False, Device changes and disabling cancel waiting.
    property AutoReconnect: Boolean read GetAutoReconnect write SetAutoReconnect default False;
    property ReconnectIntervalMs: Cardinal read GetReconnectIntervalMs write SetReconnectIntervalMs default DefaultReconnectIntervalMs;
    property ReconnectMaxAttempts: Cardinal read GetReconnectMaxAttempts write SetReconnectMaxAttempts default DefaultReconnectMaxAttempts;
    // Main-thread notification after automatic opening; starts a new session.
    property OnReconnected: TNotifyEvent read FOnReconnected write FOnReconnected;
    // Once after the retry budget is exhausted, with the last opening error.
    // Distinct from OnError, which retains its terminal-reader-error contract.
    property OnReconnectFailed: TSerialErrorEvent read FOnReconnectFailed write FOnReconnectFailed;
    property BufferedRead: Boolean read FBufferedRead write SetBufferedRead default False;
    property ReadBufferLimit: Integer read FReadBufferLimit write SetReadBufferLimit default 65536;
    property Active: boolean read FActive write SetActive;
    // Will be overridden by CustomBaudRate if its value is ≥ 0.
    property BaudRate: TBaudRate read FBaudRate write SetBaudRate;
    // If < 0 the value of BaudRate is used instead.
    property CustomBaudRate: integer read FCustomBaudRate write SetCustomBaudrate;
    property DataBits: TDataBits read FDataBits write SetDataBits;
    property Parity: TParity read FParity write SetParity;
    //fcHardware (legacy name) = fcRTS_CTS; fcXonXoff (legacy name) = fcXonXoff_and_DTR. The real XonXoff is named fcXonXoff_no_DTR
    property FlowControl: TFlowControl read FFlowControl write SetFlowControl;
    // Set while closed and idle; olsDefault preserves legacy line handling.
    property DtrOnOpen: TSerialOpenLineState read FDtrOnOpen write SetDtrOnOpen default olsDefault;
    property RtsOnOpen: TSerialOpenLineState read FRtsOnOpen write SetRtsOnOpen default olsDefault;
    property StopBits: TStopBits read FStopBits write SetStopBits;
    
    property SynSer: TBlockSerial read GetSynSer;
    property Device: string read FDevice write SetDevice;
    property RcvLineCRLF: Boolean read FRcvLineCRLF write SetRcvLineCRLF;

    property OnRxData: TNotifyEvent read FOnRxData write FOnRxData;
    property OnStatus: TStatusEvent read FOnStatus write FOnStatus;
    // Reports a terminal reader error after logical close on the main thread;
    // buffered native cleanup may still be pending.
    property OnError: TSerialErrorEvent read FOnError write FOnError;
    // Triggers if the device is removed during an active connection.
    property OnRemoved : TNotifyEvent read FOnRemoved write FOnRemoved;
    // Queued once per closed connection after RX/TX and native cleanup finish.
    // Active, ClosePending and WritePending are False before the handler.
    // Also covers synchronous close; suppressed on destruction or early reopen.
    property OnCloseCompleted: TNotifyEvent read FOnCloseCompleted write FOnCloseCompleted;
    property OnWriteCompleted: TSerialWriteCompletedEvent
      read FOnWriteCompleted write FOnWriteCompleted;
  end;

{ Returns the version of TLazSerial itself, not TBlockSerial.GetVersion's
  version string for the bundled SynaSer implementation. }
function LazSerialGetVersion: string;
procedure Register;

implementation

uses LazSerialSetup, LazFileUtils;

function NormalizeConnectedDevice(const ADevice: string): string;
begin
  Result := ADevice;
  {$IFDEF MSWINDOWS}
  if (Copy(Result, 1, 4) = '\\.\') or
    (Copy(Result, 1, 4) = '\\?\') then Delete(Result, 1, 4);
  Result := UpperCase(Result);
  {$ELSE}
  if (Pos('/', Result) > 0) or FileExists(Result) then
    Result := TryReadAllLinks(ExpandFileNameUTF8(Result));
  {$ENDIF}
end;

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

procedure RecordStatisticsException(const AStatistics: ISerialStatisticsState;
  E: Exception);
begin
  if E is ESynaSerError then
    AStatistics.RecordError(ESynaSerError(E).ErrorCode, ESynaSerError(E).ErrorMessage)
  else
    AStatistics.RecordError(0, E.Message);
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
  FOwner.FStatistics.MarkClosed(scrReadError);
  FOwner.ReaderConnectionLost(AErrorCode);
  try
    try
      FOwner.DeviceClose;
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

function TLazSerial.GetSettings: TSerialSettings;
begin
  CheckMainThread('TLazSerial.GetSettings');
  Result.BaudRate := FBaudRate;
  Result.CustomBaudRate := FCustomBaudRate;
  Result.DataBits := FDataBits;
  Result.Parity := FParity;
  Result.StopBits := FStopBits;
  Result.FlowControl := FFlowControl;
end;

procedure TLazSerial.ApplySettings(const ASettings: TSerialSettings);

  procedure CheckEnum(AValue, AMaximum: Integer; const AName: string);
  begin
    if (AValue < 0) or (AValue > AMaximum) then
      raise EArgumentException.CreateFmt('Invalid %s in serial settings', [AName]);
  end;

begin
  CheckMainThread('TLazSerial.ApplySettings');
  CheckPortConfiguration('TLazSerial.ApplySettings');
  // Validate the entire candidate before indexing enum tables or changing
  // driver/component state, including when saving settings for a later Open.
  CheckEnum(Ord(ASettings.BaudRate), Ord(High(TBaudRate)), 'BaudRate');
  CheckEnum(Ord(ASettings.DataBits), Ord(High(TDataBits)), 'DataBits');
  CheckEnum(Ord(ASettings.Parity), Ord(High(TParity)), 'Parity');
  CheckEnum(Ord(ASettings.StopBits), Ord(High(TStopBits)), 'StopBits');
  CheckEnum(Ord(ASettings.FlowControl), Ord(High(TFlowControl)), 'FlowControl');
  ValidateSerialOpenLines(FDtrOnOpen, FRtsOnOpen, ASettings.FlowControl);
  // ConfigurePort commits all properties together and delivers status callbacks
  // last. They may close, reopen or destroy this component.
  ConfigurePort(ASettings.BaudRate, ASettings.CustomBaudRate,
    ASettings.DataBits, ASettings.Parity, ASettings.StopBits,
    ASettings.FlowControl);
end;

procedure TLazSerial.ConfigurePort(ABaudRate: TBaudRate;
  ACustomBaudRate: Integer; ADataBits: TDataBits; AParity: TParity;
  AStopBits: TStopBits; AFlowControl: TFlowControl);
var
  Speed: Integer;
  Lifetime: ISerialReaderSession;
  Serial: TLazSerial;
begin
  CheckPortConfiguration('TLazSerial.ConfigurePort');
  if FActive then
    ValidateSerialOpenLines(FDtrOnOpen, FRtsOnOpen, AFlowControl);
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
        on E: Exception do
        begin
          RecordStatisticsException(FStatistics, E);
          if not FTransport.IsOpen then
          begin
            FStatistics.MarkClosed(scrConfigurationError);
            FActive := False;
            if FReaderSession <> nil then
              FReaderSession.Cancel;
            if ReadThread <> nil then
              ReadThread.Terminate;
          end;
          raise;
        end;
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
  if GetClosePending then
    raise EInvalidOperation.Create('Serial port cleanup is pending');
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
  TransportLocked: Boolean;
  Lifetime: ISerialReaderSession;
  Serial: TLazSerial;
begin
  Lifetime := FStatusSession;
  Inc(FCloseCallDepth);
  if FActive and not FDestroying then FClosingConnectionId := FConnectionId;
  TThread.RemoveQueuedEvents(nil, @ProcessWriteQueue);
  FWriteQueueScheduled := False;
  if FWriteQueue <> nil then FWriteQueue.Clear;
  TransportLocked := False;
  if FActive then
    if FDestroying then FStatistics.MarkClosed(scrDestroyed)
    else FStatistics.MarkClosed(scrUserRequest);
  FClosing := True;
  try
    if FReadOperation <> nil then
    begin
      FActive := False;
      FTransport.SetStatusHandler(nil);
      // Keep the progress callback until shared native cleanup is complete.
      // Inactive receive notifications only schedule close completion.
    end;
    if FWriteOperation <> nil then
    begin
      FWriteCloseRequested := True;
      FWriteOperation.DeferDelivery;
      if FReadOperation <> nil then FWriteOperation.Cancel;
    end;
    if FReadOperation <> nil then
    begin
      try
        FReadOperation.ClosePort;
      except
        if FWriteOperation <> nil then
          try FWriteOperation.ClosePort;
          except
            // Complete TX cleanup without replacing the RX startup error.
          end;
        raise;
      end;
      if FWriteOperation <> nil then FWriteOperation.ClosePort;
      Exit;
    end;

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
    if FWriteOperation <> nil then
    begin
      // The reader is stopped. The operation retains the native port while its
      // cancellation and close finish without holding the component's lock.
      FTransport.SetStatusHandler(nil);
      FActive := False;
      FWriteOperation.ClosePort;
      Exit;
    end;

    BeginTransport;
    TransportLocked := True;
    try
      FTransport.Close;
    finally
      FActive := FTransport.IsOpen;
    end;
  finally
    FClosing := False;
    // EndTransport can deliver a callback that destroys this component.
    try
      if TransportLocked then EndTransport;
    finally
      Serial := (Lifetime as TSerialReaderSession).FOwner;
      if Serial <> nil then
      begin
        Dec(Serial.FCloseCallDepth);
        Serial.ScheduleCloseCompleted;
      end;
    end;
  end;
end;

constructor TLazSerial.Create(AOwner: TComponent);
begin
  inherited;
  ReadThread := nil;
  FTransportLock := TCriticalSection.Create;
  FStatusSession := TSerialReaderSession.Create(Self);
  FTransport := TLazSynapseSerialTransport.Create;
  FStatistics := CreateSerialStatistics;
  FWriteQueue := TSerialWriteQueue.Create;
  FFlowControl := fcNone;
  FDtrOnOpen := olsDefault;
  FRtsOnOpen := olsDefault;
  FSerialWatcher := TSerialWatcher.Create(Self);
  FSerialWatcher.OnComDisconnected := @ComDisconnected;
  FSerialWatcher.OnDevicesRefreshed := @DevicesRefreshed;
  FReconnect := TSerialReconnect.Create(Self);
  FReconnect.OnReady := @ReconnectReady;
  FReadBufferLimit := 65536;
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
end;

procedure TLazSerial.SetDtrOnOpen(AValue: TSerialOpenLineState);
begin
  CheckMainThread('TLazSerial.DtrOnOpen');
  CheckWriteIdle('TLazSerial.DtrOnOpen');
  if FActive or GetClosePending then
    raise EInvalidOperation.Create('DtrOnOpen requires a closed idle port');
  FDtrOnOpen := AValue;
end;

procedure TLazSerial.SetRtsOnOpen(AValue: TSerialOpenLineState);
begin
  CheckMainThread('TLazSerial.RtsOnOpen');
  CheckWriteIdle('TLazSerial.RtsOnOpen');
  if FActive or GetClosePending then
    raise EInvalidOperation.Create('RtsOnOpen requires a closed idle port');
  FRtsOnOpen := AValue;
end;

procedure TLazSerial.SetBufferedRead(AValue: Boolean);
begin
  CheckMainThread('TLazSerial.BufferedRead');
  CheckWriteIdle('TLazSerial.BufferedRead');
  if FActive or GetClosePending then
    raise EInvalidOperation.Create('Receive mode requires a closed idle port');
  FBufferedRead := AValue;
end;

procedure TLazSerial.SetReadBufferLimit(AValue: Integer);
begin
  CheckMainThread('TLazSerial.ReadBufferLimit');
  CheckWriteIdle('TLazSerial.ReadBufferLimit');
  if FActive or GetClosePending then
    raise EInvalidOperation.Create('Receive limit requires a closed idle port');
  if AValue <= 0 then
    raise EArgumentException.Create('Receive limit must be positive');
  FReadBufferLimit := AValue;
end;

function TLazSerial.GetClosePending: Boolean;
begin
  CheckMainThread('TLazSerial.ClosePending');
  Result := FWriteCloseRequested and (FWriteOperation <> nil);
  if FReadOperation <> nil then
    Result := Result or FReadOperation.GetClosePending;
end;

procedure TLazSerial.ScheduleCloseCompleted;
begin
  if FDestroying or (FClosingConnectionId = 0) or FCloseNotificationQueued or
    (FCloseCallDepth <> 0) or FActive or GetClosePending or GetWritePending then Exit;
  FCloseNotificationQueued := True;
  try
    TThread.ForceQueue(nil, @DeliverCloseCompleted);
  except
    FCloseNotificationQueued := False;
    raise;
  end;
end;

procedure TLazSerial.DeliverCloseCompleted;
var Handler: TNotifyEvent;
begin
  FCloseNotificationQueued := False;
  if FDestroying or (FClosingConnectionId = 0) or (FCloseCallDepth <> 0) or
    FActive or GetClosePending or GetWritePending then Exit;
  FClosingConnectionId := 0;
  Handler := FOnCloseCompleted;
  // No component access after user code: the handler may reopen or destroy it.
  if Assigned(Handler) then Handler(Self);
end;

function TLazSerial.TryReadData(out AData: string): Boolean;
begin
  CheckMainThread('TLazSerial.TryReadData');
  AData := '';
  if not FBufferedRead then
    raise EInvalidOperation.Create('Buffered reads are not enabled');
  if not FActive or (FReadOperation = nil) then
    ComException('can not read from a closed port.');
  Result := FReadOperation.TryReadData(FRcvLineCRLF, AData);
end;

function TLazSerial.TryReadUntil(const ATerminator: RawByteString;
  out AData: RawByteString; AMaxLength: Integer): Boolean;
var Operation: ISerialReadUntilOperation;
begin
  CheckMainThread('TLazSerial.TryReadUntil');
  AData := '';
  if not FBufferedRead then
    raise EInvalidOperation.Create(
      'TryReadUntil requires BufferedRead=True; set it before opening the port');
  if FRcvLineCRLF then
    raise EInvalidOperation.Create('TryReadUntil requires RcvLineCRLF=False');
  if not FActive or (FReadOperation = nil) then
    ComException('can not read from a closed port.');
  if not Supports(FReadOperation, ISerialReadUntilOperation, Operation) then
    raise EInvalidOperation.Create('The active custom reader does not support TryReadUntil');
  Result := Operation.TryReadUntil(ATerminator, AData, AMaxLength);
end;

function TLazSerial.DataAvailable: boolean;
begin
  CheckMainThread('TLazSerial.DataAvailable');
  if FBufferedRead then
    Result := FActive and (FReadOperation <> nil) and
      FReadOperation.DataAvailable(FRcvLineCRLF)
  else Result := CanReadData(0);
end;

function TLazSerial.CanReadData(const ATimeout: Integer;
  const ACheckError: Boolean): Boolean;
var
  Serial: TBlockSerial;
  Error: ESynaSerError;
begin
  BeginTransport;
  try
    if FWriteCloseRequested then
      Exit(False);
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
  TThread.RemoveQueuedEvents(nil, @DeliverCloseCompleted);
  TThread.RemoveQueuedEvents(nil, @ProcessWriteQueue);
  FreeAndNil(FReconnect);
  FStatusSession.Detach;
  FSerialWatcher.OnComDisconnected := nil;
  FSerialWatcher.OnDevicesRefreshed := nil;
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
      if FWriteOperation <> nil then
      begin
        FWriteOperation.Detach;
        FWriteOperation := nil;
      end;
      if FReadOperation <> nil then
      begin
        FReadOperation.Detach;
        FReadOperation := nil;
      end;
      FTransport.SetStatusHandler(nil);
      FTransport.Free;
    finally
      FReaderSession := nil;
      FStatusSession := nil;
      FWriteQueue.Free;
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

function TLazSerial.GetAutoReconnect: Boolean;
begin
  CheckMainThread('TLazSerial.AutoReconnect');
  Result := FReconnect.Enabled;
end;

procedure TLazSerial.SetAutoReconnect(AValue: Boolean);
begin
  CheckMainThread('TLazSerial.AutoReconnect');
  if FReconnect.Enabled = AValue then Exit;
  FReconnect.Enabled := AValue;
  if AValue and FActive then FReconnect.Connected(FConnectedDevice);
end;

function TLazSerial.GetReconnectIntervalMs: Cardinal;
begin
  CheckMainThread('TLazSerial.ReconnectIntervalMs');
  Result := FReconnect.IntervalMs;
end;

procedure TLazSerial.SetReconnectIntervalMs(AValue: Cardinal);
begin
  CheckMainThread('TLazSerial.ReconnectIntervalMs');
  FReconnect.IntervalMs := AValue;
end;

function TLazSerial.GetReconnectMaxAttempts: Cardinal;
begin
  CheckMainThread('TLazSerial.ReconnectMaxAttempts');
  Result := FReconnect.MaxAttempts;
end;

procedure TLazSerial.SetReconnectMaxAttempts(AValue: Cardinal);
begin
  CheckMainThread('TLazSerial.ReconnectMaxAttempts');
  FReconnect.MaxAttempts := AValue;
end;

function TLazSerial.GetReconnectPending: Boolean;
begin
  CheckMainThread('TLazSerial.ReconnectPending');
  Result := FReconnect.Pending;
end;

procedure TLazSerial.ReconnectReady(Sender: TObject);
var DeviceName: string;
begin
  if FDestroying or FActive or not FReconnect.Pending then Exit;
  if GetClosePending or GetWritePending or FClosing then
  begin
    FReconnect.DeferAttempt;
    Exit;
  end;
  // Preserve the closed-state guarantee for a subscribed completion handler.
  if (FClosingConnectionId <> 0) and Assigned(FOnCloseCompleted) then
  begin
    ScheduleCloseCompleted;
    FReconnect.DeferAttempt;
    Exit;
  end;
  if not FReconnect.BeginAttempt(DeviceName) then Exit;
  FDevice := DeviceName;
  OpenConnection(True);
  // Opening delivers callbacks which may have destroyed this component.
end;

procedure TLazSerial.ReaderConnectionLost(AErrorCode: Integer);
begin
  if AErrorCode = ErrReadBufferOverflow then FReconnect.Cancel
  else FReconnect.ConnectionLost(False);
end;

procedure TLazSerial.OpenConnection(AReconnecting: Boolean);
var
  PreviousStatistics: ISerialStatisticsState;
  Lifetime: ISerialReaderSession;
  Serial: TLazSerial;
  Generation, OpenedId: QWord;
  Failed: Boolean;
  ErrorCode: Integer;
  ErrorMessage: string;
begin
  Lifetime := FStatusSession;
  Generation := FReconnect.Generation;
  OpenedId := 0;
  Failed := False;
  ErrorCode := 0;
  ErrorMessage := '';
  if ReadThread <> nil then DeviceClose;
  Serial := (Lifetime as TSerialReaderSession).FOwner;
  if Serial = nil then Exit;
  TThread.RemoveQueuedEvents(nil, @DeliverCloseCompleted);
  FCloseNotificationQueued := False;
  FClosingConnectionId := 0;
  if FReadOperation <> nil then
  begin
    FReadOperation.Detach;
    FReadOperation := nil;
  end;
  BeginTransport;
  try
    FSerialWatcher.Refresh;
    PreviousStatistics := FStatistics;
    FStatistics := CreateSerialStatistics;
    try
      FTransport.SetStatistics(FStatistics);
      DeviceOpen;
      FActive := True;
      FReconnect.Connected(FConnectedDevice);
      Generation := FReconnect.Generation;
      OpenedId := FConnectionId;
    except
      on E: Exception do
      begin
        FStatistics := PreviousStatistics;
        if not AReconnecting then raise;
        ErrorMessage := E.Message;
        if E is ESynaSerError then
        begin
          ErrorCode := ESynaSerError(E).ErrorCode;
          if ESynaSerError(E).ErrorMessage <> '' then
            ErrorMessage := ESynaSerError(E).ErrorMessage;
        end;
        Failed := FReconnect.AttemptFailed;
      end;
    end;
  finally
    EndTransport;
  end;
  // Status callbacks run outside the transport lock and may close, reopen or
  // destroy the component. Their exceptions must never become retry failures.
  Serial := (Lifetime as TSerialReaderSession).FOwner;
  if not AReconnecting or (Serial = nil) then Exit;
  if Serial.FReconnect.Generation <> Generation then Exit;
  if (OpenedId <> 0) and Serial.FActive and
    (Serial.FConnectionId = OpenedId) then
  begin
    if Assigned(Serial.FOnReconnected) then Serial.FOnReconnected(Serial);
  end
  else if Failed and not Serial.FActive and Assigned(Serial.FOnReconnectFailed) then
    Serial.FOnReconnectFailed(Serial, ErrorCode, ErrorMessage);
end;

procedure TLazSerial.ShowSetupDialog;
begin
  CheckMainThread('TLazSerial.ShowSetupDialog');
  CheckPortConfiguration('TLazSerial.ShowSetupDialog');
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
  CheckPortConfiguration('TLazSerial.SynSer');
  Result := FTransport.NativeSerial;
end;

function TLazSerial.GetStatistics: TSerialStatistics;
begin
  CheckMainThread('TLazSerial.Statistics');
  Result := FStatistics.Snapshot;
end;

procedure TLazSerial.DeviceOpen;
begin
  ValidateSerialOpenLines(FDtrOnOpen, FRtsOnOpen, FFlowControl);
  FTransport.ConfigureOpenLines(FDtrOnOpen, FRtsOnOpen, FFlowControl);
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
    Inc(FConnectionId);
    FConnectedDevice := NormalizeConnectedDevice(FTransport.DeviceName);
    FConnectedDeviceTracked := FSerialWatcher.ContainsDevice(FConnectedDevice);

    if FBufferedRead then
    begin
      FReadOperation := FTransport.CreateReadOperation(FReadBufferLimit, @BufferedReadChanged);
      if FReadOperation = nil then
        raise EInvalidOperation.Create('Transport returned no receive operation');
      FReadOperation.DataAvailable(FRcvLineCRLF);
      FReadOperation.Start;
      Exit;
    end;
    FReaderSession := TSerialReaderSession.Create(Self);
    ReadThread := TComPortReadThread.Create(Self, FReaderSession);
    ReadThread.Start;
  except
    FReaderSession := nil;
    FreeAndNil(ReadThread);
    if FReadOperation <> nil then
    begin
      FTransport.SetStatusHandler(nil);
      FReadOperation.Detach;
      FReadOperation.ClosePort;
    end
    else try
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
  if FBufferedRead then
  begin
    TryReadData(Result);
    Exit;
  end;
  if FWriteCloseRequested then
    ComException('can not read from a closed port.');
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
  CheckWriteIdle('TLazSerial.ReplaceTransportForTesting');
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
  // Explicit requests cancel waiting even when Active is already False.
  if (FReconnect <> nil) and (not state or not FActive) then FReconnect.Cancel;
  if state and (FWriteCloseRequested or GetClosePending) then
    raise EInvalidOperation.Create('Serial port cleanup is pending');
  if (state = FActive) and (state or (ReadThread = nil)) then
    Exit;
  if not state then
    DeviceClose
  else
    OpenConnection(False);
end;

procedure TLazSerial.SetBaudRate(br: TBaudRate);
begin
  CheckMainThread('TLazSerial.BaudRate');
  CheckPortConfiguration('TLazSerial.BaudRate');
  if FCustomBaudRate < 0 then
    ConfigurePort(br, FCustomBaudRate, FDataBits, FParity, FStopBits, FFlowControl)
  else
    FBaudRate := br;
end;

procedure TLazSerial.SetCustomBaudrate(br: Integer);
begin
  CheckMainThread('TLazSerial.CustomBaudRate');
  CheckPortConfiguration('TLazSerial.CustomBaudRate');
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
  CheckPortConfiguration('TLazSerial.Device');
  if (FDevice <> ADevice) and (FReconnect <> nil) then FReconnect.Cancel;
  FDevice := ADevice;
end;

procedure TLazSerial.SetFlowControl(aFlowControl: TFlowControl);
begin
  CheckMainThread('TLazSerial.FlowControl');
  CheckPortConfiguration('TLazSerial.FlowControl');
  if FFlowControl = aFlowControl then
    Exit;
  ConfigurePort(FBaudRate, FCustomBaudRate, FDataBits, FParity, FStopBits,
    aFlowControl);
end;


procedure TLazSerial.SetParity(pr: TParity);
begin
  CheckMainThread('TLazSerial.Parity');
  ConfigurePort(FBaudRate, FCustomBaudRate, FDataBits, pr, FStopBits, FFlowControl);
end;

procedure TLazSerial.SetRcvLineCRLF(AValue: Boolean);
begin
  CheckMainThread('TLazSerial.RcvLineCRLF');
  if not (FBufferedRead and FActive) then CheckWriteIdle('TLazSerial.RcvLineCRLF');
  FRcvLineCRLF := AValue;
  if FReadOperation <> nil then FReadOperation.DataAvailable(AValue);
end;

procedure TLazSerial.SetStopBits(sb: TStopBits);
begin
  CheckMainThread('TLazSerial.StopBits');
  ConfigurePort(FBaudRate, FCustomBaudRate, FDataBits, FParity, sb, FFlowControl);
end;

function TLazSerial.WriteBuffer(var buf; size: integer): integer;
begin
  CheckMainThread('TLazSerial.WriteBuffer');
  CheckWriteIdle('TLazSerial.WriteBuffer');
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
  CheckWriteIdle('TLazSerial.WriteData');
  BeginTransport;
  try
    if not FTransport.IsOpen then
      ComException('can not write to a closed port.');
    result:=FTransport.SendString(data);
  finally
    EndTransport;
  end;
end;

function TLazSerial.GetWritePending: Boolean;
begin
  CheckMainThread('TLazSerial.WritePending');
  Result := (FWriteOperation <> nil) or
    ((FWriteQueue <> nil) and (FWriteQueue.Count > 0));
end;

procedure TLazSerial.CheckPortConfiguration(const AOperation: string);
begin
  CheckWriteIdle(AOperation);
  if (FReadOperation <> nil) and FActive then
    raise EInvalidOperation.CreateFmt('%s: buffered receiver is active', [AOperation]);
end;

procedure TLazSerial.CheckWriteIdle(const AOperation: string);
begin
  if (FReadOperation <> nil) and FReadOperation.GetClosePending then
    raise EInvalidOperation.CreateFmt('%s: serial cleanup is pending', [AOperation]);
  if GetWritePending then
    raise EInvalidOperation.CreateFmt('%s: an asynchronous write is pending',
      [AOperation]);
end;

function TLazSerial.GetWriteQueueEnabled: Boolean;
begin CheckMainThread('TLazSerial.WriteQueueEnabled'); Result := FWriteQueue.Enabled; end;
procedure TLazSerial.SetWriteQueueEnabled(AValue: Boolean);
begin
  CheckMainThread('TLazSerial.WriteQueueEnabled');
  if FWriteQueue.Enabled = AValue then Exit;
  CheckWriteIdle('TLazSerial.WriteQueueEnabled');
  FWriteQueue.Enabled := AValue;
end;
function TLazSerial.GetWriteQueueByteLimit: Integer;
begin CheckMainThread('TLazSerial.WriteQueueByteLimit'); Result := FWriteQueue.ByteLimit; end;
procedure TLazSerial.SetWriteQueueByteLimit(AValue: Integer);
begin
  CheckMainThread('TLazSerial.WriteQueueByteLimit');
  CheckWriteIdle('TLazSerial.WriteQueueByteLimit');
  FWriteQueue.ByteLimit := AValue;
end;
function TLazSerial.GetWriteQueueItemLimit: Integer;
begin CheckMainThread('TLazSerial.WriteQueueItemLimit'); Result := FWriteQueue.ItemLimit; end;
procedure TLazSerial.SetWriteQueueItemLimit(AValue: Integer);
begin
  CheckMainThread('TLazSerial.WriteQueueItemLimit');
  CheckWriteIdle('TLazSerial.WriteQueueItemLimit');
  FWriteQueue.ItemLimit := AValue;
end;
function TLazSerial.GetPendingWriteCount: Integer;
begin
  CheckMainThread('TLazSerial.PendingWriteCount');
  Result := FWriteQueue.Count;
  if (Result = 0) and (FWriteOperation <> nil) then Result := 1;
end;
function TLazSerial.GetPendingWriteBytes: SizeInt;
begin
  CheckMainThread('TLazSerial.PendingWriteBytes');
  if FWriteQueue.Count > 0 then Result := FWriteQueue.Bytes
  else Result := FWriteSize;
end;
procedure TLazSerial.StartWriteOperation(const AData: AnsiString; AId: QWord;
  ATimeoutMs: Cardinal);
var Operation: ISerialWriteOperation;
begin
  Operation := FTransport.CreateWriteOperation(AData, AId, ATimeoutMs, @WriteFinished);
  if Operation = nil then
    raise EInvalidOperation.Create('Transport returned no write operation');
  FWriteOperation := Operation;
  FWriteCloseRequested := False;
  FWriteId := AId;
  FWriteSize := Length(AData);
  try
    Operation.Start;
  except
    Operation.Detach;
    FWriteOperation := nil;
    FWriteSize := 0;
    raise;
  end;
end;
procedure TLazSerial.StartQueuedWrite(const ARequest: TSerialQueuedWrite);
var Failure: TSerialWriteResult;
begin
  BeginTransport;
  try
    try
      if not FTransport.IsOpen then ComException('can not write to a closed port.');
      StartWriteOperation(ARequest.Data, ARequest.OperationId, ARequest.TimeoutMs);
    except
      on E: Exception do
      begin
        Failure := Default(TSerialWriteResult);
        Failure.OperationId := ARequest.OperationId;
        Failure.BytesRequested := Length(ARequest.Data);
        Failure.Outcome := swoFailed;
        Failure.ErrorMessage := E.Message;
        if E is ESynaSerError then
        begin
          Failure.ErrorCode := ESynaSerError(E).ErrorCode;
          if ESynaSerError(E).ErrorMessage <> '' then
            Failure.ErrorMessage := ESynaSerError(E).ErrorMessage;
        end;
        FStatistics.RecordError(Failure.ErrorCode, Failure.ErrorMessage);
        FTransport.CompleteWrite(Failure);
        FWriteQueue.Complete(Failure);
      end;
    end;
  finally
    // Status callbacks may destroy the component or raise. They are not
    // transport failures and must stay outside the startup exception handler.
    EndTransport;
  end;
end;
procedure TLazSerial.ScheduleWriteQueue;
begin
  if FDestroying or FWriteQueueScheduled or FWriteQueueDispatching or
    (FWriteQueue.Count = 0) or (FWriteOperation <> nil) or FClosing or
    GetClosePending then Exit;
  FWriteQueueScheduled := True;
  try
    TThread.ForceQueue(nil, @ProcessWriteQueue);
  except
    FWriteQueueScheduled := False;
    raise;
  end;
end;
procedure TLazSerial.ProcessWriteQueue;
var
  Lifetime: ISerialReaderSession;
  Serial: TLazSerial;
  Request: TSerialQueuedWrite;
  WriteResult: TSerialWriteResult;
  Handler: TSerialWriteCompletedEvent;
begin
  FWriteQueueScheduled := False;
  if FDestroying or FWriteQueueDispatching or (FWriteOperation <> nil) or
    FClosing or GetClosePending then Exit;
  Lifetime := FStatusSession;
  FWriteQueueDispatching := True;
  try
    if FWriteQueue.PopResult(WriteResult) then
    begin
      Handler := FOnWriteCompleted;
      if Assigned(Handler) then Handler(Self, WriteResult);
    end
    else if FWriteQueue.BeginNext(Request) then StartQueuedWrite(Request);
  finally
    // Only local lifetime state is safe after a completion or status callback.
    // Schedule after leaving the handler, including when it raises, so nested
    // CheckSynchronize cannot launch the next write inside user code.
    Serial := (Lifetime as TSerialReaderSession).FOwner;
    if Serial <> nil then
    begin
      Serial.FWriteQueueDispatching := False;
      Serial.ScheduleWriteQueue;
    end;
  end;
end;

function TLazSerial.WriteDataAsync(const AData: string;
  const ATimeoutMs: Cardinal): QWord;
var NextId: QWord;
begin
  CheckMainThread('TLazSerial.WriteDataAsync');
  if not FWriteQueue.Enabled then CheckWriteIdle('TLazSerial.WriteDataAsync')
  else if FClosing or FWriteCloseRequested or GetClosePending then
    raise EInvalidOperation.Create('WriteDataAsync: serial cleanup is pending');
  if ATimeoutMs = 0 then
    raise EArgumentException.Create('Write timeout must be greater than zero');
  if Length(AData) > High(Integer) then
    raise EArgumentException.Create('Write buffer is too large');
  if not FActive then
    ComException('can not write to a closed port.');
  if FLastWriteId = High(QWord) then
    raise EInvalidOperation.Create('Write operation identifiers exhausted');
  NextId := FLastWriteId + 1;
  if FWriteQueue.Enabled then
  begin
    FWriteQueue.Push(NextId, AData, ATimeoutMs);
    try
      ScheduleWriteQueue;
    except
      FWriteQueue.RollbackPush(NextId);
      raise;
    end;
    FLastWriteId := NextId;
    Exit(NextId);
  end;
  BeginTransport;
  try
    if not FTransport.IsOpen then
      ComException('can not write to a closed port.');
    StartWriteOperation(AData, NextId, ATimeoutMs);
    FLastWriteId := NextId;
  finally
    EndTransport;
  end;
  Result := NextId;
end;

procedure TLazSerial.CancelWrite;
begin
  CheckMainThread('TLazSerial.CancelWrite');
  if FWriteQueue.Enabled then FWriteQueue.CancelWaiting;
  if FWriteOperation <> nil then
    FWriteOperation.Cancel
  else ScheduleWriteQueue;
end;

procedure TLazSerial.WriteFinished(const AResult: TSerialWriteResult);
var
  Operation: ISerialWriteOperation;
  Handler: TSerialWriteCompletedEvent;
begin
  if (FWriteOperation = nil) or (AResult.OperationId <> FWriteId) then
    Exit;
  Operation := FWriteOperation;
  FWriteOperation := nil;
  FWriteSize := 0;
  Operation.Detach;
  if FWriteCloseRequested then
  begin
    FWriteCloseRequested := False;
    ScheduleCloseCompleted;
    Exit;
  end;
  FTransport.CompleteWrite(AResult);
  if FWriteQueue.ActiveId = AResult.OperationId then
  begin
    FWriteQueue.Complete(AResult);
    ScheduleWriteQueue;
    Exit;
  end;
  Handler := FOnWriteCompleted;
  // Do not access component state after calling user code.
  if not FDestroying and Assigned(Handler) then
    Handler(Self, AResult);
end;


function TLazSerial.ModemSignals: TModemSignals;
begin
  CheckMainThread('TLazSerial.ModemSignals');
  if GetClosePending then
    raise EInvalidOperation.Create('Serial port cleanup is pending');
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


procedure TLazSerial.SetDTR(OnOff: boolean);
begin
  CheckMainThread('TLazSerial.SetDTR');
  CheckPortConfiguration('TLazSerial.SetDTR');
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
  CheckPortConfiguration('TLazSerial.SetRTS');
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
  FStatistics := AOwner.FStatistics;
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
  FStatistics.RecordError(AErrorCode, AErrorMessage);
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

procedure TLazSerial.BufferedReadChanged;
var
  Operation: ISerialReadOperation;
  Lifetime: ISerialReaderSession;
  Serial: TLazSerial;
  Code: Integer;
  Message, Partial: string;
begin
  Operation := FReadOperation;
  if (Operation = nil) or FDestroying then Exit;
  if not FActive then
  begin
    ScheduleCloseCompleted;
    Exit;
  end;
  Lifetime := FStatusSession;
  if Operation.GetFailure(Code, Message) then
  begin
    FStatistics.MarkClosed(scrReadError);
    ReaderConnectionLost(Code);
    DeviceClose;
    Serial := (Lifetime as TSerialReaderSession).FOwner;
    if Serial <> nil then Serial.DeliverReaderError(Code, Message);
    Exit;
  end;
  if not Operation.DataAvailable(FRcvLineCRLF) then
  begin
    // Progress through an already rejected line without reporting incomplete
    // input to the user. The same parser retains any healthy partial line.
    if FRcvLineCRLF then Operation.TryReadData(True, Partial);
    Exit;
  end;
  DeliverReaderReceive;
  // The handler can destroy this component. Do not access fields afterwards.
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

procedure TLazSerial.DevicesRefreshed(Sender: TObject;
  const ADevices: TSerialDeviceInfoArray);
begin
  FReconnect.Observe(ADevices);
  if FActive and FSerialWatcher.ContainsDevice(FConnectedDevice) then
    FConnectedDeviceTracked := True;
end;

procedure TLazSerial.TriggerDisconnected;
var
  Lifetime: ISerialReaderSession;
  Serial: TLazSerial;
  ConnectionId: QWord;
begin
  if not FActive then Exit;
  if FSerialWatcher.ContainsDevice(FConnectedDevice) then
  begin
    FConnectedDeviceTracked := True;
    Exit;
  end;
  // Absence from enumeration cannot prove removal of an unlisted path.
  if not FConnectedDeviceTracked then Exit;
  Lifetime := FStatusSession;
  ConnectionId := FConnectionId;
  FStatistics.MarkClosed(scrDeviceRemoved);
  FReconnect.ConnectionLost(True);
  DeviceClose;
  Serial := (Lifetime as TSerialReaderSession).FOwner;
  if (Serial <> nil) and (Serial.FConnectionId = ConnectionId) and
    not Serial.FActive and Assigned(Serial.FOnRemoved) then
    Serial.FOnRemoved(Serial);
end;

procedure TLazSerial.ComDisconnected(Sender: TObject);
begin
  TriggerDisconnected;
end;

procedure Register;
begin
  RegisterComponents('LazSerial', [TLazSerial]);
  RegisterPropertyEditor(TypeInfo(boolean), TLazSerial, 'Active', THiddenPropertyEditor);
end;

initialization
{$i TLazSerial.lrs}

end.
