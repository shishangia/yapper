using Microsoft.Win32;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace Yapper.Windows;

internal static class AppTheme
{
    public static string Preference { get; private set; } = "System";
    public static void Apply(string preference)
    {
        Preference = preference is "Light" or "Dark" ? preference : "System";
        var dark = Preference == "Dark" || Preference == "System" &&
            Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int value && value == 0;
        var colors = new Dictionary<string, string>
        {
            ["AppBackground"] = dark ? "#201C25" : "#FCF8FB",
            ["ContentBackground"] = dark ? "#241F2B" : "#FFFCFE",
            ["SidebarBackground"] = dark ? "#211B28" : "#F5EDF7",
            ["Surface"] = dark ? "#302837" : "#FFFFFF",
            ["Hover"] = dark ? "#3D3245" : "#F2E7F0",
            ["Selected"] = dark ? "#523449" : "#FFC8DC",
            ["Border"] = dark ? "#65536E" : "#D9CBDC",
            ["SubtleBorder"] = dark ? "#493B52" : "#EBE1ED",
            ["Ink"] = dark ? "#FCF2FA" : "#302438",
            ["SecondaryInk"] = dark ? "#D8C7E1" : "#63526C",
            ["MutedInk"] = dark ? "#C3B0CE" : "#706078",
            ["Accent"] = dark ? "#FFAFCC" : "#8B365F",
            ["BlueAccent"] = dark ? "#A2D2FF" : "#285E91",
            ["PrimaryButton"] = "#FFAFCC",
            ["PrimaryButtonInk"] = "#302438"
        };
        foreach (var (key, hex) in colors)
            System.Windows.Application.Current.Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        if (SystemParameters.HighContrast)
        {
            foreach (var key in new[] { "AppBackground", "ContentBackground", "SidebarBackground", "Surface", "Hover" })
                System.Windows.Application.Current.Resources[key] = SystemColors.WindowBrush;
            foreach (var key in new[] { "Ink", "SecondaryInk", "MutedInk", "Border", "SubtleBorder" })
                System.Windows.Application.Current.Resources[key] = SystemColors.WindowTextBrush;
            foreach (var key in new[] { "Selected", "PrimaryButton" }) System.Windows.Application.Current.Resources[key] = SystemColors.HighlightBrush;
            System.Windows.Application.Current.Resources["PrimaryButtonInk"] = SystemColors.HighlightTextBrush;
        }
        foreach (Window window in System.Windows.Application.Current.Windows) ApplyTitleBar(window, dark);
    }

    public static void ApplyTitleBar(Window window) => Apply(Preference);
    private static void ApplyTitleBar(Window window, bool dark)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;
        var value = dark && !SystemParameters.HighContrast ? 1 : 0;
        DwmSetWindowAttribute(handle, 20, ref value, sizeof(int));
    }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
