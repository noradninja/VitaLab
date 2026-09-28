using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;

// Vita core-note record layouts are documented by the LGPL-3.0-or-later
// vita-core-dump project: https://github.com/bgK/vita-core-dump

try
{
    Dictionary<string, string> options = ParseOptions(args);
    string dumpPath = RequiredPath(options, "dump");
    string elfPath = RequiredPath(options, "elf");
    string addr2LinePath = RequiredPath(options, "addr2line");
    string textPath = RequiredOption(options, "text");
    string jsonPath = RequiredOption(options, "json");
    int maxStackWords = options.TryGetValue("max-stack-words", out string? value)
        ? int.Parse(value)
        : 1024;
    if (maxStackWords is < 1 or > 65536)
        throw new ArgumentException("--max-stack-words must be between 1 and 65536.");

    byte[] coreBytes = ReadPossiblyCompressed(dumpPath);
    Elf32 coreElf = Elf32.Parse(coreBytes, requireCore: true);
    CoreDump core = CoreDump.Parse(coreBytes, coreElf);
    Elf32 targetElf = Elf32.Parse(File.ReadAllBytes(elfPath), requireCore: false);
    ProgramHeader targetText = targetElf.ProgramHeaders
        .Where(header => header.Type == ElfConstants.PtLoad && (header.Flags & ElfConstants.PfExecute) != 0)
        .OrderBy(header => header.VirtualAddress)
        .FirstOrDefault()
        ?? throw new InvalidDataException("The target ELF has no executable PT_LOAD segment.");

    CoreThread thread = core.Threads.FirstOrDefault(item => item.StopReason != 0)
        ?? core.Threads.FirstOrDefault()
        ?? throw new InvalidDataException("The dump contains no threads.");
    CoreRegisters registers = core.Registers.FirstOrDefault(item => item.ThreadId == thread.Uid)
        ?? throw new InvalidDataException($"The dump has no registers for thread 0x{thread.Uid:x8}.");

    CoreModule targetModule = SelectTargetModule(core.Modules, registers.Pc, targetText, options.GetValueOrDefault("module"));
    CoreSegment targetRuntimeText = SelectRuntimeTextSegment(targetModule, registers.Pc, targetText);
    List<uint> rawAddresses = new() { registers.Pc, registers.Lr };
    List<StackCandidate> candidates = ScanStack(core, registers.Sp, targetRuntimeText, maxStackWords);
    rawAddresses.AddRange(candidates.Select(candidate => candidate.Address));

    Dictionary<uint, SymbolRecord> symbols = SymbolizeAddresses(
        rawAddresses.Distinct(), targetRuntimeText.Start, targetText.VirtualAddress,
        elfPath, addr2LinePath);

    AddressRecord pc = CreateAddressRecord(registers.Pc, targetModule, targetRuntimeText, targetText, symbols);
    AddressRecord lr = CreateAddressRecord(registers.Lr, targetModule, targetRuntimeText, targetText, symbols);
    List<StackRecord> stack = candidates.Select(candidate => new StackRecord(
        candidate.StackAddress,
        CreateAddressRecord(candidate.Address, targetModule, targetRuntimeText, targetText, symbols)))
        .ToList();

    Analysis analysis = new(
        SchemaVersion: 1,
        DumpFile: Path.GetFileName(dumpPath),
        TargetElfFile: Path.GetFileName(elfPath),
        Thread: new ThreadRecord(thread.Uid, thread.Name, thread.Status, thread.StopReason),
        Registers: new RegisterRecord(registers.GeneralPurpose, registers.Ifsr, registers.Ifar, registers.Dfsr, registers.Dfar),
        TargetModule: new ModuleRecord(targetModule.Name, targetRuntimeText.Start, targetRuntimeText.Size, targetText.VirtualAddress),
        ProgramCounter: pc,
        LinkRegister: lr,
        StackCandidates: stack,
        Modules: core.Modules.Select(module => new ModuleSummary(
            module.Name,
            module.Segments.Select(segment => new SegmentSummary(segment.Attributes, segment.Start, segment.Size)).ToList())).ToList());

    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(textPath))!);
    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(jsonPath))!);
    File.WriteAllText(textPath, FormatText(analysis), new UTF8Encoding(false));
    File.WriteAllText(jsonPath, JsonSerializer.Serialize(analysis, new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));

    Console.WriteLine($"Symbolized PC 0x{registers.Pc:x8} for thread {thread.Name}.");
    Console.WriteLine($"Target module: {targetModule.Name} at 0x{targetRuntimeText.Start:x8}.");
    Console.WriteLine($"Stack candidates: {stack.Count}.");
    Console.WriteLine($"Text: {Path.GetFullPath(textPath)}");
    Console.WriteLine($"JSON: {Path.GetFullPath(jsonPath)}");
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine($"VitaLab symbolization failed: {exception.Message}");
    return 1;
}

