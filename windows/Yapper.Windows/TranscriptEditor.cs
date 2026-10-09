using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using Yapper.Core;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using ComboBox = System.Windows.Controls.ComboBox;

namespace Yapper.Windows;

public sealed class TranscriptEditor : Window
{
    private readonly LibraryStore library;
    private readonly Guid recordingId;
    private readonly ListBox passages = new() { DisplayMemberPath = "Text", MinWidth = 230 };
    private readonly TextBox text = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MinHeight = 120 };
    private readonly ComboBox speakers = new();
    private readonly TextBox name = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private TranscriptSegment? loadedPassage;
    private string nameSpeaker = "", loadedName = "";
    private bool refreshing;
    private string SelectedSpeaker => speakers.SelectedValue as string ?? "";
    private bool HasPassageEdits => loadedPassage is not null
        && (text.Text != loadedPassage.Text || SelectedSpeaker != (loadedPassage.SpeakerId ?? ""));
    private bool HasNameEdit => name.Text != loadedName;
    private Transcript Current => library.Data.Recordings.Single(r => r.Id == recordingId).Conversation!;
    public TranscriptEditor(LibraryStore library, Guid id)
    {
        this.library = library; recordingId = id;
        AutomationProperties.SetAutomationId(passages, "transcriptPassages");
        AutomationProperties.SetAutomationId(text, "passageText");
        AutomationProperties.SetAutomationId(name, "speakerName");
        AutomationProperties.SetAutomationId(status, "editorStatus");
        AutomationProperties.SetAutomationId(speakers, "speakerAssignment");
        AutomationProperties.SetName(passages, "Transcript passages");
        AutomationProperties.SetName(text, "Passage text");
        AutomationProperties.SetName(speakers, "Speaker assignment");
        AutomationProperties.SetName(name, "Speaker name for this recording");
        speakers.SelectedValuePath = "Key";
        var speakerTemplate = new DataTemplate();
        var speakerText = new FrameworkElementFactory(typeof(TextBlock));
        speakerText.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding("Value"));
        speakerTemplate.VisualTree = speakerText;
        speakers.ItemTemplate = speakerTemplate;
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Save, (_, e) =>
        { SaveEdits(); e.Handled = true; }, (_, e) =>
        { e.CanExecute = HasPassageEdits || HasNameEdit; e.Handled = true; }));
        InputBindings.Add(new KeyBinding(ApplicationCommands.Save, new KeyGesture(Key.S, ModifierKeys.Control)));
        Closing += (_, e) => { if (!ResolveEdits()) e.Cancel = true; };
        SetResourceReference(StyleProperty, typeof(Window));
        Title = "Yapper · Review transcript"; Width = 860; Height = 660; MinWidth = 720; MinHeight = 500;
        Width = Math.Min(Width, SystemParameters.WorkArea.Width - 32);
        Height = Math.Min(Height, SystemParameters.WorkArea.Height - 32);
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SourceInitialized += (_, _) => AppTheme.ApplyTitleBar(this);
        var root = new DockPanel { Margin = new Thickness(24) };
        var heading = new TextBlock { Text = "Review transcript", Style = (Style)FindResource("PageTitle") };
        DockPanel.SetDock(heading, Dock.Top);
        root.Children.Add(heading);
        var actions = new WrapPanel();
        AddButton(actions, "Confirm one speaker", () =>
        {
            if (!ResolveEdits()) return;
            if (System.Windows.MessageBox.Show(this, "Assign every passage to one speaker? This can be undone.", "Yapper", MessageBoxButton.YesNo) == MessageBoxResult.Yes) Change(t => t.ConfirmSingleSpeaker());
        });
        AddButton(actions, "Undo one speaker", () => { if (ResolveEdits()) Change(t => t.UndoSingleSpeaker()); });
        AddButton(actions, "Copy transcript", () => { if (ResolveEdits()) System.Windows.Clipboard.SetText(Current.FormattedText()); });
        var timestamps = new CheckBox { Content = "Show timestamps", IsChecked = Current.ShowsTimestamps, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(timestamps, "showTranscriptTimestamps");
        timestamps.Checked += (_, _) => Change(t => t.WithTimestamps(true));
        timestamps.Unchecked += (_, _) => Change(t => t.WithTimestamps(false));
        actions.Children.Add(timestamps);
        DockPanel.SetDock(actions, Dock.Top); root.Children.Add(actions);
        DockPanel.SetDock(status, Dock.Bottom); root.Children.Add(status);
        var grid = new Grid(); grid.ColumnDefinitions.Add(new() { Width = new GridLength(260) }); grid.ColumnDefinitions.Add(new());
        grid.Children.Add(passages);
        var editor = new StackPanel { Margin = new Thickness(18, 0, 0, 0) };
        var editorScroll = new ScrollViewer { Content = editor, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(editorScroll, 1); grid.Children.Add(editorScroll);
        editor.Children.Add(new TextBlock { Text = "Passage text", FontWeight = FontWeights.Bold }); editor.Children.Add(text);
        editor.Children.Add(new TextBlock { Text = "Speaker assignment" }); editor.Children.Add(speakers);
        var save = new WrapPanel();
        var saveButton = new Button { Content = "Save changes", Command = ApplicationCommands.Save, ToolTip = "Save passage and speaker name (Ctrl+S)" };
        AutomationProperties.SetAcceleratorKey(saveButton, "Ctrl+S");
        save.Children.Add(saveButton); editor.Children.Add(save);
        editor.Children.Add(new TextBlock { Text = "Speaker name (recording-specific)" }); editor.Children.Add(name);
        var naming = new WrapPanel();
        AddButton(naming, "Rename selected speaker", () =>
        {
            if (SelectedSpeaker.Length > 0) Change(t => t.Rename(SelectedSpeaker, name.Text), preserveName: false);
        });
        AddButton(naming, "Add speaker", () => Change(t => t.AddSpeaker(name.Text), preserveName: false));
        AddButton(naming, "Merge into selected speaker", () =>
        {
            if (passages.SelectedItem is TranscriptSegment old && old.SpeakerId is not null && speakers.SelectedValue is string target && target.Length > 0)
            {
                if (ResolveEdits()) Change(t => t.Merge(old.SpeakerId, target));
            }
        }, "Move this passage's speaker into the selected speaker");
        editor.Children.Add(naming);
        editor.Children.Add(new TextBlock { Text = "Small uncertain passages stay in reading flow. Review assignments here; naming does not identify the same person in other recordings.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 14, 0, 0) });
        root.Children.Add(grid); Content = root;
        passages.SelectionChanged += (_, _) =>
        {
            if (refreshing || passages.SelectedItem is not TranscriptSegment next) return;
            if (ResolveEdits()) Reload(next.Id);
            else
            {
                refreshing = true;
                passages.SelectedItem = Current.Segments.FirstOrDefault(s => s.Id == loadedPassage?.Id);
                refreshing = false;
            }
        };
        speakers.SelectionChanged += (_, _) => SelectSpeaker();
        text.TextChanged += (_, _) => ShowDraftStatus();
        name.TextChanged += (_, _) => ShowDraftStatus();
        Reload();
    }
    private static void AddButton(Panel panel, string label, Action action, string? hint = null)
    {
        // Wrapping text keeps long labels readable in a narrow editor instead of clipping them.
        var button = new Button { Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center }, ToolTip = hint };
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) => action(); panel.Children.Add(button);
    }
    private void Reload(int? selectedId = null, bool preservePassage = false, bool preserveName = false)
    {
        var old = selectedId ?? loadedPassage?.Id;
        var draftText = text.Text; var draftSpeaker = SelectedSpeaker; var draftName = name.Text;
        var selectionStart = text.SelectionStart; var selectionLength = text.SelectionLength;
        refreshing = true;
        try
        {
            passages.ItemsSource = Current.Segments;
            speakers.ItemsSource = new[] { new KeyValuePair<string, string>("", "Needs review") }.Concat(Current.SpeakerIds.Select(id => new KeyValuePair<string, string>(id, Current.SpeakerName(id)))).ToArray();
            passages.SelectedItem = Current.Segments.FirstOrDefault(s => s.Id == old) ?? Current.Segments.FirstOrDefault();
            loadedPassage = passages.SelectedItem as TranscriptSegment;
            text.Text = preservePassage ? draftText : loadedPassage?.Text ?? "";
            speakers.SelectedValue = preservePassage ? draftSpeaker : loadedPassage?.SpeakerId ?? "";
            nameSpeaker = SelectedSpeaker;
            loadedName = Current.SpeakerNames.GetValueOrDefault(nameSpeaker, "");
            name.Text = preserveName ? draftName : loadedName;
            if (preservePassage) text.Select(Math.Min(selectionStart, text.Text.Length), Math.Min(selectionLength, Math.Max(0, text.Text.Length - selectionStart)));
            if (loadedPassage is not null) status.Text = $"{TimeSpan.FromSeconds(loadedPassage.Start):hh\\:mm\\:ss} to {TimeSpan.FromSeconds(loadedPassage.End):hh\\:mm\\:ss}";
        }
        finally { refreshing = false; }
    }
    private void SelectSpeaker()
    {
        if (refreshing) return;
        var target = SelectedSpeaker;
        if (HasNameEdit)
        {
            var answer = System.Windows.MessageBox.Show(this, "Save the edited speaker name before changing the assignment?", "Unsaved speaker name", MessageBoxButton.YesNoCancel);
            if (answer == MessageBoxResult.Cancel || answer == MessageBoxResult.Yes && !SaveName())
            {
                refreshing = true; speakers.SelectedValue = nameSpeaker; refreshing = false;
                return;
            }
        }
        refreshing = true;
        nameSpeaker = target; loadedName = Current.SpeakerNames.GetValueOrDefault(target, ""); name.Text = loadedName;
        refreshing = false;
        ShowDraftStatus();
    }
    private bool SaveName()
    {
        if (nameSpeaker.Length == 0) { status.Text = "Choose a speaker or use Add speaker to save this name."; return false; }
        return Change(t => t.Rename(nameSpeaker, name.Text), preserveName: false);
    }
    private bool SaveEdits()
    {
        if (HasNameEdit && nameSpeaker.Length == 0) { status.Text = "Choose a speaker or use Add speaker to save this name."; return false; }
        var editPassage = HasPassageEdits; var editName = HasNameEdit;
        var passage = loadedPassage; var speaker = SelectedSpeaker;
        // A hand correction to a passage (e.g. a mis-transcribed name) is worth remembering;
        // this only fires on an explicit save, never while typing.
        var learned = editPassage && passage is not null ? PreferredWordLearner.Learn(passage.Text, text.Text) : null;
        var saved = Change(t =>
        {
            if (editPassage && passage is not null) t = t.Edit(passage.Id, text.Text, speaker.Length == 0 ? null : speaker);
            return editName ? t.Rename(nameSpeaker, name.Text) : t;
        }, preservePassage: false, preserveName: false);
        if (saved && learned is not null && LearnWord(learned)) status.Text = "Learned " + learned;
        return saved;
    }
    private bool LearnWord(string word)
    {
        var updated = string.Join('\n', PreferredVocabulary.Parse(library.Data.Preferences.PreferredWords + "\n" + word));
        if (updated == library.Data.Preferences.PreferredWords) return false;
        library.Save(library.Data with { Preferences = library.Data.Preferences with { PreferredWords = updated } });
        return true;
    }
    private bool ResolveEdits()
    {
        if (!HasPassageEdits && !HasNameEdit) return true;
        var answer = System.Windows.MessageBox.Show(this, "Save your passage and speaker-name changes? Choose No to discard them, or Cancel to keep editing.", "Unsaved transcript changes", MessageBoxButton.YesNoCancel);
        if (answer == MessageBoxResult.Yes) return SaveEdits();
        if (answer == MessageBoxResult.No) { Reload(); return true; }
        return false;
    }
    private void ShowDraftStatus()
    {
        if (refreshing) return;
        status.Text = HasPassageEdits || HasNameEdit ? "Unsaved changes. Press Ctrl+S to save." : "No unsaved changes.";
        CommandManager.InvalidateRequerySuggested();
    }
    private bool Change(Func<Transcript, Transcript> change, bool preservePassage = true, bool preserveName = true)
    {
        var keepPassage = preservePassage && HasPassageEdits;
        var keepName = preserveName && HasNameEdit;
        try
        {
            library.UpdateConversation(recordingId, change);
            Reload(preservePassage: keepPassage, preserveName: keepName);
            status.Text = HasPassageEdits || HasNameEdit ? "Change saved. Your draft is still unsaved. Press Ctrl+S to save." : "Saved. Usage statistics unchanged.";
            CommandManager.InvalidateRequerySuggested();
            return true;
        }
        catch (Exception error) { status.Text = error.Message; return false; }
    }
}
