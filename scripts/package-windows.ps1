$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root 'dist/windows'
$app = Join-Path $output 'app'
$cargoTarget = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $root 'build/windows-cargo' }
$env:CARGO_TARGET_DIR = $cargoTarget
cargo build --locked --manifest-path "$root/windows/Yapper.Nemotron/Cargo.toml" --release --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Nemotron helper build failed' }
dotnet publish "$root/windows/Yapper.Windows/Yapper.Windows.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:RestoreLockedMode=true -o $app
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed' }
$vulkanWhisper = Join-Path $app 'runtimes/vulkan/win-x64/whisper.dll'
if (!(Test-Path $vulkanWhisper)) { throw 'The Vulkan Whisper runtime was not packaged.' }
Copy-Item "$cargoTarget/x86_64-pc-windows-msvc/release/yapper-nemotron.exe" "$app/Yapper.Nemotron.exe"
$directML = Join-Path $cargoTarget 'x86_64-pc-windows-msvc/release/DirectML.dll'
if (!(Test-Path $directML)) { throw 'DirectML was not produced with the Nemotron helper.' }
Copy-Item $directML "$app/DirectML.dll"
if (!(Test-Path "$app/Yapper.Nemotron.exe") -or !(Test-Path "$app/DirectML.dll")) {
    throw 'Nemotron helper runtime was not packaged'
}
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
$installer = Join-Path $output 'Yapper-1.1.1-win-x64-setup.exe'
$hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
"$hash  $(Split-Path -Leaf $installer)" | Set-Content "$installer.sha256" -Encoding ascii
Write-Host "Installer: $installer"
Write-Host "SHA256: $hash"