static Dictionary<string, string> ParseOptions(string[] arguments)
{
    Dictionary<string, string> result = new(StringComparer.OrdinalIgnoreCase);
    for (int index = 0; index < arguments.Length; index++)
    {
        string current = arguments[index];
        if (!current.StartsWith("--", StringComparison.Ordinal) || index + 1 >= arguments.Length)
            throw new ArgumentException("Arguments must use --name value pairs.");
        result[current[2..]] = arguments[++index];
    }
    return result;
}

static string RequiredOption(Dictionary<string, string> options, string name) =>
    options.TryGetValue(name, out string? value) && !string.IsNullOrWhiteSpace(value)
        ? value
        : throw new ArgumentException($"Missing --{name}.");

static string RequiredPath(Dictionary<string, string> options, string name)
{
    string path = Path.GetFullPath(RequiredOption(options, name));
    return File.Exists(path) ? path : throw new FileNotFoundException($"--{name} does not exist.", path);
}

static byte[] ReadPossiblyCompressed(string path)
{
    byte[] input = File.ReadAllBytes(path);
    if (input.Length < 2 || input[0] != 0x1f || input[1] != 0x8b)
        return input;
    using MemoryStream source = new(input);
    using GZipStream gzip = new(source, CompressionMode.Decompress);
    using MemoryStream output = new();
    gzip.CopyTo(output);
    return output.ToArray();
}

static CoreModule SelectTargetModule(IReadOnlyList<CoreModule> modules, uint pc, ProgramHeader targetText, string? requestedName)
{
    if (!string.IsNullOrWhiteSpace(requestedName))
        return modules.SingleOrDefault(module => string.Equals(module.Name, requestedName, StringComparison.Ordinal))
            ?? throw new InvalidDataException($"The dump has no module named '{requestedName}'.");

    CoreModule? containingPc = modules.FirstOrDefault(module =>
        !module.Name.StartsWith("Sce", StringComparison.Ordinal) && module.Segments.Any(segment => segment.Contains(pc)));
    if (containingPc is not null)
        return containingPc;

    CoreModule? sizeMatch = modules
        .Where(module => !module.Name.StartsWith("Sce", StringComparison.Ordinal))
        .Select(module => new
        {
            Module = module,
            Difference = module.Segments.Count == 0
                ? long.MaxValue
                : module.Segments.Min(segment => Math.Abs((long)segment.Size - targetText.MemorySize))
        })
        .OrderBy(item => item.Difference)
        .Select(item => item.Module)
        .FirstOrDefault();
    return sizeMatch ?? throw new InvalidDataException("Unable to identify the target application module.");
}

static CoreSegment SelectRuntimeTextSegment(CoreModule module, uint pc, ProgramHeader targetText)
{
    CoreSegment? containingPc = module.Segments.FirstOrDefault(segment => segment.Contains(pc));
    if (containingPc is not null)
        return containingPc;
    return module.Segments.OrderBy(segment => Math.Abs((long)segment.Size - targetText.MemorySize)).FirstOrDefault()
        ?? throw new InvalidDataException($"Module {module.Name} has no segments.");
}

