using System.Globalization;

namespace VitaLab.Capture;

sealed class ProgressParser
{
    private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);

    public ProgressSample? AddLine(string line, DateTimeOffset observedAtUtc, double monotonicSeconds)
    {
        int separator = line.IndexOf('=');
        if (separator <= 0)
        {
            return null;
        }

        string key = line[..separator];
        string value = line[(separator + 1)..];
        values[key] = value;
        if (!key.Equals("progress", StringComparison.Ordinal))
        {
            return null;
        }

        var snapshot = new Dictionary<string, string>(values, StringComparer.Ordinal);
        values.Clear();
        return new ProgressSample(
            observedAtUtc,
            monotonicSeconds,
            ParseLong(snapshot, "frame"),
            ParseLong(snapshot, "out_time_us"),
            snapshot.GetValueOrDefault("out_time"),
            value,
            snapshot);
    }

    private static long? ParseLong(IReadOnlyDictionary<string, string> source, string key) =>
        source.TryGetValue(key, out string? value) &&
        long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out long parsed)
            ? parsed
            : null;
}
