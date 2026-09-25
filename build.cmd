@echo off
rem Builds bin\PingGadget.exe with the C# compiler that ships with Windows (.NET Framework 4.x).
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
cd /d "%~dp0"
if not exist bin mkdir bin
"%CSC%" /nologo /target:winexe /optimize+ /out:bin\PingGadget.exe /win32manifest:app.manifest ^
  /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll ^
  src\*.cs
