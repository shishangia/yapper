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
    Add-Type -AssemblyName System.Drawing
    $output = Join-Path (Split-Path $AppPath -Parent) '../windows-screenshots'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    function Select-Page([string]$id) {
        $tab = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
        if (!$tab) { throw "Missing sidebar route: $id" }
        $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    function Capture-Window($element, [string]$name) {
        $bounds = $element.Current.BoundingRectangle
        $bitmap = New-Object System.Drawing.Bitmap ([int]$bounds.Width), ([int]$bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $bitmap.Size)
        $bitmap.Save((Join-Path $output "$name.png"))
        $graphics.Dispose(); $bitmap.Dispose()
    }
    foreach ($appearance in @('Light', 'Dark')) {
        Select-Page 'sidebar.settings'
        $theme = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'themeChoice'))
        if (!$theme) { throw 'Theme picker missing' }
        $theme.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        $choice = $theme.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $appearance))
        if (!$choice) { throw "Theme choice missing: $appearance" }
        $choice.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        foreach ($route in @('dashboard', 'transcribeAudio', 'history', 'dictionary', 'statistics', 'aiModels', 'settings')) {
            Select-Page "sidebar.$route"
            Capture-Window $window "$appearance-$route"
        }
    }
    $saved = Get-Content (Join-Path $testRoot 'library.json') -Raw | ConvertFrom-Json
    if ($saved.Preferences.Theme -ne 'Dark') { throw 'Theme did not persist' }
    Select-Page 'sidebar.history'
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
    Capture-Window $editor 'Dark-editor'
    $editor.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Stop-Process -Id $process.Id
    $process.WaitForExit()
    $env:YAPPER_RECORDER_TEST = 'recording'
    $process = Start-Process -FilePath $AppPath -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $pill = $null
    while (!$pill -and [DateTime]::UtcNow -lt $deadline) {
        $pill = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Yapper Recorder'))
        if (!$pill) { Start-Sleep -Milliseconds 100 }
    }
    if (!$pill) { throw 'Floating recorder did not appear' }
    Capture-Window $pill 'Dark-recorder'
    $restored = Get-Content (Join-Path $testRoot 'library.json') -Raw | ConvertFrom-Json
    if ($restored.Preferences.Theme -ne 'Dark' -or $restored.Recordings.Count -ne 1) { throw 'Relaunch changed theme or library' }
    Write-Host 'PASS sidebar, light/dark themes, persistence, floating recorder, history and editor'
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id }
    Remove-Item Env:YAPPER_TEST_ROOT
    Remove-Item Env:YAPPER_RECORDER_TEST -ErrorAction SilentlyContinue
}