static List<StackCandidate> ScanStack(CoreDump core, uint stackPointer, CoreSegment targetText, int maxWords)
{
    List<StackCandidate> result = new();
    HashSet<uint> seen = new();
    for (int index = 0; index < maxWords; index++)
    {
        uint stackAddress = checked(stackPointer + (uint)(index * 4));
        if (!core.TryReadUInt32(stackAddress, out uint value))
            break;
        uint normalized = value & 0xfffffffeu;
        if (targetText.Contains(normalized) && seen.Add(normalized))
            result.Add(new StackCandidate(stackAddress, normalized));
    }
    return result;
}

static Dictionary<uint, SymbolRecord> SymbolizeAddresses(
    IEnumerable<uint> runtimeAddresses,
    uint runtimeBase,
    uint elfBase,
    string elfPath,
    string addr2LinePath)
{
    Dictionary<uint, SymbolRecord> result = new();
    foreach (uint runtimeAddress in runtimeAddresses)
    {
        uint normalized = runtimeAddress & 0xfffffffeu;
        if (normalized < runtimeBase)
            continue;
        uint elfAddress = checked(elfBase + (normalized - runtimeBase));
        ProcessStartInfo startInfo = new(addr2LinePath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("-a");
        startInfo.ArgumentList.Add("-f");
        startInfo.ArgumentList.Add("-C");
        startInfo.ArgumentList.Add("-e");
        startInfo.ArgumentList.Add(elfPath);
        startInfo.ArgumentList.Add($"0x{elfAddress:x8}");
        using Process process = Process.Start(startInfo) ?? throw new InvalidOperationException("Unable to start addr2line.");
        string output = process.StandardOutput.ReadToEnd();
        string error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"addr2line failed for 0x{elfAddress:x8}: {error.Trim()}");
        string[] lines = output.Replace("\r", string.Empty).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        string function = lines.Length >= 2 ? lines[^2].Trim() : "??";
        string location = lines.Length >= 1 ? lines[^1].Trim() : "??:0";
        result[normalized] = new SymbolRecord(elfAddress, function, location);
    }
    return result;
}

static AddressRecord CreateAddressRecord(
    uint runtimeAddress,
    CoreModule module,
    CoreSegment runtimeText,
    ProgramHeader elfText,
    IReadOnlyDictionary<uint, SymbolRecord> symbols)
{
    uint normalized = runtimeAddress & 0xfffffffeu;
    bool inTarget = runtimeText.Contains(normalized);
    symbols.TryGetValue(normalized, out SymbolRecord? symbol);
    return new AddressRecord(runtimeAddress, inTarget ? module.Name : null,
        inTarget ? normalized - runtimeText.Start : null,
        inTarget ? elfText.VirtualAddress + (normalized - runtimeText.Start) : null,
        symbol?.Function, symbol?.Location);
}

static string FormatText(Analysis analysis)
{
    StringBuilder text = new();
    text.AppendLine("VitaLab local core-dump symbolization");
    text.AppendLine($"Dump: {analysis.DumpFile}");
    text.AppendLine($"Target ELF: {analysis.TargetElfFile}");
    text.AppendLine($"Thread: {analysis.Thread.Name} (0x{analysis.Thread.Uid:x8})");
    text.AppendLine($"Stop reason: 0x{analysis.Thread.StopReason:x8}");
    text.AppendLine($"Target module: {analysis.TargetModule.Name}");
    text.AppendLine($"Runtime text base: 0x{analysis.TargetModule.RuntimeTextBase:x8}");
    text.AppendLine($"ELF text base: 0x{analysis.TargetModule.ElfTextBase:x8}");
    text.AppendLine();
    AppendAddress(text, "PC", analysis.ProgramCounter);
    AppendAddress(text, "LR", analysis.LinkRegister);
    text.AppendLine($"SP: 0x{analysis.Registers.GeneralPurpose[13]:x8}");
    text.AppendLine($"DFSR/DFAR: 0x{analysis.Registers.Dfsr:x8} / 0x{analysis.Registers.Dfar:x8}");
    text.AppendLine($"IFSR/IFAR: 0x{analysis.Registers.Ifsr:x8} / 0x{analysis.Registers.Ifar:x8}");
    text.AppendLine();
    text.AppendLine("Heuristic target-code addresses found on the crashed thread stack:");
    if (analysis.StackCandidates.Count == 0)
        text.AppendLine("  none");
    foreach (StackRecord record in analysis.StackCandidates)
    {
        text.Append($"  [0x{record.StackAddress:x8}] ");
        AppendAddress(text, null, record.Address);
    }
    text.AppendLine();
    text.AppendLine("Note: stack candidates are not a proven call stack; this build lacks sufficient unwind metadata.");
    return text.ToString();
}

