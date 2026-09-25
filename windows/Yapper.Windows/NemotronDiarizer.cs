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

    internal IReadOnlyList<SpeakerTurn> Process(float[] samples, CancellationToken cancellation)
    {
        if (process.HasExited) throw Failure("The speaker runtime stopped.");
        using var kill = cancellation.Register(() => { try { process.Kill(true); } catch { } });
        string? line;
        try
        {
            var bytes = MemoryMarshal.AsBytes(samples.AsSpan());
            process.StandardInput.BaseStream.Write(BitConverter.GetBytes((long)bytes.Length));
            process.StandardInput.BaseStream.Write(bytes);
            process.StandardInput.BaseStream.Flush();
            line = process.StandardOutput.ReadLine();
        }
        catch (IOException error)
        {
            cancellation.ThrowIfCancellationRequested();
            throw Failure("The speaker runtime stopped. " + error.Message);
        }
        cancellation.ThrowIfCancellationRequested();
        if (line is null) throw Failure("The speaker runtime returned no result.");
        var turns = JsonSerializer.Deserialize<NativeSpeakerTurn[]>(line,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
        return turns.Select(t => new SpeakerTurn(t.SpeakerId, t.Start, t.End)).ToArray();
    }

    private InvalidOperationException Failure(string fallback)
    {
        // stderr only completes once the helper exits; give a dying helper a moment to flush it.
        var error = standardError.Wait(2000) ? standardError.Result.Trim() : "";
        return new(error.Length > 0 ? error[Math.Max(0, error.Length - 600)..] : fallback);
    }

    public void Dispose()
    {
        try { process.StandardInput.Close(); } catch (IOException) { }
        if (!process.WaitForExit(3000)) { process.Kill(true); process.WaitForExit(); }
        process.Dispose();
    }
}
