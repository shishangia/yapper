using System.IO;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Yapper.Windows;

public static class AudioDecoder
{
    public static float[] Decode(string source, string normalizedPath)
    {
        var writeNormalized = !Path.GetFullPath(source).Equals(
            Path.GetFullPath(normalizedPath), StringComparison.OrdinalIgnoreCase);
        using var reader = new AudioFileReader(source);
        ISampleProvider samples = reader;
        if (samples.WaveFormat.Channels == 2) samples = new StereoToMonoSampleProvider(samples);
        else if (samples.WaveFormat.Channels != 1) throw new InvalidDataException("Use a mono or stereo recording.");
        if (samples.WaveFormat.SampleRate != 16000) samples = new WdlResamplingSampleProvider(samples, 16000);
        var output = new List<float>();
        var buffer = new float[16000];
        using var file = writeNormalized ? new WaveFileWriter(normalizedPath, new WaveFormat(16000, 16, 1)) : null;
        int count;
        while ((count = samples.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (output.Count + count > 16000L * 60 * 120)
                throw new InvalidDataException("This preview supports recordings up to two hours.");
            output.AddRange(buffer.AsSpan(0, count).ToArray());
            file?.WriteSamples(buffer, 0, count);
        }
        if (output.Count == 0) throw new InvalidDataException("The file contains no readable audio.");
        return output.ToArray();
    }
}
