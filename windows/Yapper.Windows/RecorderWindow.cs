using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Yapper.Windows;

public sealed class RecorderWindow : Window
{
    private readonly TextBlock label = new() { FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock elapsed = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 8, 0) };
    private readonly ProgressBar meter = new() { Minimum = 0, Maximum = 1, Width = 55, Height = 5, Margin = new Thickness(10, 0, 0, 0) };
    private readonly Button stop = new() { Content = "Stop", Padding = new Thickness(10, 4, 10, 4), MinHeight = 28 };
    private readonly Button cancel = new() { Content = "Cancel", Padding = new Thickness(10, 4, 10, 4), MinHeight = 28 };
    private readonly DispatcherTimer timer;
    private DateTime started;
    private bool recording;
    public event Action? StopRequested;
    public event Action? CancelRequested;

    public RecorderWindow()
    {
        Title = "Yapper Recorder"; Width = 510; Height = 66;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true;
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        label.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
        elapsed.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryInk");
        meter.SetResourceReference(ProgressBar.ForegroundProperty, "Accent");
        foreach (var child in new UIElement[] { label, meter, elapsed, stop, cancel }) row.Children.Add(child);
        var pill = new Border { CornerRadius = new CornerRadius(24), BorderThickness = new Thickness(1), Margin = new Thickness(5), Padding = new Thickness(16, 6, 16, 6), Child = row };
        pill.SetResourceReference(Border.BackgroundProperty, "Surface"); pill.SetResourceReference(Border.BorderBrushProperty, "Border");
        Content = pill;
        stop.Click += (_, _) => StopRequested?.Invoke();
        cancel.Click += (_, _) => CancelRequested?.Invoke();
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            SetWindowLongPtr(hwnd, -20, new IntPtr(GetWindowLongPtr(hwnd, -20).ToInt64() | 0x08000000 | 0x00000080));
        };
        timer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) =>
        {
            if (recording) elapsed.Text = (DateTime.UtcNow - started).ToString(@"mm\:ss");
        }, Dispatcher);
        timer.Stop();
    }
    public void Present(bool isRecording, string status = "Transcribing…")
    {
        recording = isRecording;
        if (isRecording) { started = DateTime.UtcNow; elapsed.Text = "00:00"; timer.Start(); }
        else { elapsed.Text = ""; timer.Stop(); }
        label.Text = isRecording ? "Recording" : status;
        stop.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
        meter.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
        Left = SystemParameters.WorkArea.Left + (SystemParameters.WorkArea.Width - Width) / 2;
        Top = SystemParameters.WorkArea.Bottom - Height - 12;
        Show();
    }
    public void UpdateLevel(float value) { if (recording) meter.Value = Math.Clamp(value, 0, 1); }
    public void SetStatus(string text) { if (!recording) label.Text = text.Length > 30 ? text[..27] + "…" : text; }
    public void Dismiss() { recording = false; timer.Stop(); Hide(); }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
}
