$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root 'dist/windows'
$app = Join-Path $output 'app'
dotnet publish "$root/windows/Yapper.Windows/Yapper.Windows.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:RestoreLockedMode=true -o $app
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed' }
Copy-Item "$root/LICENSE" "$app/LICENSE.txt"
Copy-Item "$root/windows/Yapper.Windows/ThirdPartyNotices.txt" "$app/ThirdPartyNotices.txt"
Copy-Item "$root/windows/Licenses" "$app/Licenses" -Recurse -Force
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -property installationPath
$crt = Get-ChildItem "$vs/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT" -Directory | Sort-Object FullName -Descending | Select-Object -First 1
if (!$crt) { throw 'The build machine needs the licensed Visual C++ x64 CRT redistributables.' }
Get-ChildItem $crt.FullName -Filter '*.dll' | Copy-Item -Destination $app
Get-ChildItem $app -Recurse -Filter 'whisper.dll' | ForEach-Object { Get-ChildItem $crt.FullName -Filter '*.dll' | Copy-Item -Destination $_.Directory.FullName }
$compiler = "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe"
if (!(Test-Path $compiler)) { throw 'Install Inno Setup 6 on the build machine to package the installer.' }
& $compiler "$root/windows/Yapper.Windows/Installer.iss"
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed' }
$installer = Join-Path $output 'Yapper-0.1.0-preview.3-win-x64-setup.exe'
$hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
"$hash  $(Split-Path -Leaf $installer)" | Set-Content "$installer.sha256" -Encoding ascii
Write-Host "Installer: $installer"
Write-Host "SHA256: $hash"
