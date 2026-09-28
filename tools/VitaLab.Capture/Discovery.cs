using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace VitaLab.Capture;

static partial class Discovery
{
    public static async Task<DiscoveryResult> RunAsync(
        PreflightResult preflight,
        string videoDevice,
        string audioDevice)
    {
        ProcessResult listing = await ProcessRunner.RunAsync(
            preflight.FfmpegPath,
            ["-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"]);

        IReadOnlyList<CaptureDevice> devices = ParseDevices(listing.StandardError);
        RequireDevice(devices, "video", videoDevice);
        RequireDevice(devices, "audio", audioDevice);

        ProcessResult videoOptions = await ProcessRunner.RunAsync(
            preflight.FfmpegPath,
            ["-hide_banner", "-list_options", "true", "-f", "dshow", "-i", $"video={videoDevice}"]);
        ProcessResult audioOptions = await ProcessRunner.RunAsync(
            preflight.FfmpegPath,
            ["-hide_banner", "-list_options", "true", "-f", "dshow", "-i", $"audio={audioDevice}"]);

        IReadOnlyList<DeviceOption> parsedVideo = ParseOptions("video", videoOptions.StandardError);
        IReadOnlyList<DeviceOption> parsedAudio = ParseOptions("audio", audioOptions.StandardError);
        if (parsedVideo.Count == 0 || parsedAudio.Count == 0)
        {
            throw new InvalidOperationException("DirectShow did not report options for both selected capture endpoints.");
        }

        return new DiscoveryResult(
            1,
            "PASS",
            DateTimeOffset.UtcNow,
            preflight.Version,
            devices,
            videoDevice,
            audioDevice,
            parsedVideo,
            parsedAudio);
    }

    internal static IReadOnlyList<CaptureDevice> ParseDevices(string stderr)
    {
        var devices = new List<CaptureDevice>();
        CaptureDevice? previous = null;
        foreach (string rawLine in stderr.Split('\n'))
        {
            string line = StripPrefix(rawLine).Trim();
            Match deviceMatch = DeviceLineRegex().Match(line);
            if (deviceMatch.Success)
            {
                previous = new CaptureDevice(
                    deviceMatch.Groups["type"].Value.ToLowerInvariant(),
                    deviceMatch.Groups["name"].Value,
                    null);
                devices.Add(previous);
                continue;
            }

            Match alternativeMatch = AlternativeLineRegex().Match(line);
            if (previous is not null && alternativeMatch.Success)
            {
                int index = devices.Count - 1;
                previous = previous with
                {
                    AlternativeNameSha256 = Sha256(alternativeMatch.Groups["name"].Value)
                };
                devices[index] = previous;
            }
        }
        return devices;
    }

    internal static IReadOnlyList<DeviceOption> ParseOptions(string mediaType, string stderr)
    {
        var options = new List<DeviceOption>();
        foreach (string rawLine in stderr.Split('\n'))
        {
            string line = StripPrefix(rawLine).Trim();
            if ((line.Contains("pixel_format=", StringComparison.Ordinal) ||
                 line.Contains("vcodec=", StringComparison.Ordinal) ||
                 line.StartsWith("ch=", StringComparison.Ordinal)) &&
                !line.Contains("Alternative name", StringComparison.OrdinalIgnoreCase))
            {
                options.Add(new DeviceOption(mediaType, line));
            }
        }
        return options;
    }

    private static string StripPrefix(string value)
    {
        int index = value.IndexOf(']');
        return index >= 0 ? value[(index + 1)..] : value;
    }

    private static void RequireDevice(IReadOnlyList<CaptureDevice> devices, string type, string name)
    {
        if (!devices.Any(device => device.Type == type && device.Name.Equals(name, StringComparison.Ordinal)))
        {
            throw new InvalidOperationException($"DirectShow {type} device '{name}' was not found.");
        }
    }

    private static string Sha256(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    [GeneratedRegex("^\"(?<name>.+)\" \\((?<type>video|audio)\\)$", RegexOptions.CultureInvariant)]
    private static partial Regex DeviceLineRegex();

    [GeneratedRegex("^Alternative name \"(?<name>.+)\"$", RegexOptions.CultureInvariant)]
    private static partial Regex AlternativeLineRegex();
}
