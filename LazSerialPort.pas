{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit LazSerialPort;

{$warn 5023 off : no warning about unused units}
interface

uses
  LazSerial, SerialWatcher, SerialSelector, LazSerialCommon, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('LazSerial',@LazSerial.Register);
  RegisterUnit('SerialWatcher',@SerialWatcher.Register);
  RegisterUnit('SerialSelector',@SerialSelector.Register);
end;

initialization
  RegisterPackage('LazSerialPort',@Register);
end.
