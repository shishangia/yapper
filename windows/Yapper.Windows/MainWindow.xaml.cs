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
    private readonly RecorderWindow recorder;
    private WindowsInput? input;
    private CancellationTokenSource? cancellation;
    private Guid activeId;
    private string? recordingPath;
    private Recording? selected;
    private sealed record JobOptions(SpeechModel Model, string Language, bool Speakers, bool Single, bool Dictation,
        bool IncludeTimestamps, IntPtr Target, Preferences Preferences, DictionaryRule[] Dictionary);
    private JobOptions? options;
    private (string Path, JobOptions Options)? retry;
    private bool finishing;
    private bool initialized;
    private bool quitting;
    private readonly AppUpdates updates = new();
    private WindowsUpdate? availableUpdate;
    private bool updateBusy;
    private long modelStorageBytes;

    public MainWindow(string root)
    {
        library = new(root);
        models = new(root);
        speech = new(models);
        AppTheme.Apply(library.Data.Preferences.Theme);
        InitializeComponent();
        recorder = new RecorderWindow();
        recorder.StopRequested += () => _ = StopAndProcess();
        recorder.CancelRequested += () => CancelJob(this, new RoutedEventArgs());
        audio.LevelChanged += level => Dispatcher.InvokeAsync(() => recorder.UpdateLevel(level));
        ThemeChoice.SelectedItem = ThemeChoice.Items.Cast<ComboBoxItem>().First(i => (string)i.Content == AppTheme.Preference);
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemAppearanceChanged;
        Width = Math.Min(Width, SystemParameters.WorkArea.Width - 32);
        Height = Math.Min(Height, SystemParameters.WorkArea.Height - 32);
        Left = SystemParameters.WorkArea.Left + (SystemParameters.WorkArea.Width - Width) / 2;
        Top = SystemParameters.WorkArea.Top + (SystemParameters.WorkArea.Height - Height) / 2;
        ModelChoice.ItemsSource = ModelStore.Catalog;
        ModelsList.ItemsSource = ModelStore.Catalog;
        ModelChoice.SelectedItem = ModelStore.Catalog.FirstOrDefault(m => m.Id == library.Data.Preferences.SelectedModel) ?? ModelStore.Catalog[1];
        ModelsList.SelectedItem = ModelChoice.SelectedItem;
        LanguageChoice.SelectedItem = LanguageChoice.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == library.Data.Preferences.Language) ?? LanguageChoice.Items[0];
        SyncDisplayedModel();
        HotkeyChoice.SelectedItem = HotkeyChoice.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Content == library.Data.Preferences.Hotkey) ?? HotkeyChoice.Items[0];
        ToggleMode.IsChecked = library.Data.Preferences.ToggleRecording;
        RestoreClipboard.IsChecked = library.Data.Preferences.RestoreClipboard;
        TrimPeriod.IsChecked = library.Data.Preferences.TrimPeriod;
        AutoEdit.IsChecked = library.Data.Preferences.AutoEdit;
        IncludeTimestamps.IsChecked = library.Data.Preferences.IncludeTimestamps;
        AutoCheckUpdates.IsChecked = library.Data.Preferences.AutoCheckUpdates;
        Loaded += async (_, _) =>
        {
            if (Environment.GetEnvironmentVariable("YAPPER_TEST_ROOT") is null && library.Data.Preferences.AutoCheckUpdates
                && DateTimeOffset.UtcNow - (library.Data.Preferences.LastUpdateCheck ?? DateTimeOffset.MinValue) >= TimeSpan.FromDays(1))
                await CheckUpdatesAsync();
        };
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
            AppTheme.ApplyTitleBar(this);
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
        _ = RefreshModelStorage();
        UpdateReady();
    }

    private SpeechModel Chosen => SpokenLanguage == "hinglish"
        ? ModelStore.Catalog.Single(m => m.Id == "whisper-hinglish")
        : (SpeechModel)ModelChoice.SelectedItem;
    private string SpokenLanguage => (string)((ComboBoxItem)LanguageChoice.SelectedItem).Tag;
    private void SyncDisplayedModel()
    {
        var hinglish = SpokenLanguage == "hinglish";
        var model = hinglish
            ? ModelStore.Catalog.Single(m => m.Id == "whisper-hinglish")
            : ModelStore.Catalog.FirstOrDefault(m => m.Id == library.Data.Preferences.SelectedModel) ?? ModelStore.Catalog[1];
        var wasInitialized = initialized;
        initialized = false;
        ModelChoice.SelectedItem = model;
        ModelsList.SelectedItem = model;
        ModelChoice.IsEnabled = !hinglish;
        initialized = wasInitialized;
    }
    private IProgress<(string Stage, double Value)> Reporter
    {
        get
        {
            var id = activeId;
            return new Progress<(string Stage, double Value)>(p =>
            {
                if (jobs.CanCommit(id)) { Status.Text = p.Stage; recorder.SetStatus(p.Stage); Progress.Value = p.Value; tray.Text = "Yapper · " + p.Stage[..Math.Min(p.Stage.Length, 40)]; }
            });
        }
    }
    private void ShowWindow() { Show(); WindowState = WindowState.Normal; Activate(); }
    private void ViewHistory(object sender, RoutedEventArgs e) => Tabs.SelectedIndex = 2;
    private void SelectRecent(object sender, SelectionChangedEventArgs e)
    {
        if (RecentList.SelectedItem is Recording item) { selected = item; ShowTranscript(); }
    }
    private void ChangeTheme(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || ThemeChoice.SelectedItem is not ComboBoxItem item) return;
        var preference = (string)item.Content;
        library.Save(library.Data with { Preferences = library.Data.Preferences with { Theme = preference } });
        AppTheme.Apply(preference);
    }
    private void SystemAppearanceChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs e)
        => Dispatcher.InvokeAsync(() => AppTheme.Apply(library.Data.Preferences.Theme));
    private void UpdateReady() { if (!jobs.IsBusy) Status.Text = models.Ready(Chosen) ? $"Ready · {Chosen.Name} · {library.Data.Preferences.Hotkey}" : "Download your selected model in AI Models before recording."; }
    private void RefreshLibrary()
    {
        HistoryList.ItemsSource = library.Data.Recordings;
        RecentList.ItemsSource = library.Data.Recordings.Take(5).ToArray();
        RecentEmpty.Visibility = library.Data.Recordings.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        RulesGrid.ItemsSource = library.Data.Dictionary;
        var words = library.Data.Usage.Sum(x => x.Words);
        var today = DateTime.Today;
        Greeting.Text = DateTime.Now.Hour < 12 ? "Good morning," : DateTime.Now.Hour < 18 ? "Good afternoon," : "Welcome back,";
        DashboardWords.Text = StatsWords.Text = words.ToString("N0");
        StatsCount.Text = library.Data.Usage.Count.ToString("N0");
        StatsMinutes.Text = (library.Data.Usage.Sum(x => x.Seconds) / 60).ToString("N1");
        StatsSaved.Text = (words / 40).ToString("N0");
        DashboardSaved.Text = $"About {words / 40:N0} typing minutes saved · 40 words/min estimate";
        DashboardWeek.Text = library.Data.Usage.Count(x => x.Date.LocalDateTime >= today.AddDays(-6)).ToString("N0");
        DashboardToday.Text = $"{library.Data.Usage.Count(x => x.Date.LocalDateTime >= today)} today · {library.Data.Usage.Count} all time";
        StatisticsText.Text = $"{library.Data.Usage.Count} transcriptions · {library.Data.Usage.Sum(x => x.Words)} words · {library.Data.Usage.Sum(x => x.Seconds) / 60:F1} recorded minutes\nModel files: {modelStorageBytes / 1_000_000_000d:F2} GB";
        if (selected is not null) { selected = library.Data.Recordings.FirstOrDefault(r => r.Id == selected.Id); ShowTranscript(); }
    }
    private async Task RefreshModelStorage()
    {
        modelStorageBytes = await Task.Run(() => Directory.Exists(models.Root)
            ? Directory.EnumerateFiles(models.Root, "*", SearchOption.AllDirectories).Sum(path => new FileInfo(path).Length) : 0);
        RefreshLibrary();
    }
    private void ShowTranscript()
    {
        TranscriptText.Text = selected?.DisplayText ?? ""; HistoryText.Text = selected?.DisplayText ?? "";
        var detail = selected?.Timing is { } t
            ? $"Processing {t.Total:F2}s · decode {t.Decode:F2}s · wait {t.Queue:F2}s · model {t.ModelPreparation:F2}s · speech {t.Inference:F2}s · speakers {t.SpeakerDetection:F2}s · cleanup {t.Cleanup:F2}s"
            : "";
        ProcessingDetails.Text = HistoryProcessingDetails.Text = detail;
    }
    private void ChangePreferences(object sender, RoutedEventArgs e)
    {
        if (!initialized) return;
        library.Save(library.Data with { Preferences = library.Data.Preferences with {
            Language = SpokenLanguage, ToggleRecording = ToggleMode.IsChecked == true,
            RestoreClipboard = RestoreClipboard.IsChecked == true, TrimPeriod = TrimPeriod.IsChecked == true,
            AutoEdit = AutoEdit.IsChecked == true, AutoCheckUpdates = AutoCheckUpdates.IsChecked == true,
            IncludeTimestamps = IncludeTimestamps.IsChecked == true } });
        SyncDisplayedModel();
        UpdateReady();
    }
    private bool Begin()
    {
        if (jobs.IsBusy || updateBusy) { Status.Text = "Wait for the current job or update to finish."; return false; }
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
        recorder.Dismiss();
        tray.Text = "Yapper";
        RefreshLibrary();
    }
    private void HotkeyPressed()
    {
        if (finishing || updateBusy) return;
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
            dictation, IncludeTimestamps.IsChecked == true, target, library.Data.Preferences, library.Data.Dictionary.ToArray());
        recordingPath = Path.Combine(library.Root, "Recordings", Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            audio.Start(recordingPath, MicrophoneChoice.SelectedIndex);
            _ = WarmDuringRecording(options);
            recorder.Present(true);
            Status.Text = "Recording microphone… Press the shortcut again or Stop when finished.";
            tray.Text = "Yapper · Recording";
            RecordButton.Content = "Stop and transcribe";
        }
        catch (Exception error) { Status.Text = error.Message; Finish(); }
    }
    private async Task WarmDuringRecording(JobOptions job)
    {
        try { await speech.Warm(job.Model, job.Language, job.Speakers && !job.Single, CancellationToken.None); }
        catch (Exception error) { Debug.WriteLine("Model warm-up failed; transcription will retry: " + error.Message); }
    }
    private async Task StopAndProcess()
    {
        if (finishing || recordingPath is null || options is null) return;
        finishing = true;
        var path = recordingPath;
        var completed = false;
        recordingPath = null;
        Status.Text = "Finishing recording…";
        if (!jobs.CancellationRequested) recorder.Present(false, "Finishing recording…");
        try
        {
            await audio.Stop();
            cancellation!.Token.ThrowIfCancellationRequested();
            await Process(path, true);
            completed = true;
        }
        catch (OperationCanceledException) { Status.Text = "Canceled. No transcript was saved."; }
        catch (Exception error) { Status.Text = "Could not transcribe. Audio retained locally. " + error.Message; }
        finally
        {
            if (File.Exists(path) && (jobs.CancellationRequested || (completed && selected?.AudioPath != path))) File.Delete(path);
            Finish();
        }
    }
    private async void ImportAudio(object sender, RoutedEventArgs e)
    {
        if (jobs.IsBusy) return;
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "Audio|*.wav;*.mp3;*.m4a;*.wma;*.aiff|All files|*.*" };
        if (dialog.ShowDialog(this) != true || !Begin()) return;
        options = new(Chosen, SpokenLanguage, DetectSpeakers.IsChecked == true, SingleSpeaker.IsChecked == true, false,
            IncludeTimestamps.IsChecked == true, IntPtr.Zero,
            library.Data.Preferences, library.Data.Dictionary.ToArray());
        try { await Process(dialog.FileName, false); }
        catch (OperationCanceledException) { Status.Text = "Canceled. No transcript was saved."; }
        catch (Exception error) { Status.Text = "Could not transcribe. " + error.Message; }
        finally { Finish(); }
    }
    private async Task Process(string source, bool retained)
    {
        var job = options!;
        var id = activeId;
        var token = cancellation!.Token;
        // Imports always copy, even from the Recordings folder: the source may be another history item's audio.
        var recordings = Path.GetFullPath(Path.Combine(library.Root, "Recordings")) + Path.DirectorySeparatorChar;
        var sourcePath = Path.GetFullPath(source);
        var sourceIsRetainedRecording = retained && sourcePath.StartsWith(recordings, StringComparison.OrdinalIgnoreCase);
        var destination = sourceIsRetainedRecording
            ? sourcePath : Path.Combine(library.Root, "Recordings", Guid.NewGuid().ToString("N") + ".wav");
        var saved = false;
        var decoded = false;
        try
        {
            Status.Text = "Preparing audio…";
            var decodeClock = Stopwatch.StartNew();
            var samples = await Task.Run(() => AudioDecoder.Decode(source, destination));
            var decodeSeconds = decodeClock.Elapsed.TotalSeconds;
            decoded = true;
            token.ThrowIfCancellationRequested();
            var speechResult = await speech.Transcribe(samples, job.Model, job.Language, job.Speakers, job.Single, Reporter, token);
            var transcript = speechResult.Transcript with { TimestampsVisible = job.IncludeTimestamps };
            token.ThrowIfCancellationRequested();
            if (transcript.PlainText.Trim().Length == 0) throw new InvalidDataException("No speech was transcribed.");
            var cleanupClock = Stopwatch.StartNew();
            var text = job.Dictation ? DictationText.Process(transcript.PlainText, job.Dictionary,
                job.Preferences.TrimPeriod, job.Preferences.AutoEdit) : transcript.PlainText;
            var cleanupSeconds = cleanupClock.Elapsed.TotalSeconds;
            var timing = new ProcessingTiming(decodeSeconds, speechResult.QueueSeconds, speechResult.ModelPreparationSeconds,
                speechResult.InferenceSeconds, speechResult.SpeakerDetectionSeconds, cleanupSeconds);
            selected = new(Guid.NewGuid(), DateTimeOffset.UtcNow, text, samples.Length / 16000d, destination, job.Model.Name,
                job.Dictation ? null : transcript, timing);
            library.Add(selected);
            saved = true;
            retry = null;
            RefreshLibrary();
            ShowTranscript();
            Status.Text = transcript.Warning ?? $"Transcript saved in {timing.Total:F1}s.";
            if (job.Dictation)
            {
                var outcome = await WindowsInput.Paste(text, job.Target, job.Preferences.RestoreClipboard, () => jobs.CanCommit(id));
                if (outcome is not null) { Status.Text = outcome; tray.ShowBalloonTip(6000, "Yapper", outcome, Forms.ToolTipIcon.Info); }
            }
        }
        catch (Exception) when (!token.IsCancellationRequested && !saved && (decoded || sourceIsRetainedRecording))
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
        try { await Process(retained.Path, true); }
        catch (OperationCanceledException) { Status.Text = "Canceled. No transcript was saved."; }
        catch (Exception error) { Status.Text = "Retry failed. " + error.Message; }
        finally { Finish(); }
    }
    private async void DownloadModels(object sender, RoutedEventArgs e)
    {
        if (!Begin()) return;
        var model = Chosen;
        var reporter = Reporter;
        var token = cancellation!.Token;
        try {
            await Task.Run(() => models.Download(model, true, reporter, token));
            Status.Text = "Models are ready for offline use.";
            _ = RefreshModelStorage();
        }
        catch (OperationCanceledException) { Status.Text = "Download canceled. You can retry."; }
        catch (Exception error) { Status.Text = "Download failed. " + error.Message; }
        finally { Finish(); }
    }
    private void CancelJob(object sender, RoutedEventArgs e)
    {
        jobs.Cancel(); cancellation?.Cancel();
        Status.Text = "Canceling. Waiting for active native work to finish…";
        recorder.Dismiss();
        if (audio.IsRecording) _ = StopAndProcess();
    }
    private void SelectModel(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || ModelChoice.SelectedItem is not SpeechModel model) return;
        if (model.Id == "whisper-hinglish")
        {
            LanguageChoice.SelectedItem = LanguageChoice.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "hinglish");
            return;
        }
        library.Save(library.Data with { Preferences = library.Data.Preferences with { SelectedModel = model.Id } });
        ModelsList.SelectedItem = model;
        UpdateReady();
    }
    private void ChooseCatalogModel(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || ModelsList.SelectedItem is not SpeechModel model) return;
        if (model.Id == "whisper-hinglish")
        {
            LanguageChoice.SelectedItem = LanguageChoice.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "hinglish");
            return;
        }
        if (SpokenLanguage == "hinglish")
            LanguageChoice.SelectedItem = LanguageChoice.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "auto");
        ModelChoice.SelectedItem = model;
    }
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
    private async void DeleteModel(object sender, RoutedEventArgs e)
    {
        if (jobs.IsBusy || updateBusy) { Status.Text = "Wait for processing or updating to finish before deleting models."; return; }
        var model = ModelsList.SelectedItem as SpeechModel ?? Chosen;
        if (MessageBox.Show(this, "Delete " + model.Name + "? Your recordings are not affected.", "Yapper", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        await speech.Unload(model.Id);
        var path = models.DirectoryFor(model.Id);
        if (Directory.Exists(path)) Directory.Delete(path, true);
        if (model.Id == "whisper-hinglish" && SpokenLanguage == "hinglish")
            LanguageChoice.SelectedItem = LanguageChoice.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "auto");
        _ = RefreshModelStorage(); UpdateReady();
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
    private void ChangeHotkey(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || HotkeyChoice.SelectedItem is not ComboBoxItem item) return;
        var shortcut = (string)((ComboBoxItem)HotkeyChoice.SelectedItem).Content;
        try
        {
            input?.Register(shortcut);
            library.Save(library.Data with { Preferences = library.Data.Preferences with { Hotkey = shortcut } });
            UpdateReady();
        }
        catch (Exception error)
        {
            initialized = false;
            HotkeyChoice.SelectedItem = HotkeyChoice.Items.Cast<ComboBoxItem>()
                .First(i => (string)i.Content == library.Data.Preferences.Hotkey);
            initialized = true; Status.Text = error.Message;
        }
    }
    private async void CheckUpdates(object sender, RoutedEventArgs e) => await CheckUpdatesAsync();
    private async Task CheckUpdatesAsync()
    {
        if (updateBusy || !CheckUpdatesButton.IsEnabled) return;
        CheckUpdatesButton.IsEnabled = false;
        UpdateStatus.Text = "Checking GitHub…";
        try
        {
            availableUpdate = await updates.Check(CancellationToken.None);
            library.Save(library.Data with { Preferences = library.Data.Preferences with { LastUpdateCheck = DateTimeOffset.UtcNow } });
            UpdateStatus.Text = availableUpdate is null ? "You're up to date." : $"Yapper {availableUpdate.Version} is available.";
            InstallUpdateButton.IsEnabled = availableUpdate is not null;
            if (availableUpdate is not null && !jobs.IsBusy)
                tray.ShowBalloonTip(6000, "Yapper update available", $"Version {availableUpdate.Version} is ready. Open Settings to download and install.", Forms.ToolTipIcon.Info);
        }
        catch (Exception error) { UpdateStatus.Text = "Could not check for updates. " + error.Message; }
        finally { CheckUpdatesButton.IsEnabled = true; }
    }
    private async void InstallUpdate(object sender, RoutedEventArgs e)
    {
        if (availableUpdate is null || updateBusy) return;
        if (jobs.IsBusy) { UpdateStatus.Text = "Finish recording or transcription before installing."; return; }
        var update = availableUpdate;
        if (MessageBox.Show(this, $"Download Yapper {update.Version} from GitHub and close Yapper to run its installer?\n\nWindows installers are currently unsigned. Windows security prompts stay enabled. Your library will remain in place.", "Update Yapper", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        if (jobs.IsBusy) { UpdateStatus.Text = "A recording started. Finish it before installing."; return; }
        updateBusy = true;
        InstallUpdateButton.IsEnabled = CheckUpdatesButton.IsEnabled = false;
        try
        {
            var path = await updates.Download(update, Path.Combine(library.Root, "Updates"), new Progress<double>(p => UpdateStatus.Text = $"Downloading update… {p:P0}"), CancellationToken.None);
            var start = new ProcessStartInfo(path) { UseShellExecute = true };
            start.ArgumentList.Add("/DIR=" + AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
            if (System.Diagnostics.Process.Start(start) is null) throw new IOException("Windows did not start the installer.");
            updateBusy = false;
            Quit();
        }
        catch (Exception error) { UpdateStatus.Text = "Update not installed. " + error.Message; }
        finally { updateBusy = false; CheckUpdatesButton.IsEnabled = true; InstallUpdateButton.IsEnabled = availableUpdate is not null; }
    }
    private void OpenPrivacy(object sender, RoutedEventArgs e) => System.Diagnostics.Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
    private void OpenData(object sender, RoutedEventArgs e) => System.Diagnostics.Process.Start(new ProcessStartInfo(library.Root) { UseShellExecute = true });
    private void OnClosing(object? sender, CancelEventArgs e) { if (!quitting) { e.Cancel = true; Hide(); } }
    private void Quit()
    {
        if (jobs.IsBusy || updateBusy) { ShowWindow(); Status.Text = "Finish the current recording or update before quitting."; return; }
        Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemAppearanceChanged;
        quitting = true; var icon = tray.Icon; tray.Dispose(); icon?.Dispose(); input?.Dispose(); audio.Dispose(); speech.Dispose(); recorder.Close(); Close(); System.Windows.Application.Current.Shutdown();
    }
}
