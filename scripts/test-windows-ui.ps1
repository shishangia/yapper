param([Parameter(Mandatory=$true)][string]$AppPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EditorTestInput {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
}
'@
$env:YAPPER_TEST_ROOT = Join-Path $env:TEMP ("Yapper-UI-" + [guid]::NewGuid())
$testRoot = $env:YAPPER_TEST_ROOT
New-Item -ItemType Directory -Path $testRoot | Out-Null
$fixture = [ordered]@{
    Version = 1
    Recordings = @([ordered]@{Id='71a528e0-d4fd-4bfa-bdcd-d0c30c09e42c';Date='2026-01-01T12:00:00Z';Text='Hello there';Duration=2;AudioPath='missing-test-audio.wav';Model='Synthetic fixture';Timing=@{Decode=.1;Queue=.2;ModelPreparation=.3;Inference=.4;SpeakerDetection=.5;Cleanup=.01};Conversation=@{SpeakerDetectionRequested=$true;Segments=@(@{Id=0;Start=0;End=1;Text='Hello';SpeakerId='1'},@{Id=1;Start=1;End=2;Text=' there';SpeakerId='2'});SpeakerNames=@{'1'='Test Alice';'2'='Test Bob'}}})
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
    Select-Page 'sidebar.transcribeAudio'
    $timestamps = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'includeTimestamps'))
    if (!$timestamps) { throw 'Timestamp preference missing' }
    $toggle = $timestamps.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'New transcripts should default to paragraphs' }
    $toggle.Toggle()
    $saved = Get-Content (Join-Path $testRoot 'library.json') -Raw | ConvertFrom-Json
    if ($saved.Preferences.Theme -ne 'Dark') { throw 'Theme did not persist' }
    if ($saved.Preferences.Language -ne 'hinglish') { throw "New library did not default to Hinglish: $($saved.Preferences.Language)" }
    if ($saved.Preferences.SelectedModel -ne 'whisper-small') { throw 'Hinglish mode overwrote the saved general model' }
    if (!$saved.Preferences.AutoEdit) { throw 'New library did not enable local dictation cleanup' }
    Select-Page 'sidebar.history'
    $entry = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))
    if (!$entry) { throw 'Synthetic history entry did not load' }
    $entry.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $timing = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Processing 1.51s · decode 0.10s · wait 0.20s · model 0.30s · speech 0.40s · speakers 0.50s · cleanup 0.01s'))
    if (!$timing) { throw 'Processing timing details missing' }
    $review = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Review / edit turns'))
    $review.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $editor = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (!$editor -and [DateTime]::UtcNow -lt $deadline) {
        $editor = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Yapper · Review transcript'))
        if (!$editor) { Start-Sleep -Milliseconds 100 }
    }
    if (!$editor) { throw 'Transcript editor did not open' }
    $keys = New-Object -ComObject WScript.Shell
    function Editor-Control([string]$id) {
        $control = $editor.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
        if (!$control) { throw "Editor control missing: $id" }
        return $control
    }
    function Invoke-EditorAction([string]$label) {
        $button = $editor.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $label))
        if (!$button) { throw "Editor action missing: $label" }
        $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    function Assert-EditorSaved([string]$expected = 'Saved. Usage statistics unchanged.') {
        $editorStatus = Editor-Control 'editorStatus'
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ($editorStatus.Current.Name -ne $expected -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if ($editorStatus.Current.Name -ne $expected) {
            throw "Editor refresh failed: $($editorStatus.Current.Name)"
        }
    }
    function Select-Passage([int]$index) {
        $passages = Editor-Control 'transcriptPassages'
        $items = $passages.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))
        $items[$index].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    function Answer-UnsavedChanges([string]$answer) {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $dialogHandle = [IntPtr]::Zero
        while ($dialogHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) {
            $dialogHandle = [EditorTestInput]::FindWindow('#32770', 'Unsaved transcript changes')
            if ($dialogHandle -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
        }
        if ($dialogHandle -eq [IntPtr]::Zero) { throw 'Native unsaved changes prompt did not appear' }
        $owner = [uint32]0
        [void][EditorTestInput]::GetWindowThreadProcessId($dialogHandle, [ref]$owner)
        if ($owner -ne $process.Id) { throw 'Unsaved changes dialog belongs to a different process' }
        $buttonHandle = [EditorTestInput]::GetDlgItem($dialogHandle, @{ Cancel = 2; No = 7; Yes = 6 }[$answer])
        if ($buttonHandle -eq [IntPtr]::Zero) { throw "Native unsaved changes prompt has no $answer button" }
        [void][EditorTestInput]::SetForegroundWindow($dialogHandle)
        # BM_CLICK invokes the real native button without requiring UIAutomation patterns.
        if (![EditorTestInput]::PostMessage($buttonHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'Could not click the native dialog button' }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([EditorTestInput]::IsWindow($dialogHandle) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if ([EditorTestInput]::IsWindow($dialogHandle)) { throw "Native unsaved changes prompt did not accept $answer" }
        Write-Host "PASS native unsaved changes action: $answer"
    }
    function Leave-Draft {
        (Editor-Control 'transcriptPassages').SetFocus()
        $keys.SendKeys('{HOME}')
    }
    foreach ($field in @(@('passageText', 'Passage text'), @('speakerAssignment', 'Speaker assignment'), @('speakerName', 'Speaker name for this recording'))) {
        if ((Editor-Control $field[0]).Current.Name -ne $field[1]) { throw "Missing accessible name: $($field[0])" }
    }
    $editorTimestamps = $editor.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'showTranscriptTimestamps'))
    if (!$editorTimestamps) { throw 'Transcript timestamp switch missing' }
    $editorToggle = $editorTimestamps.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($editorToggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { throw 'Legacy transcript should keep timestamps' }
    foreach ($expected in @($false, $true, $false)) {
        $editorToggle.Toggle()
        Assert-EditorSaved
        $edited = Get-Content (Join-Path $testRoot 'library.json') -Raw | ConvertFrom-Json
        if ($edited.Recordings[0].Conversation.TimestampsVisible -ne $expected) { throw 'Timestamp toggle was not saved' }
    }
    Select-Passage 1
    $speakerName = (Editor-Control 'speakerName').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $passageText = (Editor-Control 'passageText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($speakerName.Current.Value -ne 'Test Bob') { throw 'Second passage speaker was not selected' }
    $passageText.SetValue('Draft before display changes')
    $speakerName.SetValue('Test Robert')
    foreach ($expected in @($true, $false)) {
        $editorToggle.Toggle()
        Assert-EditorSaved 'Change saved. Your draft is still unsaved. Press Ctrl+S to save.'
        if ($passageText.Current.Value -ne 'Draft before display changes' -or $speakerName.Current.Value -ne 'Test Robert') { throw 'Timestamp toggle lost a draft' }
    }
    Invoke-EditorAction 'Rename selected speaker'
    Assert-EditorSaved 'Change saved. Your draft is still unsaved. Press Ctrl+S to save.'
    if ($speakerName.Current.Value -ne 'Test Robert') { throw 'Speaker name or selected passage was lost during refresh' }
    if ($passageText.Current.Value -ne 'Draft before display changes') { throw 'Rename lost the passage draft' }
    $edited = Get-Content (Join-Path $testRoot 'library.json') -Raw | ConvertFrom-Json
    if ($edited.Recordings[0].Conversation.Segments[1].Text -ne ' there') { throw 'A display or naming change silently saved the draft' }
    Leave-Draft
    Answer-UnsavedChanges 'Cancel'
    if ($passageText.Current.Value -ne 'Draft before display changes') { throw 'Canceling navigation lost the draft' }
    $keys.SendKeys('%{F4}')
    Answer-UnsavedChanges 'Cancel'
    if ($passageText.Current.Value -ne 'Draft before display changes') { throw 'Canceling close lost the draft' }
    Leave-Draft
    Answer-UnsavedChanges 'No'
    Select-Passage 1
    if ($passageText.Current.Value -ne ' there') { throw 'Discard did not restore the saved passage' }
    $passageText.SetValue('Saved on navigation')
    Leave-Draft
    Answer-UnsavedChanges 'Yes'
    Select-Passage 1
    if ($passageText.Current.Value -ne 'Saved on navigation') { throw 'Save on navigation failed' }
    $passageText.SetValue('Updated reply')
    if (!$keys.AppActivate($process.Id)) { throw 'Could not focus the editor for Ctrl+S' }
    (Editor-Control 'passageText').SetFocus()
    $keys.SendKeys('^s')
    Assert-EditorSaved
    if ($passageText.Current.Value -ne 'Updated reply') { throw 'Passage text was lost during refresh' }
    Invoke-EditorAction 'Copy transcript'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $copied = (Get-Clipboard -Raw) -replace "`r`n", "`n"
        if ($copied -eq "Test Alice: Hello`n`nTest Robert: Updated reply") { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($copied -ne "Test Alice: Hello`n`nTest Robert: Updated reply") { throw "Copied transcript did not reflect the edits: $copied" }
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
    if ($restored.Preferences.Theme -ne 'Dark') { throw "Theme did not survive relaunch: $($restored.Preferences.Theme)" }
    if (!$restored.Preferences.IncludeTimestamps) { throw 'New-transcript timestamp preference did not survive relaunch' }
    if ($restored.Recordings.Count -ne 1) { throw "Library count changed on relaunch: $($restored.Recordings.Count)" }
    if ($restored.Recordings[0].Conversation.TimestampsVisible -ne $false) { throw "Recording timestamp view did not persist: $($restored.Recordings[0].Conversation.TimestampsVisible)" }
    if ($restored.Recordings[0].Conversation.SpeakerNames.'2' -ne 'Test Robert') { throw 'Speaker rename did not survive relaunch' }
    if ($restored.Recordings[0].Conversation.Segments[1].Text -ne 'Updated reply') { throw 'Passage edit did not survive relaunch' }
    if ($restored.Recordings[0].Conversation.Segments[1].SpeakerId -ne '2') { throw 'Passage edit changed the speaker assignment' }
    if ($restored.Recordings[0].Conversation.SpeakerNames.'1' -ne 'Test Alice') { throw 'Renaming changed another speaker' }
    if ($restored.Usage.Count -ne 0) { throw 'Editor changes added usage statistics' }
    Write-Host 'PASS editor draft preservation, save/discard/cancel, Ctrl+S, accessible names, copied output and relaunch persistence'
    Write-Host 'PASS sidebar, light/dark themes, persistence, floating recorder, history and editor'
} catch {
    Write-Host $_.ScriptStackTrace
    throw
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id }
    Remove-Item Env:YAPPER_TEST_ROOT
    Remove-Item Env:YAPPER_RECORDER_TEST -ErrorAction SilentlyContinue
}
