using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using Clipboard = System.Windows.Clipboard;

namespace Yapper.Windows;

public sealed class WindowsInput : IDisposable
{
    private int hotkeyId = 3107;
    private readonly HwndSource source;
    private readonly DispatcherTimer releaseTimer;
    private uint virtualKey;
    private bool held;
    private string? registeredShortcut;
    public event Action? Pressed;
    public event Action? Released;
    public WindowsInput(IntPtr handle)
    {
        source = HwndSource.FromHwnd(handle);
        source.AddHook(Hook);
        releaseTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(35), DispatcherPriority.Input, (_, _) =>
        {
            if (held && (GetAsyncKeyState((int)virtualKey) & 0x8000) == 0)
            {
                held = false;
                Released?.Invoke();
            }
        }, Dispatcher.CurrentDispatcher);
    }
    public void Register(string shortcut)
    {
        if (registeredShortcut == shortcut) return;
        var parts = shortcut.Split('+');
        uint modifiers = 0x4000;
        foreach (var part in parts[..^1]) modifiers |= part switch { "Control" => 2u, "Alt" => 1u, "Shift" => 4u, _ => throw new ArgumentException("Unsupported shortcut.") };
        var key = parts[^1] switch { "Space" => 0x20u, "F9" => 0x78u, "F10" => 0x79u, _ => throw new ArgumentException("Unsupported shortcut key.") };
        var nextId = hotkeyId == 3107 ? 3108 : 3107;
        if (!RegisterHotKey(source.Handle, nextId, modifiers, key)) throw new InvalidOperationException("That shortcut is already used by another app. Choose a different one.");
        UnregisterHotKey(source.Handle, hotkeyId);
        hotkeyId = nextId;
        virtualKey = key;
        registeredShortcut = shortcut;
    }
    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == 0x0312 && wParam.ToInt32() == hotkeyId && !held)
        {
            held = true;
            Pressed?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }
    public static IntPtr CaptureTarget() => GetForegroundWindow();

    public static async Task<string?> Paste(string text, IntPtr target, bool restore, Func<bool> canCommit)
    {
        if (!canCommit()) return null;
        if (target == IntPtr.Zero || !IsWindow(target) || !SetForegroundWindow(target))
        {
            Clipboard.SetText(text);
            return "Copied. Focus your text field and press Ctrl+V.";
        }
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0))
        {
            if (!canCommit()) return null;
            if (DateTime.UtcNow >= deadline) { Clipboard.SetText(text); return "Copied. Release the shortcut keys and press Ctrl+V."; }
            await Task.Delay(35);
        }
        await Task.Delay(200);
        if (!canCommit()) return null;
        if (GetForegroundWindow() != target)
        {
            Clipboard.SetText(text);
            return "Copied. The original text field is no longer focused.";
        }
        System.Windows.DataObject? previous = null;
        if (restore && Clipboard.GetDataObject() is { } data)
        {
            previous = new System.Windows.DataObject();
            foreach (var format in data.GetFormats(false))
            {
                var value = data.GetData(format, false);
                if (value is not null) previous.SetData(format, value);
            }
        }
        Clipboard.SetText(text);
        var sequence = GetClipboardSequenceNumber();
        var inputs = new[] { Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true) };
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length)
            return "Copied. Windows blocked auto-paste; press Ctrl+V. Elevated apps may require manual paste.";
        if (restore)
        {
            await Task.Delay(500);
            if (GetClipboardSequenceNumber() == sequence)
            {
                if (previous is null) Clipboard.Clear(); else Clipboard.SetDataObject(previous, true);
            }
        }
        return null;
    }
    private static Input Key(ushort code, bool up) => new() { Type = 1, Union = new InputUnion { Keyboard = new KeyboardInput { VirtualKey = code, Flags = up ? 2u : 0u } } };
    public void Dispose() { releaseTimer.Stop(); UnregisterHotKey(source.Handle, hotkeyId); source.RemoveHook(Hook); }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputUnion Union; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion { [FieldOffset(0)] public KeyboardInput Keyboard; [FieldOffset(0)] public MouseInput Mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort VirtualKey, Scan; public uint Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
}
