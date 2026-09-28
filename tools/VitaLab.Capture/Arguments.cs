namespace VitaLab.Capture;

sealed class Arguments
{
    private readonly Dictionary<string, string> values;

    private Arguments(string command, Dictionary<string, string> values)
    {
        Command = command;
        this.values = values;
    }

    public string Command { get; }

    public static Arguments Parse(string[] args)
    {
        if (args.Length == 0)
        {
            throw new ArgumentException("A command is required.");
        }

        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int index = 1; index < args.Length; index += 2)
        {
            if (index + 1 >= args.Length || !args[index].StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Expected --name value at argument {index + 1}.");
            }

            values.Add(args[index][2..], args[index + 1]);
        }

        return new Arguments(args[0].ToLowerInvariant(), values);
    }

    public string Require(string name) =>
        values.TryGetValue(name, out string? value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing required option --{name}.");

    public string Optional(string name, string defaultValue) =>
        values.TryGetValue(name, out string? value) ? value : defaultValue;

    public int OptionalInt(string name, int defaultValue, int minimum, int maximum)
    {
        if (!values.TryGetValue(name, out string? value))
        {
            return defaultValue;
        }
        if (!int.TryParse(value, out int parsed) || parsed < minimum || parsed > maximum)
        {
            throw new ArgumentException($"Option --{name} must be an integer from {minimum} through {maximum}.");
        }
        return parsed;
    }
}
