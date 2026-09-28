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
    }

    private static void Require(bool condition, string name)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"Self-test failed: {name}.");
        }
    }
}
