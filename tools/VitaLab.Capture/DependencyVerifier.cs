using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace VitaLab.Capture;

static partial class DependencyVerifier
{
    public static async Task<(DependencyManifest Manifest, PreflightResult Result)> VerifyAsync(
        string manifestPath,
        string payloadRoot)
    {
        DependencyManifest manifest = JsonSerializer.Deserialize<DependencyManifest>(
            await File.ReadAllTextAsync(manifestPath), JsonOptions.Default)
            ?? throw new InvalidDataException("FFmpeg manifest is empty.");

        if (manifest.SchemaVersion != 1)
        {
            throw new InvalidDataException($"Unsupported FFmpeg manifest schema {manifest.SchemaVersion}.");
        }

        string ffmpegPath = ResolvePayloadFile(payloadRoot, manifest.Binary, "bin/ffmpeg.exe");
        string ffprobePath = ResolvePayloadFile(payloadRoot, manifest.Binary, "bin/ffprobe.exe");
        string ffmpegHash = ComputeSha256(ffmpegPath);
        string ffprobeHash = ComputeSha256(ffprobePath);
        VerifyHash(ffmpegPath, ffmpegHash, manifest.Binary.Files["bin/ffmpeg.exe"]);
        VerifyHash(ffprobePath, ffprobeHash, manifest.Binary.Files["bin/ffprobe.exe"]);

        ProcessResult version = await ProcessRunner.RunAsync(ffmpegPath, ["-hide_banner", "-version"]);
        RequireSuccess(version, "ffmpeg version");
        if (!version.StandardOutput.Contains(manifest.Version, StringComparison.Ordinal) ||
            !version.StandardOutput.Contains(manifest.SourceCommit[..10], StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("FFmpeg version does not match the pinned manifest identity.");
        }

        string configuration = ExtractConfiguration(version.StandardOutput);
        foreach (string forbidden in manifest.ForbiddenConfigureFlags)
        {
            if (ContainsConfigureFlag(configuration, forbidden))
            {
                throw new InvalidDataException($"FFmpeg contains forbidden configuration flag {forbidden}.");
            }
        }

        ProcessResult devices = await ProcessRunner.RunAsync(ffmpegPath, ["-hide_banner", "-devices"]);
        ProcessResult muxers = await ProcessRunner.RunAsync(ffmpegPath, ["-hide_banner", "-muxers"]);
        ProcessResult encoders = await ProcessRunner.RunAsync(ffmpegPath, ["-hide_banner", "-encoders"]);
        ProcessResult probeVersion = await ProcessRunner.RunAsync(ffprobePath, ["-hide_banner", "-version"]);
        RequireSuccess(devices, "FFmpeg device list");
        RequireSuccess(muxers, "FFmpeg muxer list");
        RequireSuccess(encoders, "FFmpeg encoder list");
        RequireSuccess(probeVersion, "ffprobe version");

        var capabilities = new List<string>();
        VerifyCapabilities(devices.StandardOutput, manifest.RequiredCapabilities.Devices, "device", capabilities);
        VerifyCapabilities(muxers.StandardOutput, manifest.RequiredCapabilities.Muxers, "muxer", capabilities);
        VerifyCapabilities(encoders.StandardOutput, manifest.RequiredCapabilities.Encoders, "encoder", capabilities);
        foreach (string preferred in manifest.RequiredCapabilities.PreferredEncoders)
        {
            if (HasListedCapability(encoders.StandardOutput, preferred))
            {
                capabilities.Add($"preferred-encoder:{preferred}");
            }
        }

        return (manifest, new PreflightResult(
            "PASS",
            FirstLine(version.StandardOutput),
            manifest.SourceCommit,
            Path.GetFullPath(ffmpegPath),
            Path.GetFullPath(ffprobePath),
            ffmpegHash,
            ffprobeHash,
            configuration,
            capabilities));
    }

    private static string ResolvePayloadFile(string payloadRoot, BinaryPackage package, string relativePath)
    {
        string path = Path.Combine(payloadRoot, package.PayloadDirectory, relativePath.Replace('/', Path.DirectorySeparatorChar));
        return File.Exists(path) ? path : throw new FileNotFoundException("Pinned FFmpeg payload file was not found.", path);
    }

    private static string ComputeSha256(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static void VerifyHash(string path, string actual, string expected)
    {
        if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"SHA-256 mismatch for {path}: expected {expected}, got {actual}.");
        }
    }

    private static void RequireSuccess(ProcessResult result, string operation)
    {
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException($"{operation} failed with exit code {result.ExitCode}: {result.StandardError.Trim()}");
        }
    }

    private static void VerifyCapabilities(string listing, IEnumerable<string> names, string kind, List<string> capabilities)
    {
        foreach (string name in names)
        {
            if (!HasListedCapability(listing, name))
            {
                throw new InvalidDataException($"Pinned FFmpeg is missing required {kind} {name}.");
            }
            capabilities.Add($"{kind}:{name}");
        }
    }

    private static bool HasListedCapability(string listing, string name) =>
        Regex.IsMatch(listing, $@"(?m)^\s*[A-Z\.]+\s+{Regex.Escape(name)}(?:\s|$)", RegexOptions.CultureInvariant);

    private static bool ContainsConfigureFlag(string configuration, string flag) =>
        Regex.IsMatch(configuration, $@"(?:^|\s){Regex.Escape(flag)}(?:\s|$)", RegexOptions.CultureInvariant);

    private static string ExtractConfiguration(string versionOutput)
    {
        string? line = versionOutput.Split('\n')
            .Select(value => value.Trim())
            .FirstOrDefault(value => value.StartsWith("configuration:", StringComparison.Ordinal));
        return line is null ? throw new InvalidDataException("FFmpeg did not report its build configuration.") : line[14..].Trim();
    }

    private static string FirstLine(string value) => value.Split('\n')[0].Trim();
}
