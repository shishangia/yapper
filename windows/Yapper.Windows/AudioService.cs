using System.IO;
using NAudio.Wave;

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
    public event Action<Exception>? RecordingFailed;
    public event Action<float>? LevelChanged;
    private readonly object writerLock = new();
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
            capture.DataAvailable += (_, e) =>
            {
                try
                {
                    lock (writerLock) writer?.Write(e.Buffer, 0, e.BytesRecorded);
                    var peak = 0f;
                    for (var index = 0; index + 1 < e.BytesRecorded; index += 2) peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(e.Buffer, index) / 32768f));
                    LevelChanged?.Invoke(peak);
                }
                catch (Exception error) { if (stopped.TrySetException(error)) RecordingFailed?.Invoke(error); }
            };
            capture.RecordingStopped += (_, e) =>
            {
                lock (writerLock) { writer?.Dispose(); writer = null; }
                if (e.Exception is not null) { stopped.TrySetException(e.Exception); RecordingFailed?.Invoke(e.Exception); }
                else stopped.TrySetResult();
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

    public void TogglePlayback(string path)
    {
        if (IsPlaying && playback?.FileName == path) { player!.Pause(); return; }
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
