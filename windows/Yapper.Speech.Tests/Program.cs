using Yapper.Windows;

var model = new SpeechModel("whisper-tiny", ["unused"]);
var progress = new Progress<(string, double)>();
var tests = new (string Name, Func<Task> Run)[]
{
    ("idle timer cannot revive models after shutdown", async () =>
    {
        var clock = new TestClock();
        var service = new SpeechService(new(), clock);
        await service.Warm(model, "en", false, CancellationToken.None);
        clock.Advance(TimeSpan.FromMinutes(6));
        var pending = service.UnloadIfIdle(5);
        service.Dispose();
        await pending;
        await service.UnloadIfIdle(5);
        try { await service.Warm(model, "en", false, CancellationToken.None); throw new Exception("Disposed service loaded a model"); }
        catch (ObjectDisposedException) { }
        Check(NativeCalls.Loads.Count == 1, "Disposed service reloaded a model");
    }),
    ("idle unloading preserves active recordings and reloads later", async () =>
    {
        var clock = new TestClock();
        using var service = new SpeechService(new(), clock);
        await service.Warm(model, "en", false, CancellationToken.None);
        service.SetRecording(true); clock.Advance(TimeSpan.FromMinutes(10));
        await service.UnloadIfIdle(5);
        await service.Warm(model, "en", false, CancellationToken.None);
        Check(NativeCalls.Loads.Count == 1, "Recording model was unloaded.");
        service.SetRecording(false); clock.Advance(TimeSpan.FromMinutes(6));
        await service.UnloadIfIdle(5);
        await service.Warm(model, "en", false, CancellationToken.None);
        Check(NativeCalls.Loads.Count == 2, "Idle model did not reload.");
    }),
    ("vocabulary changes rebuild the processor without reloading model weights", async () =>
    {
        using var service = new SpeechService(new());
        await service.Warm(model, "en", false, CancellationToken.None, "Yapper\nWorkstation");
        await service.Warm(model, "en", false, CancellationToken.None, "Yapper\nWorkstation");
        await service.Warm(model, "en", false, CancellationToken.None, "New term");
        Check(NativeCalls.Loads.Count == 1, "Vocabulary change reloaded model weights.");
        Check(NativeCalls.Prompts.SequenceEqual(["Yapper, Workstation", "New term"]), "Wrong vocabulary prompt.");
    }),
    ("warm-up leaves the caller responsive for both engines", async () =>
    {
        foreach (var id in new[] { "whisper-tiny", "parakeet-v3" })
        {
            using var service = new SpeechService(new());
            await OnDedicatedCaller(async caller =>
            {
                NativeCalls.OnLoad = _ =>
                {
                    if (Environment.CurrentManagedThreadId == caller) throw new Exception("Model load ran on the caller thread.");
                };
                await service.Warm(new(id, ["unused"]), "en", false, CancellationToken.None);
            });
        }
    }),
    ("cold transcription prepares the model off the caller", async () =>
    {
        using var service = new SpeechService(new());
        await OnDedicatedCaller(async caller =>
        {
            NativeCalls.OnLoad = _ =>
            {
                if (Environment.CurrentManagedThreadId == caller) throw new Exception("Model load ran on the caller thread.");
            };
            var result = await service.Transcribe([0f], model, "en", false, false, progress, CancellationToken.None);
            Check(result.Transcript.PlainText == "Hello", "Cold transcription failed.");
        });
    }),
    ("Whisper inference receives the job's cancellation token", async () =>
    {
        using var service = new SpeechService(new());
        using var cancel = new CancellationTokenSource();
        await service.Transcribe([0f], model, "en", false, false, progress, cancel.Token);
        Check(NativeCalls.InferenceTokens.SequenceEqual([cancel.Token]), "Inference cannot be canceled mid-run.");
    }),
    ("cancel during GPU inference skips CPU retry", async () =>
    {
        using var service = new SpeechService(new());
        using var cancel = new CancellationTokenSource();
        NativeCalls.OnInference = gpu =>
        {
            if (gpu) { cancel.Cancel(); throw new InvalidOperationException("GPU failed"); }
        };
        await Canceled(() => service.Transcribe([0f], model, "en", false, false, progress, cancel.Token));
        Check(NativeCalls.Loads.SequenceEqual([true]), "Canceled inference loaded a CPU model.");
        Check(NativeCalls.Inferences.SequenceEqual([true]), "Canceled inference retried on CPU.");
    }),
    ("cancel during GPU model loading skips fallback", async () =>
    {
        using var service = new SpeechService(new());
        using var cancel = new CancellationTokenSource();
        NativeCalls.OnLoad = gpu =>
        {
            if (gpu) { cancel.Cancel(); throw new InvalidOperationException("GPU load failed"); }
        };
        await Canceled(() => service.Warm(model, "en", false, cancel.Token));
        Check(NativeCalls.Loads.SequenceEqual([true]), "Canceled warm-up retried on CPU.");
    }),
    ("cancel during CPU preparation skips retry inference", async () =>
    {
        using var service = new SpeechService(new());
        using var cancel = new CancellationTokenSource();
        NativeCalls.OnInference = gpu => { if (gpu) throw new InvalidOperationException("GPU failed"); };
        NativeCalls.OnLoad = gpu => { if (!gpu) cancel.Cancel(); };
        await Canceled(() => service.Transcribe([0f], model, "en", false, false, progress, cancel.Token));
        Check(NativeCalls.Inferences.SequenceEqual([true]), "CPU inference started after cancellation.");
    }),
    ("GPU failure retries once and reuses CPU model", async () =>
    {
        using var service = new SpeechService(new());
        NativeCalls.OnInference = gpu => { if (gpu) throw new InvalidOperationException("GPU failed"); };
        var first = await service.Transcribe([0f], model, "en", false, false, progress, CancellationToken.None);
        var second = await service.Transcribe([0f], model, "en", false, false, progress, CancellationToken.None);
        Check(first.Transcript.PlainText == "Hello" && second.Transcript.PlainText == "Hello", "Fallback lost output.");
        Check(NativeCalls.Loads.SequenceEqual([true, false]), "CPU model was not reused.");
        Check(NativeCalls.Inferences.SequenceEqual([true, false, false]), "Unexpected inference order.");
    }),
    ("preview GPU failure drops the draft without switching to CPU", async () =>
    {
        using var service = new SpeechService(new());
        var failGpu = true;
        NativeCalls.OnInference = gpu => { if (gpu && failGpu) throw new InvalidOperationException("GPU failed"); };
        try { await service.Transcribe([0f], model, "en", false, false, progress, CancellationToken.None, preview: true); throw new Exception("Preview error was hidden"); }
        catch (InvalidOperationException) { }
        failGpu = false;
        var result = await service.Transcribe([0f], model, "en", false, false, progress, CancellationToken.None);
        Check(result.Transcript.PlainText == "Hello", "Full transcription failed after a preview error.");
        Check(NativeCalls.Loads.SequenceEqual([true]), "Preview error loaded a CPU model.");
        Check(NativeCalls.Inferences.SequenceEqual([true, true]), "Preview error moved the session to CPU.");
    }),
    ("cancel waits for active load before the next job enters", async () =>
    {
        using var service = new SpeechService(new());
        using var cancel = new CancellationTokenSource();
        using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        NativeCalls.OnLoad = _ => { entered.TrySetResult(); release.Wait(TimeSpan.FromSeconds(5)); };
        // Invoke on a dedicated caller so a regression cannot block the test coordinator.
        var returned = new TaskCompletionSource<Task>(TaskCreationOptions.RunContinuationsAsynchronously);
        var caller = new Thread(() => returned.SetResult(service.Warm(model, "en", false, cancel.Token)));
        caller.Start();
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            var active = await returned.Task.WaitAsync(TimeSpan.FromSeconds(2));
            cancel.Cancel();
            var next = service.Warm(model, "en", false, CancellationToken.None);
            Check(!active.IsCompleted && !next.IsCompleted, "An active load released admission early.");
            release.Set();
            await Canceled(() => active);
            await next;
        }
        finally { release.Set(); caller.Join(); }
    })
};
var failures = 0;
foreach (var (name, run) in tests)
{
    NativeCalls.Reset();
    try { await run(); Console.WriteLine("PASS " + name); }
    catch (Exception error) { failures++; Console.Error.WriteLine("FAIL " + name + ": " + error.Message); }
}
Console.WriteLine($"{tests.Length - failures}/{tests.Length} speech checks passed");
return failures == 0 ? 0 : 1;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static async Task OnDedicatedCaller(Func<int, Task> action)
{
    var returned = new TaskCompletionSource<Task>(TaskCreationOptions.RunContinuationsAsynchronously);
    var caller = new Thread(() =>
    {
        try { returned.SetResult(action(Environment.CurrentManagedThreadId)); }
        catch (Exception error) { returned.SetException(error); }
    });
    caller.Start();
    await await returned.Task;
    caller.Join();
}
static async Task Canceled(Func<Task> action)
{
    try { await action(); }
    catch (OperationCanceledException) { return; }
    throw new Exception("Expected cancellation.");
}

sealed class TestClock : TimeProvider
{
    private long timestamp;
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp() => timestamp;
    public void Advance(TimeSpan duration) => timestamp += duration.Ticks;
}
