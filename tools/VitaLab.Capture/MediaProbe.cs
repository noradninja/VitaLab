using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace VitaLab.Capture;

static class MediaProbe
{
    public static async Task<ProbeResult> RunAsync(PreflightResult preflight, string inputPath)
    {
        inputPath = Path.GetFullPath(inputPath);
        if (!File.Exists(inputPath))
        {
            throw new FileNotFoundException("Recording was not found.", inputPath);
        }

        ProcessResult probe = await ProcessRunner.RunAsync(
            preflight.FfprobePath,
            ["-v", "error", "-show_format", "-show_streams", "-of", "json", inputPath]);
        if (probe.ExitCode != 0)
        {
            throw new InvalidDataException($"ffprobe rejected the recording: {probe.StandardError.Trim()}");
        }

        using JsonDocument document = JsonDocument.Parse(probe.StandardOutput);
        JsonElement root = document.RootElement;
        var streams = new List<StreamProbe>();
        foreach (JsonElement stream in root.GetProperty("streams").EnumerateArray())
        {
            streams.Add(new StreamProbe(
                stream.GetProperty("index").GetInt32(),
                GetString(stream, "codec_type") ?? "unknown",
                GetString(stream, "codec_name") ?? "unknown",
                GetInt32(stream, "width"),
                GetInt32(stream, "height"),
                GetString(stream, "pix_fmt"),
                GetString(stream, "avg_frame_rate"),
                ParseInt32(GetString(stream, "sample_rate")),
                GetInt32(stream, "channels")));
        }

        if (!streams.Any(stream => stream.CodecType == "video") ||
            !streams.Any(stream => stream.CodecType == "audio"))
        {
            throw new InvalidDataException("Recording must contain both video and audio streams.");
        }

        string? durationText = GetString(root.GetProperty("format"), "duration");
        if (!double.TryParse(durationText, NumberStyles.Float, CultureInfo.InvariantCulture, out double duration) || duration <= 0)
        {
            throw new InvalidDataException("Recording duration is missing or invalid.");
        }

        ProcessResult decode = await ProcessRunner.RunAsync(
            preflight.FfmpegPath,
            ["-hide_banner", "-v", "error", "-i", inputPath,
             "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "NUL"]);
        if (decode.ExitCode != 0)
        {
            throw new InvalidDataException($"Full recording decode failed: {decode.StandardError.Trim()}");
        }

        return new ProbeResult(
            1,
            "PASS",
            inputPath,
            ComputeSha256(inputPath),
            new FileInfo(inputPath).Length,
            duration,
            streams,
            "PASS");
    }

    private static string? GetString(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static int? GetInt32(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out JsonElement value) && value.TryGetInt32(out int parsed)
            ? parsed
            : null;

    private static int? ParseInt32(string? value) =>
        int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int parsed) ? parsed : null;

    private static string ComputeSha256(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
}
