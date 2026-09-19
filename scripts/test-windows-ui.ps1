param([Parameter(Mandatory=$true)][string]$AppPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$env:YAPPER_TEST_ROOT = Join-Path $env:TEMP ("Yapper-UI-" + [guid]::NewGuid())
$testRoot = $env:YAPPER_TEST_ROOT
New-Item -ItemType Directory -Path $testRoot | Out-Null
$fixture = [ordered]@{
    Version = 1
    Recordings = @([ordered]@{Id='71a528e0-d4fd-4bfa-bdcd-d0c30c09e42c';Date='2026-01-01T12:00:00Z';Text='Hello there';Duration=2;AudioPath='missing-test-audio.wav';Model='Synthetic fixture';Conversation=@{SpeakerDetectionRequested=$true;Segments=@(@{Id=0;Start=0;End=1;Text='Hello';SpeakerId='1'},@{Id=1;Start=1;End=2;Text=' there';SpeakerId='2'});SpeakerNames=@{'1'='Test Alice';'2'='Test Bob'}}})
    Usage = @()
    Dictionary = @()
}
$fixture | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $testRoot 'library.json') -Encoding utf8
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
    $history = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'History'))
    $history.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $entry = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))
    if (!$entry) { throw 'Synthetic history entry did not load' }
    $entry.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $review = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Review / edit turns'))
    $review.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $editor = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (!$editor -and [DateTime]::UtcNow -lt $deadline) {
        $editor = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Yapper · Review transcript'))
        if (!$editor) { Start-Sleep -Milliseconds 100 }
    }
    if (!$editor) { throw 'Transcript editor did not open' }
    $editor.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Write-Host 'PASS Windows native window, status, tab navigation, history load, and transcript editor'
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id }
    Remove-Item Env:YAPPER_TEST_ROOT
}
