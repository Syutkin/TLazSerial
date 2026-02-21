program SerTest;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms,
  { you can add units after this } Main, LazSerialPort;

{$R *.res}

begin
  Application.Title:='';
  Application.Initialize;
  Application.CreateForm(TFMain, FMain);
  Application.Run;
end.