static void AppendAddress(StringBuilder text, string? label, AddressRecord address)
{
    if (label is not null)
        text.Append($"{label}: ");
    text.Append($"0x{address.RuntimeAddress:x8}");
    if (address.Module is not null)
        text.Append($" {address.Module}+0x{address.ModuleOffset:x}");
    if (!string.IsNullOrWhiteSpace(address.Function) && address.Function != "??")
        text.Append($" {address.Function}");
    if (!string.IsNullOrWhiteSpace(address.Location) && address.Location != "??:0")
        text.Append($" at {address.Location}");
    text.AppendLine();
}

sealed class Elf32
{
    public required IReadOnlyList<ProgramHeader> ProgramHeaders { get; init; }

    public static Elf32 Parse(byte[] data, bool requireCore)
    {
        if (data.Length < 52 || data[0] != 0x7f || data[1] != (byte)'E' || data[2] != (byte)'L' || data[3] != (byte)'F')
            throw new InvalidDataException("Input is not an ELF file.");
        if (data[4] != 1 || data[5] != 1)
            throw new InvalidDataException("Only little-endian ELF32 files are supported.");
        ushort type = ReadU16(data, 16);
        if (requireCore && type != 4)
            throw new InvalidDataException("The dump ELF is not ET_CORE.");
        uint programOffset = ReadU32(data, 28);
        ushort entrySize = ReadU16(data, 42);
        ushort count = ReadU16(data, 44);
        if (entrySize < 32)
            throw new InvalidDataException("Invalid ELF program-header size.");
        List<ProgramHeader> headers = new(count);
        for (int index = 0; index < count; index++)
        {
            int offset = checked((int)programOffset + index * entrySize);
            RequireRange(data, offset, 32);
            headers.Add(new ProgramHeader(
                ReadU32(data, offset), ReadU32(data, offset + 4), ReadU32(data, offset + 8),
                ReadU32(data, offset + 16), ReadU32(data, offset + 20), ReadU32(data, offset + 24),
                ReadU32(data, offset + 28)));
        }
        return new Elf32 { ProgramHeaders = headers };
    }

    public static ushort ReadU16(byte[] data, int offset)
    {
        RequireRange(data, offset, 2);
        return (ushort)(data[offset] | data[offset + 1] << 8);
    }

    public static uint ReadU32(byte[] data, int offset)
    {
        RequireRange(data, offset, 4);
        return (uint)(data[offset] | data[offset + 1] << 8 | data[offset + 2] << 16 | data[offset + 3] << 24);
    }

    public static string ReadName(byte[] data, int offset, int length)
    {
        RequireRange(data, offset, length);
        int count = Array.IndexOf(data, (byte)0, offset, length);
        if (count < 0)
            count = offset + length;
        return Encoding.ASCII.GetString(data, offset, count - offset);
    }

    public static void RequireRange(byte[] data, int offset, int length)
    {
        if (offset < 0 || length < 0 || offset > data.Length - length)
            throw new InvalidDataException("ELF structure extends beyond the file.");
    }
}

sealed class CoreDump
{
    public required byte[] Data { get; init; }
    public required IReadOnlyList<ProgramHeader> Loads { get; init; }
    public required List<CoreModule> Modules { get; init; }
    public required List<CoreThread> Threads { get; init; }
    public required List<CoreRegisters> Registers { get; init; }

