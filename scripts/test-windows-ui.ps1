param([Parameter(Mandatory=$true)][string]$AppPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$env:YAPPER_TEST_ROOT = Join-Path $env:TEMP ("Yapper-UI-" + [guid]::NewGuid())
$process = Start-Process -FilePath $AppPath -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    $window = $null
    while (!$window -and [DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { throw "App exited: $($process.ExitCode)" }
        if ($process.MainWindowHandle -ne 0) { $window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle) }
        if (!$window) { Start-Sleep -Milliseconds 200 }
    }
    if (!$window) { throw 'Yapper window did not appear' }
    $status = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'status'))
    if (!$status) { throw 'Status control missing' }
    foreach ($name in @('Transcribe', 'History', 'AI Models', 'Dictionary', 'Settings')) {
        $tab = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $name))
        if (!$tab) { throw "Missing tab: $name" }
        $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $pattern.Select()
    }
    Add-Type -AssemblyName System.Drawing
    $bounds = $window.Current.BoundingRectangle
    $bitmap = New-Object System.Drawing.Bitmap ([int]$bounds.Width), ([int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $bitmap.Size)
    $screenshot = Join-Path (Split-Path $AppPath -Parent) '../windows-ui.png'
    $bitmap.Save($screenshot)
    $graphics.Dispose()
    $bitmap.Dispose()
    Write-Host 'PASS Windows native window, status, and tab navigation'
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id }
    Remove-Item Env:YAPPER_TEST_ROOT
}
