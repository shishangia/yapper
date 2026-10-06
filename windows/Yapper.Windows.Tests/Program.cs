using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Yapper.Windows;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        var app = new Application();
        var field = new TextBox { AcceptsReturn = true, MinHeight = 150 };
        var window = new Window { Title = "Yapper disposable paste test", Content = field, Width = 500, Height = 250 };
        var result = 1;
        window.Loaded += async (_, _) =>
        {
            var previous = Clipboard.GetDataObject();
            try
            {
                window.Activate(); field.Focus();
                Clipboard.SetText("original clipboard");
                var target = new WindowInteropHelper(window).Handle;
                var recorder = new RecorderWindow();
                recorder.Present(true);
                await Task.Delay(150);
                if (WindowsInput.CaptureTarget() != target) throw new Exception("Floating recorder stole input focus.");
                recorder.SetPreview(string.Concat(Enumerable.Repeat("An earlier sentence in the draft. ", 12)) + "The newest words must remain visible.");
                await Task.Delay(150);
                var draftScroll = Descendants(recorder).OfType<ScrollViewer>().Single(s => s.Content is TextBlock);
                if (draftScroll.ScrollableHeight <= 0 || draftScroll.VerticalOffset < draftScroll.ScrollableHeight - 1)
                    throw new Exception("Live preview did not keep the newest words visible.");
                if (WindowsInput.CaptureTarget() != target) throw new Exception("Live preview stole input focus.");
                recorder.Present(false);
                recorder.Dismiss();
                recorder.Close();
                var outcome = await WindowsInput.Paste("Yapper test phrase", target, true, () => true);
                if (outcome is not null) throw new Exception(outcome);
                if (field.Text != "Yapper test phrase") throw new Exception("Text was not inserted into the focused textbox.");
                if (Clipboard.GetText() != "original clipboard") throw new Exception("Clipboard was not restored.");
                await WindowsInput.Paste("must not paste", target, true, () => false);
                if (field.Text != "Yapper test phrase") throw new Exception("Canceled paste changed the textbox.");
                outcome = await WindowsInput.Paste("manual fallback", IntPtr.Zero, true, () => true);
                if (outcome is null || Clipboard.GetText() != "manual fallback") throw new Exception("Missing-target clipboard fallback failed.");
                Console.WriteLine("PASS actual Windows textbox insertion, clipboard restoration, cancellation, and missing-target fallback");
                result = 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); }
            finally
            {
                if (previous is null) Clipboard.Clear(); else Clipboard.SetDataObject(previous, true);
                window.Close(); app.Shutdown();
            }
        };
        app.Run(window);
        return result;
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (var index = 0; index < System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(parent, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
