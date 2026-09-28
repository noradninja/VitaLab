using System.Text.Json.Serialization;

namespace VitaLab.Capture;

sealed record DependencyManifest(
    int SchemaVersion,
    string Name,
    string Version,
    string ReleaseBranch,
    string SourceCommit,
    string License,
    BinaryPackage Binary,
    SourcePackage Source,
    string[] ForbiddenConfigureFlags,
    RequiredCapabilities RequiredCapabilities);

sealed record BinaryPackage(
    string Provider,
    string ArchiveName,
    string Url,
    string Sha256,
    string PayloadDirectory,
    Dictionary<string, string> Files);

sealed record SourcePackage(string ArchiveName, string Url, string Sha256);

sealed record RequiredCapabilities(
    string[] Devices,
    string[] Muxers,
    string[] Encoders,
    string[] PreferredEncoders);

sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
    [JsonIgnore]
    public string Combined => StandardOutput + Environment.NewLine + StandardError;
}

sealed record PreflightResult(
    string Result,
    string Version,
    string SourceCommit,
    string FfmpegPath,
    string FfprobePath,
    string FfmpegSha256,
    string FfprobeSha256,
    string Configuration,
    IReadOnlyList<string> Capabilities);

sealed record CaptureDevice(
    string Type,
    string Name,
    string? AlternativeNameSha256);

sealed record DeviceOption(
    string MediaType,
    string Description);

sealed record DiscoveryResult(
    int SchemaVersion,
    string Result,
    DateTimeOffset DiscoveredAtUtc,
    string FfmpegVersion,
    IReadOnlyList<CaptureDevice> Devices,
    string SelectedVideoDevice,
    string SelectedAudioDevice,
    IReadOnlyList<DeviceOption> VideoOptions,
    IReadOnlyList<DeviceOption> AudioOptions);

sealed record ProgressSample(
    DateTimeOffset ObservedAtUtc,
    double HostMonotonicSeconds,
    long? Frame,
    long? OutTimeUs,
    string? OutTime,
    string Progress,
    IReadOnlyDictionary<string, string> Values);

sealed record EncoderSelection(string Name, string[] Arguments, string Preflight);

sealed record RecordingResult(
    int SchemaVersion,
    string Result,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset ReadyAtUtc,
    DateTimeOffset FinishedAtUtc,
    string VideoDevice,
    string AudioDevice,
    string Encoder,
    string EncoderPreflight,
    string Container,
    string OutputFile,
    string OutputSha256,
    long OutputBytes,
    int ExitCode,
    bool ForcedTermination,
    int ProgressSampleCount,
    IReadOnlyList<string> FfmpegArguments);

sealed record StreamProbe(
    int Index,
    string CodecType,
    string CodecName,
    int? Width,
    int? Height,
    string? PixelFormat,
    string? FrameRate,
    int? SampleRate,
    int? Channels);

sealed record ProbeResult(
    int SchemaVersion,
    string Result,
    string InputFile,
    string Sha256,
    long Bytes,
    double DurationSeconds,
    IReadOnlyList<StreamProbe> Streams,
    string DecodeResult);
