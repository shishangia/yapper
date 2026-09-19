using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Yapper.Core;
using Forms = System.Windows.Forms;
using MessageBox = System.Windows.MessageBox;

namespace Yapper.Windows;

public partial class MainWindow : Window
{
    private readonly LibraryStore library;
    private readonly ModelStore models;
    private readonly SpeechService speech;
    private readonly AudioService audio = new();
    private readonly JobGate jobs = new();
    private readonly Forms.NotifyIcon tray;
    private WindowsInput? input;
    private CancellationTokenSource? cancellation;
    private Guid activeId;
    private string? recordingPath;
    private Recording? selected;
    private sealed record JobOptions(SpeechModel Model, string Language, bool Speakers, bool Single, bool Dictation,
        IntPtr Target, Preferences Preferences, DictionaryRule[] Dictionary);
    private JobOptions? options;
    private (string Path, JobOptions Options)? retry;
    private bool finishing;
    private bool initialized;
    private bool quitting;

    public MainWindow(string root)
    {
        library = new(root);
        models = new(root);
        speech = new(models);
        InitializeComponent();
        Width = Math.Min(Width, SystemParameters.WorkArea.Width - 32);
        Height = Math.Min(Height, SystemParameters.WorkArea.Height - 32);
        Left = SystemParameters.WorkArea.Left + (SystemParameters.WorkArea.Width - Width) / 2;
        Top = SystemParameters.WorkArea.Top + (SystemParameters.WorkArea.Height - Height) / 2;
        ModelChoice.ItemsSource = ModelStore.Catalog;
        ModelsList.ItemsSource = ModelStore.Catalog;
        ModelChoice.SelectedItem = ModelStore.Catalog.FirstOrDefault(m => m.Id == library.Data.Preferences.SelectedModel) ?? ModelStore.Catalog[1];
        ModelsList.SelectedItem = ModelChoice.SelectedItem;
        LanguageChoice.SelectedItem = LanguageChoice.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == library.Data.Preferences.Language) ?? LanguageChoice.Items[0];
        HotkeyChoice.SelectedItem = HotkeyChoice.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Content == library.Data.Preferences.Hotkey) ?? HotkeyChoice.Items[0];
        ToggleMode.IsChecked = library.Data.Preferences.ToggleRecording;
        RestoreClipboard.IsChecked = library.Data.Preferences.RestoreClipboard;
        TrimPeriod.IsChecked = library.Data.Preferences.TrimPeriod;
        AutoEdit.IsChecked = library.Data.Preferences.AutoEdit;
        MicrophoneChoice.ItemsSource = AudioService.Inputs;
        MicrophoneChoice.SelectedIndex = 0;
        using var iconStream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Yapper.ico")).Stream;
        tray = new Forms.NotifyIcon { Icon = new System.Drawing.Icon(iconStream), Text = "Yapper", Visible = true };
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowWindow);
        tray.ContextMenuStrip = new Forms.ContextMenuStrip();
        tray.ContextMenuStrip.Items.Add("Open Yapper", null, (_, _) => Dispatcher.Invoke(ShowWindow));
        tray.ContextMenuStrip.Items.Add("Quit", null, (_, _) => Dispatcher.Invoke(Quit));
        SourceInitialized += (_, _) =>
        {
            input = new(new WindowInteropHelper(this).Handle);
            input.Pressed += HotkeyPressed;
            input.Released += () => { if (!library.Data.Preferences.ToggleRecording && audio.IsRecording) _ = StopAndProcess(); };
            try { input.Register(library.Data.Preferences.Hotkey); } catch (Exception error) { Status.Text = error.Message; }
        };
        audio.RecordingFailed += error => Dispatcher.InvokeAsync(async () =>
        {
            if (!jobs.IsBusy || finishing) return;
            finishing = true;
            try { await audio.Stop(); } catch { }
            Status.Text = "Microphone recording stopped. " + error.Message;
            Finish();
        });
        initialized = true;
        RefreshLibrary();
        UpdateReady();
    }

    private SpeechModel Chosen => (SpeechModel)ModelChoice.SelectedItem;
    private string SpokenLanguage => (string)((ComboBoxItem)LanguageChoice.SelectedItem).Tag;
    private IProgress<(string Stage, double Value)> Reporter
    {
        get
        {
            var id = activeId;
            return new Progress<(string Stage, double Value)>(p =>
            {
                if (jobs.CanCommit(id)) { Status.Text = p.Stage; Progress.Value = p.Value; tray.Text = "Yapper · " + p.Stage[..Math.Min(p.Stage.Length, 40)]; }
            });
        }
    }
    private void ShowWindow() { Show(); WindowState = WindowState.Normal; Activate(); }
    private void UpdateReady() { if (!jobs.IsBusy) Status.Text = models.Ready(Chosen) ? $"Ready · {Chosen.Name} · {library.Data.Preferences.Hotkey}" : "Download your selected model in AI Models before recording."; }
    private void RefreshLibrary()
    {
        HistoryList.ItemsSource = library.Data.Recordings;
        RulesGrid.ItemsSource = library.Data.Dictionary;
        StatisticsText.Text = $"{library.Data.Usage.Count} transcriptions · {library.Data.Usage.Sum(x => x.Words)} words · {library.Data.Usage.Sum(x => x.Seconds) / 60:F1} recorded minutes\nModel files: {Directory.EnumerateFiles(models.Root, "*", SearchOption.AllDirectories).Sum(p => new FileInfo(p).Length) / 1_000_000_000d:F2} GB";
        if (selected is not null) { selected = library.Data.Recordings.FirstOrDefault(r => r.Id == selected.Id); ShowTranscript(); }
    }
    private void ShowTranscript() { TranscriptText.Text = selected?.DisplayText ?? ""; HistoryText.Text = selected?.DisplayText ?? ""; }
    private bool Begin()
    {
        if (jobs.IsBusy) { Status.Text = "Wait for the current job to finish, or cancel it."; return false; }
        activeId = jobs.Begin();
        audio.StopPlayback();
        cancellation = new();
        CancelButton.IsEnabled = true;
        Progress.Value = 0;
        RetryButton.IsEnabled = false;
        return true;
    }
    private void Finish()
    {
        jobs.Finish(activeId);
        cancellation?.Dispose(); cancellation = null;
        options = null; recordingPath = null; finishing = false;
        RetryButton.IsEnabled = retry is not null;
        CancelButton.IsEnabled = false;
        RecordButton.Content = "Record microphone";
        tray.Text = "Yapper";
        RefreshLibrary();
    }
    private void HotkeyPressed()
    {
        if (finishing) return;
        if (audio.IsRecording) { if (library.Data.Preferences.ToggleRecording) _ = StopAndProcess(); return; }
        StartRecording(true, WindowsInput.CaptureTarget());
    }
    private void RecordConversation(object sender, RoutedEventArgs e)
    {
        if (finishing) return;
        if (audio.IsRecording) _ = StopAndProcess(); else StartRecording(false, IntPtr.Zero);
    }
    private void StartRecording(bool dictation, IntPtr target)
    {
        if (!models.Ready(Chosen)) { Status.Text = "Download the selected model first."; ShowWindow(); return; }
        if (!Begin()) return;
        options = new(Chosen, SpokenLanguage, !dictation && DetectSpeakers.IsChecked == true, !dictation && SingleSpeaker.IsChecked == true,
            dictation, target, library.Data.Preferences, library.Data.Dictionary.ToArray());
        recordingPath = Path.Combine(library.Root, "Recordings", Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            audio.Start(recordingPath, MicrophoneChoice.SelectedIndex);
            Status.Text = "Recording microphone… Press the shortcut again or Stop when finished.";
            tray.Text = "Yapper · Recording";
            RecordButton.Content = "Stop and transcribe";
        }
        catch (Exception error) { Status.Text = error.Message; Finish(); }
    }
    private async Task StopAndProcess()
    {
        if (finishing || recordingPath is null || options is null) return;
        finishing = true;
        var path = recordingPath;
        var completed = false;
        recordingPath = null;
        Status.Text = "Finishing recording…";
        try
        {
            await audio.Stop();
            cancellation!.Token.ThrowIfCancellationRequested();
            await Process(path);
            completed = true;
        }
        catch (OperationCanceledException) { Status.Text = "Canceled. No transcript was saved."; }
        catch (Exception error) { Status.Text = "Could not transcribe. Audio retained locally. " + error.Message; }
        finally
        {
            if (File.Exists(path) && (completed || jobs.CancellationRequested)) File.Delete(path);
            Finish();
        }
    }
    private async void ImportAudio(object sender, RoutedEventArgs e)
    {
        if (jobs.IsBusy) return;
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "Audio|*.wav;*.mp3;*.m4a;*.wma;*.aiff|All files|*.*" };
        if (dialog.ShowDialog(this) != true || !Begin()) return;
        options = new(Chosen, SpokenLanguage, DetectSpeakers.IsChecked == true, SingleSpeaker.IsChecked == true, false, IntPtr.Zero,
            library.Data.Preferences, library.Data.Dictionary.ToArray());
        try { await Process(dialog.FileName); }
        catch (OperationCanceledException) { Status.Text = "Canceled. No transcript was saved."; }
        catch (Exception error) { Status.Text = "Could not transcribe. " + error.Message; }
        finally { Finish(); }
    }
    private async Task Process(string source)
    {
        var job = options!;
        var id = activeId;
        var token = cancellation!.Token;
        var destination = Path.Combine(library.Root, "Recordings", Guid.NewGuid().ToString("N") + ".wav");
        var saved = false;
        var decoded = false;
        try
        {
            Status.Text = "Preparing audio…";
            var samples = await Task.Run(() => AudioService.Decode(source, destination));
            decoded = true;
            token.ThrowIfCancellationRequested();
            var transcript = await speech.Transcribe(samples, job.Model, job.Language, job.Speakers, job.Single, Reporter, token);
            token.ThrowIfCancellationRequested();
            if (transcript.PlainText.Trim().Length == 0) throw new InvalidDataException("No speech was transcribed.");
            var text = job.Dictation ? DictationText.Process(transcript.PlainText, job.Dictionary,
                job.Preferences.TrimPeriod, job.Preferences.AutoEdit) : transcript.PlainText;
            selected = new(Guid.NewGuid(), DateTimeOffset.UtcNow, text, samples.Length / 16000d, destination, job.Model.Name, job.Dictation ? null : transcript);
            library.Add(selected);
            saved = true;
            retry = null;
            RefreshLibrary();
            ShowTranscript();
            Status.Text = transcript.Warning ?? "Transcript saved.";
            if (job.Dictation)
            {
                var outcome = await WindowsInput.Paste(text, job.Target, job.Preferences.RestoreClipboard, () => jobs.CanCommit(id));
                if (outcome is not null) { Status.Text = outcome; tray.ShowBalloonTip(6000, "Yapper", outcome, Forms.ToolTipIcon.Info); }
            }
        }
        catch (Exception) when (!token.IsCancellationRequested && decoded && !saved)
        {
            retry = (destination, job with { Dictation = false, Target = IntPtr.Zero });
            throw;
        }
        finally { if (!saved && retry?.Path != destination && File.Exists(destination)) File.Delete(destination); }
    }
    private async void RetryTranscription(object sender, RoutedEventArgs e)
    {
        if (retry is not { } retained || !Begin()) return;
        options = retained.Options;
        try { await Process(retained.Path); }
        catch (OperationCanceledException) { Status.Text = "Canceled. No transcript was saved."; }
        catch (Exception error) { Status.Text = "Retry failed. " + error.Message; }
        finally { Finish(); }
    }
    private async void DownloadModels(object sender, RoutedEventArgs e)
    {
        if (!Begin()) return;
        var model = Chosen;
        try { await models.Download(model, true, Reporter, cancellation!.Token); Status.Text = "Models are ready for offline use."; }
        catch (OperationCanceledException) { Status.Text = "Download canceled. You can retry."; }
        catch (Exception error) { Status.Text = "Download failed. " + error.Message; }
        finally { Finish(); }
    }
    private void CancelJob(object sender, RoutedEventArgs e)
    {
        jobs.Cancel(); cancellation?.Cancel();
        Status.Text = "Canceling. Waiting for active native work to finish…";
        if (audio.IsRecording) _ = StopAndProcess();
    }
    private void SelectModel(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || ModelChoice.SelectedItem is not SpeechModel model) return;
        library.Save(library.Data with { Preferences = library.Data.Preferences with { SelectedModel = model.Id } });
        ModelsList.SelectedItem = model;
        UpdateReady();
    }
    private void ChooseCatalogModel(object sender, SelectionChangedEventArgs e) { if (initialized && ModelsList.SelectedItem is SpeechModel model) ModelChoice.SelectedItem = model; }
    private void SelectRecording(object sender, SelectionChangedEventArgs e) { if (HistoryList.SelectedItem is Recording item) { selected = item; ShowTranscript(); } }
    private void CopyTranscript(object sender, RoutedEventArgs e) { if (selected is not null) { System.Windows.Clipboard.SetText(selected.DisplayText); Status.Text = "Copied."; } }
    private void PlayAudio(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        try { audio.TogglePlayback(selected.AudioPath); Status.Text = audio.IsPlaying ? "Playing recording" : "Playback paused"; }
        catch (Exception error) { Status.Text = "Recording unavailable. " + error.Message; audio.StopPlayback(); }
    }
    private void ReviewTurns(object sender, RoutedEventArgs e)
    {
        if (selected?.Conversation is null) { Status.Text = "Select a conversation recording to edit its turns."; return; }
        new TranscriptEditor(library, selected.Id) { Owner = this }.ShowDialog();
        RefreshLibrary();
    }
    private void DeleteRecording(object sender, RoutedEventArgs e)
    {
        if (selected is null || MessageBox.Show(this, "Remove this history entry? Its audio and usage statistics will be retained.", "Yapper", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        library.Delete(selected.Id); selected = null; ShowTranscript(); RefreshLibrary();
    }
    private void DeleteModel(object sender, RoutedEventArgs e)
    {
        if (jobs.IsBusy) { Status.Text = "Wait for processing to finish before deleting models."; return; }
        if (MessageBox.Show(this, "Delete " + Chosen.Name + "? Your recordings are not affected.", "Yapper", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        var path = models.DirectoryFor(Chosen.Id);
        if (Directory.Exists(path)) Directory.Delete(path, true);
        RefreshLibrary(); UpdateReady();
    }
    private void AddRule(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(TriggerText.Text)) return;
        library.Save(library.Data with { Dictionary = [.. library.Data.Dictionary, new(TriggerText.Text.Trim(), ReplacementText.Text)] });
        TriggerText.Clear(); ReplacementText.Clear(); RefreshLibrary();
    }
    private void RemoveRule(object sender, RoutedEventArgs e)
    {
        if (RulesGrid.SelectedItem is DictionaryRule rule) { library.Save(library.Data with { Dictionary = library.Data.Dictionary.Where(r => r != rule).ToList() }); RefreshLibrary(); }
    }
    private void SaveSettings(object sender, RoutedEventArgs e)
    {
        var shortcut = (string)((ComboBoxItem)HotkeyChoice.SelectedItem).Content;
        try
        {
            input?.Register(shortcut);
            library.Save(library.Data with { Preferences = new(Chosen.Id, SpokenLanguage, ToggleMode.IsChecked == true, RestoreClipboard.IsChecked == true, TrimPeriod.IsChecked == true, shortcut, AutoEdit.IsChecked == true) });
            Status.Text = "Settings saved.";
        }
        catch (Exception error) { Status.Text = error.Message; }
    }
    private void OpenPrivacy(object sender, RoutedEventArgs e) => System.Diagnostics.Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
    private void OpenData(object sender, RoutedEventArgs e) => System.Diagnostics.Process.Start(new ProcessStartInfo(library.Root) { UseShellExecute = true });
    private void OnClosing(object? sender, CancelEventArgs e) { if (!quitting) { e.Cancel = true; Hide(); } }
    private void Quit()
    {
        if (jobs.IsBusy) { ShowWindow(); Status.Text = "Cancel or finish the current recording before quitting."; return; }
        quitting = true; var icon = tray.Icon; tray.Dispose(); icon?.Dispose(); input?.Dispose(); audio.Dispose(); Close(); System.Windows.Application.Current.Shutdown();
    }
}
