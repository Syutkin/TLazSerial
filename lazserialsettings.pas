unit LazSerialSettings;

{$mode ObjFPC}{$H+}

interface

uses LazSerialCommon;

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
  TStopBits=(sbOne,sbOneAndHalf,sbTwo);

  // Value snapshot of the port's data format. Start with Serial.GetSettings
  // when editing a subset; a negative CustomBaudRate selects BaudRate.
  TSerialSettings = record
    BaudRate: TBaudRate;
    CustomBaudRate: Integer;
    DataBits: TDataBits;
    Parity: TParity;
    StopBits: TStopBits;
    FlowControl: TFlowControl;
  end;

implementation

end.
