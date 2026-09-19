using System.IO;
using System.Windows;

namespace Yapper.Windows;

public partial class App : System.Windows.Application
{
    private Mutex? instance;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, failure) =>
        {
            System.Windows.MessageBox.Show("The operation could not finish. Your saved library was not reset.\n\n" + failure.Exception.Message, "Yapper");
            failure.Handled = true;
        };
        instance = new Mutex(true, "Local\\Yapper.Windows", out var created);
        if (!created) { System.Windows.MessageBox.Show("Yapper is already running. Open it from the system tray.", "Yapper"); Shutdown(); return; }
        try
        {
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Yapper");
            if (Environment.GetEnvironmentVariable("YAPPER_TEST_ROOT") is { Length: > 0 } testRoot) root = Path.GetFullPath(testRoot);
            var window = new MainWindow(root);
            MainWindow = window;
            window.Show();
        }
        catch (Exception error)
        {
            System.Windows.MessageBox.Show("Yapper could not open its local library. No data was replaced.\n\n" + error.Message, "Yapper");
            Shutdown(1);
        }
    }
    protected override void OnExit(ExitEventArgs e) { instance?.Dispose(); base.OnExit(e); }
}