    public static CoreDump Parse(byte[] data, Elf32 elf)
    {
        List<CoreModule> modules = new();
        List<CoreThread> threads = new();
        List<CoreRegisters> registers = new();
        foreach (ProgramHeader header in elf.ProgramHeaders.Where(item => item.Type == ElfConstants.PtNote))
        {
            int cursor = checked((int)header.Offset);
            int end = checked(cursor + (int)header.FileSize);
            while (cursor < end)
            {
                Elf32.RequireRange(data, cursor, 12);
                uint nameSize = Elf32.ReadU32(data, cursor);
                uint descriptionSize = Elf32.ReadU32(data, cursor + 4);
                cursor += 12;
                int nameOffset = cursor;
                cursor = Align4(checked(cursor + (int)nameSize));
                int descriptionOffset = cursor;
                cursor = Align4(checked(cursor + (int)descriptionSize));
                if (cursor > end)
                    throw new InvalidDataException("ELF note extends beyond its segment.");
                string name = Elf32.ReadName(data, nameOffset, checked((int)nameSize));
                switch (name)
                {
                    case "MODULE_INFO": modules.AddRange(ParseModules(data, descriptionOffset, checked((int)descriptionSize))); break;
                    case "THREAD_INFO": threads.AddRange(ParseThreads(data, descriptionOffset, checked((int)descriptionSize))); break;
                    case "THREAD_REG_INFO": registers.AddRange(ParseRegisters(data, descriptionOffset, checked((int)descriptionSize))); break;
                }
            }
        }
        return new CoreDump
        {
            Data = data,
            Loads = elf.ProgramHeaders.Where(item => item.Type == ElfConstants.PtLoad).ToList(),
            Modules = modules,
            Threads = threads,
            Registers = registers
        };
    }

    public bool TryReadUInt32(uint address, out uint value)
    {
        ProgramHeader? load = Loads.FirstOrDefault(header =>
            address >= header.VirtualAddress && (ulong)address + 4 <= (ulong)header.VirtualAddress + header.FileSize);
        if (load is null)
        {
            value = 0;
            return false;
        }
        int offset = checked((int)(load.Offset + address - load.VirtualAddress));
        value = Elf32.ReadU32(Data, offset);
        return true;
    }

    static List<CoreModule> ParseModules(byte[] data, int offset, int length)
    {
        int end = checked(offset + length);
        RequireVersionAndCount(data, ref offset, end, 1, out uint count);
        List<CoreModule> result = new(checked((int)count));
        for (uint index = 0; index < count; index++)
        {
            Elf32.RequireRange(data, offset, 80);
            string name = Elf32.ReadName(data, offset + 36, 32);
            uint segmentCount = Elf32.ReadU32(data, offset + 76);
            uint uid = Elf32.ReadU32(data, offset + 4);
            offset += 80;
            List<CoreSegment> segments = new(checked((int)segmentCount));
            for (uint segmentIndex = 0; segmentIndex < segmentCount; segmentIndex++)
            {
                Elf32.RequireRange(data, offset, 20);
                segments.Add(new CoreSegment(Elf32.ReadU32(data, offset + 4), Elf32.ReadU32(data, offset + 8), Elf32.ReadU32(data, offset + 12)));
                offset += 20;
            }
            Elf32.RequireRange(data, offset, 16);
            offset += 16;
            result.Add(new CoreModule(uid, name, segments));
        }
        if (offset > end)
            throw new InvalidDataException("Invalid MODULE_INFO note.");
        return result;
    }

    static List<CoreThread> ParseThreads(byte[] data, int offset, int length)
    {
        int end = checked(offset + length);
        RequireVersionAndCount(data, ref offset, end, 18, out uint count);
        List<CoreThread> result = new(checked((int)count));
        for (uint index = 0; index < count; index++)
        {
            Elf32.RequireRange(data, offset, 200);
            uint size = Elf32.ReadU32(data, offset);
            if (size != 200)
                throw new InvalidDataException($"Unsupported THREAD_INFO record size {size}.");
            result.Add(new CoreThread(
                Elf32.ReadU32(data, offset + 4),
                Elf32.ReadName(data, offset + 8, 32),
                Elf32.ReadU16(data, offset + 48),
                Elf32.ReadU32(data, offset + 116),
                Elf32.ReadU32(data, offset + 156)));
            offset = checked(offset + (int)size);
        }
        if (offset > end)
            throw new InvalidDataException("Invalid THREAD_INFO note.");
        return result;
    }

