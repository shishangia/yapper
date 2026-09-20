#define AppVersion "0.1.0-preview.2"
[Setup]
AppId={{19F43172-BD41-4AB7-9C15-0522D0AC6050}
AppName=Yapper
AppVersion={#AppVersion}
AppPublisher=Shivam Shishangia
AppPublisherURL=https://github.com/shishangia/yapper
DefaultDirName={localappdata}\Programs\Yapper
DefaultGroupName=Yapper
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=..\..\dist\windows
OutputBaseFilename=Yapper-{#AppVersion}-win-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=Yapper.ico
CloseApplications=yes
UninstallDisplayIcon={app}\Yapper.exe
LicenseFile=..\..\LICENSE
[Files]
Source: "..\..\dist\windows\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Yapper"; Filename: "{app}\Yapper.exe"
Name: "{autodesktop}\Yapper"; Filename: "{app}\Yapper.exe"; Tasks: desktopicon
[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\Yapper.exe"; Description: "Open Yapper"; Flags: nowait postinstall skipifsilent
