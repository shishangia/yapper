using System.Windows;
using System.Windows.Controls;
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
    private readonly TextBox text = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MinHeight = 160 };
    private readonly ComboBox speakers = new();
    private readonly TextBox name = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private Transcript Current => library.Data.Recordings.Single(r => r.Id == recordingId).Conversation!;
    public TranscriptEditor(LibraryStore library, Guid id)
    {
        this.library = library; recordingId = id;
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
            if (System.Windows.MessageBox.Show(this, "Assign every passage to one speaker? This can be undone.", "Yapper", MessageBoxButton.YesNo) == MessageBoxResult.Yes) Change(t => t.ConfirmSingleSpeaker());
        });
        AddButton(actions, "Undo one speaker", () => Change(t => t.UndoSingleSpeaker()));
        AddButton(actions, "Copy transcript", () => System.Windows.Clipboard.SetText(Current.FormattedText()));
        DockPanel.SetDock(actions, Dock.Top); root.Children.Add(actions);
        DockPanel.SetDock(status, Dock.Bottom); root.Children.Add(status);
        var grid = new Grid(); grid.ColumnDefinitions.Add(new() { Width = new GridLength(260) }); grid.ColumnDefinitions.Add(new());
        grid.Children.Add(passages);
        var editor = new StackPanel { Margin = new Thickness(18, 0, 0, 0) };
        var editorScroll = new ScrollViewer { Content = editor, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetColumn(editorScroll, 1); grid.Children.Add(editorScroll);
        editor.Children.Add(new TextBlock { Text = "Passage text", FontWeight = FontWeights.Bold }); editor.Children.Add(text);
        editor.Children.Add(new TextBlock { Text = "Speaker assignment" }); editor.Children.Add(speakers);
        var save = new WrapPanel(); AddButton(save, "Save passage", SavePassage); editor.Children.Add(save);
        editor.Children.Add(new TextBlock { Text = "Speaker name (recording-specific)" }); editor.Children.Add(name);
        var naming = new WrapPanel();
        AddButton(naming, "Rename selected speaker", () =>
        {
            if (speakers.SelectedValue is string speaker && speaker.Length > 0) Change(t => t.Rename(speaker, name.Text));
        });
        AddButton(naming, "Add speaker", () => Change(t => t.AddSpeaker(name.Text)));
        AddButton(naming, "Merge passage speaker into selected", () =>
        {
            if (passages.SelectedItem is TranscriptSegment old && old.SpeakerId is not null && speakers.SelectedValue is string target && target.Length > 0)
                Change(t => t.Merge(old.SpeakerId, target));
        });
        editor.Children.Add(naming);
        editor.Children.Add(new TextBlock { Text = "Small uncertain passages stay in reading flow. Review assignments here; naming does not identify the same person in other recordings.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 14, 0, 0) });
        root.Children.Add(grid); Content = root;
        passages.SelectionChanged += (_, _) => SelectPassage();
        speakers.SelectionChanged += (_, _) => { if (speakers.SelectedValue is string speaker) name.Text = Current.SpeakerNames.GetValueOrDefault(speaker, ""); };
        Reload();
    }
    private static void AddButton(Panel panel, string label, Action action)
    {
        var button = new Button { Content = label };
        button.Click += (_, _) => action(); panel.Children.Add(button);
    }
    private void Reload()
    {
        var old = (passages.SelectedItem as TranscriptSegment)?.Id;
        passages.ItemsSource = Current.Segments;
        speakers.ItemsSource = new[] { new KeyValuePair<string, string>("", "Needs review") }.Concat(Current.SpeakerIds.Select(id => new KeyValuePair<string, string>(id, Current.SpeakerName(id)))).ToArray();
        speakers.DisplayMemberPath = "Value"; speakers.SelectedValuePath = "Key";
        var speakerTemplate = new DataTemplate();
        var speakerText = new FrameworkElementFactory(typeof(TextBlock));
        speakerText.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding("Value"));
        speakerTemplate.VisualTree = speakerText;
        speakers.DisplayMemberPath = "";
        speakers.ItemTemplate = speakerTemplate;
        passages.SelectedItem = Current.Segments.FirstOrDefault(s => s.Id == old) ?? Current.Segments.FirstOrDefault();
        SelectPassage();
    }
    private void SelectPassage()
    {
        if (passages.SelectedItem is not TranscriptSegment segment) return;
        text.Text = segment.Text; speakers.SelectedValue = segment.SpeakerId ?? "";
        status.Text = $"{TimeSpan.FromSeconds(segment.Start):hh\\:mm\\:ss} to {TimeSpan.FromSeconds(segment.End):hh\\:mm\\:ss}";
    }
    private void SavePassage()
    {
        if (passages.SelectedItem is not TranscriptSegment segment) return;
        var speaker = speakers.SelectedValue as string;
        Change(t => t.Edit(segment.Id, text.Text, string.IsNullOrEmpty(speaker) ? null : speaker));
    }
    private void Change(Func<Transcript, Transcript> change)
    {
        try { library.UpdateConversation(recordingId, change); Reload(); status.Text = "Saved. Usage statistics unchanged."; }
        catch (Exception error) { status.Text = error.Message; }
    }
}
