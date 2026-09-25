using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using Yapper.Core;

namespace Yapper.Windows;

internal sealed record NativeSpeakerTurn(string SpeakerId, double Start, double End);

internal sealed class NemotronDiarizer : IDisposable
{
    private readonly System.Diagnostics.Process process;
    private readonly Task<string> standardError;

    internal NemotronDiarizer(string modelPath)
    {
        var helper = Environment.GetEnvironmentVariable("YAPPER_NEMOTRON_HELPER");
        if (string.IsNullOrWhiteSpace(helper)) helper = Path.Combine(AppContext.BaseDirectory, "Yapper.Nemotron.exe");
        if (!File.Exists(helper)) throw new FileNotFoundException("The local Nemotron speaker runtime is missing.", helper);
        var start = new ProcessStartInfo(helper) { UseShellExecute = false, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        start.ArgumentList.Add(modelPath);
        process = System.Diagnostics.Process.Start(start)
            ?? throw new InvalidOperationException("Could not start speaker detection.");
        standardError = process.StandardError.ReadToEndAsync();
    }

    internal IReadOnlyList<SpeakerTurn> Process(float[] samples)
    {
        if (process.HasExited) throw new InvalidOperationException(
            standardError.GetAwaiter().GetResult().Trim() is { Length: > 0 } error ? error : "The speaker runtime stopped.");
        var bytes = MemoryMarshal.AsBytes(samples.AsSpan());
        process.StandardInput.BaseStream.Write(BitConverter.GetBytes((long)bytes.Length));
        process.StandardInput.BaseStream.Write(bytes);
        process.StandardInput.BaseStream.Flush();
        var line = process.StandardOutput.ReadLine() ?? throw new InvalidOperationException("The speaker runtime returned no result.");
        var turns = JsonSerializer.Deserialize<NativeSpeakerTurn[]>(line,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
        return turns.Select(t => new SpeakerTurn(t.SpeakerId, t.Start, t.End)).ToArray();
    }

    public void Dispose()
    {
        process.StandardInput.Close();
        if (!process.WaitForExit(3000)) { process.Kill(true); process.WaitForExit(); }
        process.Dispose();
    }
}
