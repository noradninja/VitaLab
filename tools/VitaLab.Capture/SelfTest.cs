namespace VitaLab.Capture;

static class SelfTest
{
    public static void Run()
    {
        const string devices = """
            [dshow @ 0001] "Game Capture HD60 Pro" (video)
            [dshow @ 0001]   Alternative name "@device_pnp_sensitive-video"
            [dshow @ 0001] "Microphone (Game Capture HD60 Pro)" (audio)
            [dshow @ 0001]   Alternative name "@device_cm_sensitive-audio"
            """;
        IReadOnlyList<CaptureDevice> parsedDevices = Discovery.ParseDevices(devices);
        Require(parsedDevices.Count == 2, "device count");
        Require(parsedDevices[0].Name == "Game Capture HD60 Pro", "video name");
        Require(parsedDevices[0].AlternativeNameSha256 is { Length: 64 }, "video identifier hash");
        Require(parsedDevices.All(device => !device.ToString()!.Contains("sensitive", StringComparison.Ordinal)), "identifier redaction");

        const string options = """
            [dshow @ 0001]   pixel_format=yuyv422  min s=1280x720 fps=60 max s=1920x1080 fps=60
            [dshow @ 0001]   vcodec=mjpeg min s=640x480 fps=30 max s=1920x1080 fps=60
            """;
        IReadOnlyList<DeviceOption> parsedOptions = Discovery.ParseOptions("video", options);
        Require(parsedOptions.Count == 2, "option count");

        const string audioOptions = "[in#0 @ 0001]   ch= 2, bits=16, rate= 48000";
        Require(Discovery.ParseOptions("audio", audioOptions).Count == 1, "audio option count");

        Arguments parsedArguments = Arguments.Parse(["discover", "--manifest", "manifest.json", "--payload-root", "payload"]);
        Require(parsedArguments.Command == "discover", "command parse");
        Require(parsedArguments.Require("manifest") == "manifest.json", "option parse");

        var progress = new ProgressParser();
        Require(progress.AddLine("frame=60", DateTimeOffset.UnixEpoch, 1.0) is null, "progress partial");
        Require(progress.AddLine("out_time_us=1000000", DateTimeOffset.UnixEpoch, 1.1) is null, "progress time partial");
        ProgressSample? sample = progress.AddLine("progress=continue", DateTimeOffset.UnixEpoch, 1.2);
        Require(sample?.Frame == 60 && sample.OutTimeUs == 1000000, "progress sample");

        IReadOnlyList<string> recordingArguments = Recording.BuildArguments(
            "Video Device", "Audio Device",
            new EncoderSelection("mpeg4", ["-c:v", "mpeg4"], "fallback"),
            "evidence file.mkv");
        Require(recordingArguments.Contains("video=Video Device:audio=Audio Device"), "device argument");
        Require(recordingArguments[^1] == "evidence file.mkv", "output argument");
    }

    private static void Require(bool condition, string name)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"Self-test failed: {name}.");
        }
    }
}
