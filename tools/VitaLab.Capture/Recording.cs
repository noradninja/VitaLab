using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace VitaLab.Capture;

static class Recording
{
    public static async Task<RecordingResult> RunAsync(
        PreflightResult preflight,
        string videoDevice,
        string audioDevice,
        string outputPath,
        string progressPath,
        string logPath,
        string readyPath,
        string encoderPreference,
        int durationSeconds,
        int readyTimeoutSeconds,
        int stopTimeoutSeconds)
    {
        outputPath = Path.GetFullPath(outputPath);
        progressPath = Path.GetFullPath(progressPath);
        logPath = Path.GetFullPath(logPath);
        readyPath = Path.GetFullPath(readyPath);
        Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(progressPath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(readyPath)!);

        if (File.Exists(outputPath))
        {
            throw new IOException($"Recording output already exists: {outputPath}");
        }

        EncoderSelection encoder = await SelectEncoderAsync(preflight.FfmpegPath, encoderPreference);
        var startInfo = new ProcessStartInfo
        {
            FileName = preflight.FfmpegPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        IReadOnlyList<string> ffmpegArguments = BuildArguments(videoDevice, audioDevice, encoder, outputPath);
        foreach (string argument in ffmpegArguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        var startedAt = DateTimeOffset.UtcNow;
        var stopwatch = Stopwatch.StartNew();
        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("Failed to start FFmpeg recording.");
        }

        await using var progressWriter = new StreamWriter(progressPath, append: false);
        await using var logWriter = new StreamWriter(logPath, append: false);
        var readySource = new TaskCompletionSource<ProgressSample>(TaskCreationOptions.RunContinuationsAsynchronously);
        int sampleCount = 0;
        Task progressTask = ReadProgressAsync(
            process.StandardOutput, progressWriter, stopwatch, readySource,
            () => Interlocked.Increment(ref sampleCount));
        Task logTask = CopyLogAsync(process.StandardError, logWriter);
        Task exitTask = process.WaitForExitAsync();

        Task readyWinner = await Task.WhenAny(
            readySource.Task,
            exitTask,
            Task.Delay(TimeSpan.FromSeconds(readyTimeoutSeconds)));
        if (readyWinner != readySource.Task)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await exitTask;
            }
            await Task.WhenAll(progressTask, logTask);
            string reason = readyWinner == exitTask
                ? $"FFmpeg exited before producing a frame with code {process.ExitCode}."
                : $"FFmpeg did not produce a frame within {readyTimeoutSeconds} seconds.";
            throw new TimeoutException(reason + $" See {logPath}.");
        }

        ProgressSample readySample = await readySource.Task;
        await WriteJsonAtomicallyAsync(readyPath, readySample);

        if (durationSeconds > 0)
        {
            await Task.Delay(TimeSpan.FromSeconds(durationSeconds));
        }
        else
        {
            string? command = await Console.In.ReadLineAsync();
            if (!string.Equals(command, "STOP", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(command, "q", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Recording control input ended without STOP.");
            }
        }

        bool forced = false;
        if (!process.HasExited)
        {
            await process.StandardInput.WriteLineAsync("q");
            await process.StandardInput.FlushAsync();
            Task stopWinner = await Task.WhenAny(exitTask, Task.Delay(TimeSpan.FromSeconds(stopTimeoutSeconds)));
            if (stopWinner != exitTask)
            {
                forced = true;
                process.Kill(entireProcessTree: true);
            }
        }
        await exitTask;
        await Task.WhenAll(progressTask, logTask);

        DateTimeOffset finishedAt = DateTimeOffset.UtcNow;
        if (!File.Exists(outputPath) || new FileInfo(outputPath).Length == 0)
        {
            throw new InvalidDataException("FFmpeg did not create a non-empty recording.");
        }
        string hash = ComputeSha256(outputPath);
        string result = process.ExitCode == 0 && !forced ? "PASS" : "FAIL";
        return new RecordingResult(
            1,
            result,
            startedAt,
            readySample.ObservedAtUtc,
            finishedAt,
            videoDevice,
            audioDevice,
            encoder.Name,
            encoder.Preflight,
            "matroska",
            outputPath,
            hash,
            new FileInfo(outputPath).Length,
            process.ExitCode,
            forced,
            sampleCount,
            ffmpegArguments);
    }

    internal static IReadOnlyList<string> BuildArguments(
        string videoDevice,
        string audioDevice,
        EncoderSelection encoder,
        string outputPath)
    {
        var arguments = new List<string>
        {
            "-hide_banner", "-nostats", "-loglevel", "info",
            "-thread_queue_size", "512", "-rtbufsize", "512M",
            "-f", "dshow", "-audio_buffer_size", "50",
            "-i", $"video={videoDevice}:audio={audioDevice}",
            "-map", "0:v:0", "-map", "0:a:0"
        };
        arguments.AddRange(encoder.Arguments);
        arguments.AddRange([
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
            "-f", "matroska", "-progress", "pipe:1", "-stats_period", "0.25",
            "-y", outputPath
        ]);
        return arguments;
    }

    private static async Task<EncoderSelection> SelectEncoderAsync(string ffmpegPath, string preference)
    {
        if (preference.Equals("mpeg4", StringComparison.OrdinalIgnoreCase))
        {
            return new EncoderSelection(
                "mpeg4",
                ["-vf", "format=yuv420p", "-c:v", "mpeg4", "-q:v", "3"],
                "forced fallback validation");
        }
        if (!preference.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Encoder preference must be auto or mpeg4.");
        }

        string[] testArguments = [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi",
            "-i", "testsrc2=size=1280x720:rate=60", "-frames:v", "30",
            "-an", "-vf", "format=nv12", "-c:v", "h264_mf", "-f", "null", "NUL"
        ];
        ProcessResult h264Test = await ProcessRunner.RunAsync(ffmpegPath, testArguments);
        if (h264Test.ExitCode == 0)
        {
            return new EncoderSelection(
                "h264_mf",
                ["-vf", "format=nv12", "-c:v", "h264_mf", "-scenario", "archive", "-quality", "75"],
                "PASS");
        }

        return new EncoderSelection(
            "mpeg4",
            ["-vf", "format=yuv420p", "-c:v", "mpeg4", "-q:v", "3"],
            $"h264_mf rejected; fallback selected (exit {h264Test.ExitCode})");
    }

    private static async Task ReadProgressAsync(
        StreamReader reader,
        StreamWriter writer,
        Stopwatch stopwatch,
        TaskCompletionSource<ProgressSample> readySource,
        Action countSample)
    {
        var parser = new ProgressParser();
        while (await reader.ReadLineAsync() is { } line)
        {
            ProgressSample? sample = parser.AddLine(line, DateTimeOffset.UtcNow, stopwatch.Elapsed.TotalSeconds);
            if (sample is null)
            {
                continue;
            }
            await writer.WriteLineAsync(JsonSerializer.Serialize(sample, JsonOptions.Default));
            await writer.FlushAsync();
            countSample();
            if (sample.Frame > 0)
            {
                readySource.TrySetResult(sample);
            }
        }
    }

    private static async Task CopyLogAsync(StreamReader reader, StreamWriter writer)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            await writer.WriteLineAsync(line);
            await writer.FlushAsync();
        }
    }

    private static async Task WriteJsonAtomicallyAsync(string path, object value)
    {
        string temporaryPath = path + ".tmp";
        await File.WriteAllTextAsync(temporaryPath, JsonSerializer.Serialize(value, JsonOptions.Default));
        File.Move(temporaryPath, path, overwrite: true);
    }

    private static string ComputeSha256(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
}
