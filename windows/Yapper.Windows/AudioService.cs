using System.IO;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Yapper.Windows;

public sealed class AudioService : IDisposable
{
    private WaveInEvent? capture;
    private WaveFileWriter? writer;
    private TaskCompletionSource? stopped;
    private WaveOutEvent? player;
    private AudioFileReader? playback;
    public bool IsRecording => capture is not null;
    public bool IsPlaying => player?.PlaybackState == PlaybackState.Playing;
    public static string[] Inputs => Enumerable.Range(0, WaveIn.DeviceCount).Select(i => WaveIn.GetCapabilities(i).ProductName).ToArray();

    public void Start(string path, int device)
    {
        if (IsRecording) throw new InvalidOperationException("Recording is already active.");
        if (WaveIn.DeviceCount == 0) throw new InvalidOperationException("No microphone was found. Check Windows microphone privacy settings.");
        capture = new WaveInEvent { DeviceNumber = Math.Clamp(device, 0, WaveIn.DeviceCount - 1), WaveFormat = new WaveFormat(16000, 16, 1) };
        try
        {
            writer = new WaveFileWriter(path, capture.WaveFormat);
            stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
            capture.DataAvailable += (_, e) => writer?.Write(e.Buffer, 0, e.BytesRecorded);
            capture.RecordingStopped += (_, e) =>
            {
                writer?.Dispose();
                writer = null;
                if (e.Exception is not null) stopped.TrySetException(e.Exception); else stopped.TrySetResult();
            };
            capture.StartRecording();
        }
        catch { capture.Dispose(); capture = null; writer?.Dispose(); writer = null; throw; }
    }

    public async Task Stop()
    {
        if (capture is null) return;
        var current = capture;
        try { current.StopRecording(); if (stopped is not null) await stopped.Task; }
        finally { current.Dispose(); capture = null; }
    }

    public static float[] Decode(string source, string normalizedPath)
    {
        using var reader = new AudioFileReader(source);
        ISampleProvider samples = reader;
        if (samples.WaveFormat.Channels == 2) samples = new StereoToMonoSampleProvider(samples);
        else if (samples.WaveFormat.Channels != 1) throw new InvalidDataException("Use a mono or stereo recording.");
        if (samples.WaveFormat.SampleRate != 16000) samples = new WdlResamplingSampleProvider(samples, 16000);
        var output = new List<float>();
        var buffer = new float[16000];
        using var file = new WaveFileWriter(normalizedPath, new WaveFormat(16000, 16, 1));
        int count;
        while ((count = samples.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (output.Count + count > 16000L * 60 * 120) throw new InvalidDataException("This preview supports recordings up to two hours.");
            output.AddRange(buffer.AsSpan(0, count).ToArray());
            file.WriteSamples(buffer, 0, count);
        }
        if (output.Count == 0) throw new InvalidDataException("The file contains no readable audio.");
        return output.ToArray();
    }

    public void TogglePlayback(string path)
    {
        if (IsPlaying) { player!.Pause(); return; }
        if (playback?.FileName != path)
        {
            StopPlayback();
            playback = new AudioFileReader(path);
            player = new WaveOutEvent();
            player.Init(playback);
        }
        if (playback!.Position >= playback.Length) playback.Position = 0;
        player!.Play();
    }
    public void StopPlayback() { player?.Stop(); player?.Dispose(); player = null; playback?.Dispose(); playback = null; }
    public void Dispose() { capture?.StopRecording(); capture?.Dispose(); writer?.Dispose(); StopPlayback(); }
}
