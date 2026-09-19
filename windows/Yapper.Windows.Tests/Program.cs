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
}
