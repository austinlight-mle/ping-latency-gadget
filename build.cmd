@echo off
rem Builds bin\PingGadget.exe with the C# compiler that ships with Windows (.NET Framework 4.x).
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
cd /d "%~dp0"

set "APP_VERSION="
if exist VERSION set /p APP_VERSION=<VERSION
if not defined APP_VERSION (
  echo error: the VERSION file is missing or empty. 1>&2
  exit /b 1
)

rem Stamp the version into the exe (Explorer: Properties, Details).
set VERSION_CS=%TEMP%\PingGadgetVersion.cs
 >"%VERSION_CS%" echo [assembly: System.Reflection.AssemblyTitle("Ping Gadget")]
>>"%VERSION_CS%" echo [assembly: System.Reflection.AssemblyProduct("Ping Gadget")]
>>"%VERSION_CS%" echo [assembly: System.Reflection.AssemblyVersion("%APP_VERSION%")]
>>"%VERSION_CS%" echo [assembly: System.Reflection.AssemblyFileVersion("%APP_VERSION%")]
>>"%VERSION_CS%" echo [assembly: System.Reflection.AssemblyInformationalVersion("%APP_VERSION%")]

if not exist bin mkdir bin
"%CSC%" /nologo /target:winexe /optimize+ /out:bin\PingGadget.exe /win32manifest:app.manifest /win32icon:PingGadget.ico ^
  /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll ^
  src\*.cs "%VERSION_CS%"
set RC=%ERRORLEVEL%
del "%VERSION_CS%"
exit /b %RC%