    static List<CoreRegisters> ParseRegisters(byte[] data, int offset, int length)
    {
        int end = checked(offset + length);
        RequireVersionAndCount(data, ref offset, end, 17, out uint count);
        List<CoreRegisters> result = new(checked((int)count));
        for (uint index = 0; index < count; index++)
        {
            Elf32.RequireRange(data, offset, 376);
            uint size = Elf32.ReadU32(data, offset);
            if (size != 376)
                throw new InvalidDataException($"Unsupported THREAD_REG_INFO record size {size}.");
            uint[] gpr = new uint[16];
            for (int register = 0; register < gpr.Length; register++)
                gpr[register] = Elf32.ReadU32(data, offset + 8 + register * 4);
            result.Add(new CoreRegisters(
                Elf32.ReadU32(data, offset + 4), gpr,
                Elf32.ReadU32(data, offset + 360), Elf32.ReadU32(data, offset + 364),
                Elf32.ReadU32(data, offset + 368), Elf32.ReadU32(data, offset + 372)));
            offset = checked(offset + (int)size);
        }
        if (offset > end)
            throw new InvalidDataException("Invalid THREAD_REG_INFO note.");
        return result;
    }

    static void RequireVersionAndCount(byte[] data, ref int offset, int end, uint expectedVersion, out uint count)
    {
        if (offset > end - 8)
            throw new InvalidDataException("Truncated Vita core note.");
        uint version = Elf32.ReadU32(data, offset);
        count = Elf32.ReadU32(data, offset + 4);
        offset += 8;
        if (version != expectedVersion)
            throw new InvalidDataException($"Unsupported Vita core note version {version}; expected {expectedVersion}.");
    }

    static int Align4(int value) => checked((value + 3) & ~3);
}

sealed record ProgramHeader(uint Type, uint Offset, uint VirtualAddress, uint FileSize, uint MemorySize, uint Flags, uint Align);
sealed record CoreSegment(uint Attributes, uint Start, uint Size)
{
    public bool Contains(uint address) => address >= Start && (ulong)address < (ulong)Start + Size;
}
sealed record CoreModule(uint Uid, string Name, List<CoreSegment> Segments);
sealed record CoreThread(uint Uid, string Name, ushort Status, uint StopReason, uint Pc);
sealed record CoreRegisters(uint ThreadId, uint[] GeneralPurpose, uint Ifsr, uint Ifar, uint Dfsr, uint Dfar)
{
    public uint Sp => GeneralPurpose[13];
    public uint Lr => GeneralPurpose[14];
    public uint Pc => GeneralPurpose[15];
}
sealed record StackCandidate(uint StackAddress, uint Address);
sealed record SymbolRecord(uint ElfAddress, string Function, string Location);
sealed record ThreadRecord(uint Uid, string Name, ushort Status, uint StopReason);
sealed record RegisterRecord(uint[] GeneralPurpose, uint Ifsr, uint Ifar, uint Dfsr, uint Dfar);
sealed record ModuleRecord(string Name, uint RuntimeTextBase, uint RuntimeTextSize, uint ElfTextBase);
sealed record AddressRecord(uint RuntimeAddress, string? Module, uint? ModuleOffset, uint? ElfAddress, string? Function, string? Location);
sealed record StackRecord(uint StackAddress, AddressRecord Address);
sealed record SegmentSummary(uint Attributes, uint Start, uint Size);
sealed record ModuleSummary(string Name, List<SegmentSummary> Segments);
sealed record Analysis(
    int SchemaVersion,
    string DumpFile,
    string TargetElfFile,
    ThreadRecord Thread,
    RegisterRecord Registers,
    ModuleRecord TargetModule,
    AddressRecord ProgramCounter,
    AddressRecord LinkRegister,
    List<StackRecord> StackCandidates,
    List<ModuleSummary> Modules);

static class ElfConstants
{
    public const uint PtLoad = 1;
    public const uint PtNote = 4;
    public const uint PfExecute = 1;
}
