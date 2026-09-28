using System.Text.Json;
using VitaLab.Capture;

try
{
    Arguments arguments = Arguments.Parse(args);
    if (arguments.Command == "self-test")
    {
        SelfTest.Run();
        Console.WriteLine("VitaLab.Capture self-test PASS");
        return 0;
    }

    string manifestPath = Path.GetFullPath(arguments.Require("manifest"));
    string payloadRoot = Path.GetFullPath(arguments.Require("payload-root"));
    (DependencyManifest manifest, PreflightResult preflight) =
        await DependencyVerifier.VerifyAsync(manifestPath, payloadRoot);

    object output = arguments.Command switch
    {
        "preflight" => preflight,
        "discover" => await Discovery.RunAsync(
            preflight,
            arguments.Optional("video-device", "Game Capture HD60 Pro"),
            arguments.Optional("audio-device", "Microphone (Game Capture HD60 Pro)")),
        _ => throw new ArgumentException($"Unknown command '{arguments.Command}'.")
    };

    string json = JsonSerializer.Serialize(output, JsonOptions.Default);
    string? outputPath = arguments.Optional("json", string.Empty);
    if (!string.IsNullOrWhiteSpace(outputPath))
    {
        string fullOutputPath = Path.GetFullPath(outputPath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullOutputPath)!);
        await File.WriteAllTextAsync(fullOutputPath, json + Environment.NewLine);
    }
    Console.WriteLine(json);
    _ = manifest;
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine($"VitaLab.Capture: {exception.Message}");
    return 1;
}
