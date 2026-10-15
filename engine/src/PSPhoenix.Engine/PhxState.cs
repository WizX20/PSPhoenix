using System.Text.Encodings.Web;
using System.Text.Json;

namespace PSPhoenix.Engine;

/// <summary>A provider's last run: when it last succeeded (its start), and how the last attempt went.</summary>
/// <param name="LastRun">The start of the last run in which the provider succeeded, in UTC; none yet when it never did.</param>
/// <param name="LastResult"><c>ok</c>, or <c>failed: </c> and why.</param>
/// <param name="Withheld">
/// The files its last successful run held back because they hold a secret, each as
/// <c>&lt;file&gt; line &lt;n&gt;: &lt;kind&gt;</c> - never the secret itself.
/// </param>
public sealed record ProviderState(DateTime? LastRun, string? LastResult, IReadOnlyList<string>? Withheld = null);

/// <summary>The last run of <c>phx run</c>.</summary>
/// <param name="At">Its start, in UTC.</param>
/// <param name="Providers">The providers it ran.</param>
/// <param name="Failed">Those that failed - or <c>run</c>, when the run itself did.</param>
/// <param name="Log">Its log file.</param>
public sealed record RunRecord(DateTime At, IReadOnlyList<string> Providers, IReadOnlyList<string> Failed, string? Log);

/// <summary>
/// The state (docs/design.md -> Change detection and resource use): machine-local, never backed up,
/// and never needed for correctness - a missing or broken state only means "everything changed",
/// never an error. It holds the last run; per provider when it last ran; per provider and source
/// file its size, mtime and SHA-256 (two providers reading one file each keep their own view); per
/// published snapshot file the SHA-256 it was published with, and into which snapshot folder, so
/// publishing need not read the target back; and per repository a hash of its refs, for the wip
/// provider (M4).
/// </summary>
/// <remarks>
/// <c>state.json</c> is the JSON of this class, property names in camelCase, keys as they are.
/// Version 1 is also what PSPhoenix wrote before the state moved into the engine.
/// </remarks>
public sealed class PhxState
{
    /// <summary>The format this PSPhoenix reads and writes.</summary>
    public const int CurrentVersion = 1;

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        // Paths stay readable: the file is never embedded in HTML.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>The format of this state.</summary>
    public int Version { get; } = CurrentVersion;

    /// <summary>The last run; none yet.</summary>
    public RunRecord? LastRun { get; set; }

    /// <summary>Per provider, its last run.</summary>
    public Dictionary<string, ProviderState> Providers { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Per provider, the source files its last successful run saw, by full path.</summary>
    public Dictionary<string, Dictionary<string, FileStamp>> Files { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Per provider, its files in the snapshot (relative path) and the SHA-256 each was published with.</summary>
    public Dictionary<string, Dictionary<string, string>> Published { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The snapshot folder <see cref="Published"/> is of: another one (a new target, a renamed
    /// machine) starts without any.
    /// </summary>
    public string? PublishedTo { get; private set; }

    /// <summary>Per repository (its path), a hash of its refs.</summary>
    public Dictionary<string, string> Refs { get; } = PathComparison.NewDictionary<string>();

    /// <summary>The change detection for a provider's run, starting from what its last successful run saw.</summary>
    public FileTracker Tracker(string provider) => new(Files.GetValueOrDefault(provider));

    /// <summary>Per provider, what its last successful run staged (relative path -> record): the next run reuses what did not change.</summary>
    public Dictionary<string, Dictionary<string, StagedRecord>> Staged { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>What <paramref name="provider"/>'s last successful run staged; empty when none.</summary>
    public IReadOnlyDictionary<string, StagedRecord> StagedBy(string provider)
        => Staged.TryGetValue(provider, out Dictionary<string, StagedRecord>? records) ? records : new Dictionary<string, StagedRecord>(StringComparer.Ordinal);

    /// <summary>Keeps what <paramref name="provider"/> staged in a run that succeeded.</summary>
    public void KeepStaged(string provider, IReadOnlyDictionary<string, StagedRecord> records)
    {
        ArgumentNullException.ThrowIfNull(records);
        Staged[provider] = new Dictionary<string, StagedRecord>(records, StringComparer.Ordinal);
    }

    /// <summary>
    /// A provider succeeded in the run that started at <paramref name="started"/>: that is its last
    /// run now - the start, not the end, so a long run does not push its next turn past the slack of
    /// its cadence - and what it saw is what its next run compares with.
    /// </summary>
    public void Succeeded(string provider, DateTime started, FileTracker files, IEnumerable<string>? withheld = null)
    {
        ArgumentNullException.ThrowIfNull(files);
        Providers[provider] = new ProviderState(started.ToUniversalTime(), "ok", withheld?.ToArray() ?? []);
        Files[provider] = files.Seen;
    }

    /// <summary>
    /// A provider failed: its last run stays the last one it succeeded in - it is due again at once -
    /// and what its last successful run saw, and held back, stays as it was.
    /// </summary>
    public void Failed(string provider, string message)
    {
        ProviderState? last = Providers.GetValueOrDefault(provider);
        Providers[provider] = new ProviderState(last?.LastRun, $"failed: {message}", last?.Withheld ?? []);
    }

    /// <summary>
    /// Publishing goes into <paramref name="snapshot"/>: hashes published into another folder must
    /// not pass for what this one holds, so they are dropped.
    /// </summary>
    public void PublishInto(string snapshot)
    {
        if (!string.Equals(PublishedTo, snapshot, PathComparison.Comparison))
        {
            Published.Clear();
            PublishedTo = snapshot;
        }
    }

    /// <summary>A provider's published hashes, for <see cref="FolderPublisher.Publish(string, string, IDictionary{string, string}?)"/>.</summary>
    public Dictionary<string, string> PublishedHashes(string provider)
    {
        if (!Published.TryGetValue(provider, out Dictionary<string, string>? hashes))
        {
            hashes = PathComparison.NewDictionary<string>();
            Published[provider] = hashes;
        }
        return hashes;
    }

    /// <summary>The state in <paramref name="path"/>; a fresh one when there is no such file.</summary>
    /// <exception cref="InvalidDataException">The file is not a state this PSPhoenix wrote: broken, or of another version.</exception>
    public static PhxState Load(string path)
    {
        AtomicFile.RequireFullPath(path);
        if (!File.Exists(path))
        {
            return new PhxState();
        }
        Document? document;
        try
        {
            document = JsonSerializer.Deserialize<Document>(File.ReadAllText(path), Json);
        }
        catch (JsonException e)
        {
            throw new InvalidDataException($"not a state this PSPhoenix wrote ({e.Message})", e);
        }
        if (document is null || document.Version != CurrentVersion)
        {
            throw new InvalidDataException(document?.Version > CurrentVersion
                ? $"written by a newer PSPhoenix (version {document.Version})"
                : "not a state this PSPhoenix wrote");
        }
        return document.ToState();
    }

    /// <summary>Writes the state to <paramref name="path"/>, through a temporary file and a rename.</summary>
    public void Save(string path)
        => AtomicFile.WriteAllText(path, JsonSerializer.Serialize(Document.From(this), Json));

    /// <summary>A time as read: UTC, also when the file held a local or an unmarked one.</summary>
    private static DateTime Utc(DateTime value) => value.Kind switch
    {
        DateTimeKind.Local => value.ToUniversalTime(),
        DateTimeKind.Unspecified => DateTime.SpecifyKind(value, DateTimeKind.Utc),
        _ => value,
    };

    /// <summary>state.json as JSON reads and writes it; the dictionaries are copied into ones that compare as they should.</summary>
    private sealed class Document
    {
        public int Version { get; set; }

        public RunRecord? LastRun { get; set; }

        public Dictionary<string, ProviderState?>? Providers { get; set; }

        public Dictionary<string, Dictionary<string, FileStamp?>?>? Files { get; set; }

        public Dictionary<string, Dictionary<string, string?>?>? Published { get; set; }

        public string? PublishedTo { get; set; }

        public Dictionary<string, string?>? Refs { get; set; }

        public Dictionary<string, Dictionary<string, StagedRecord?>?>? Staged { get; set; }

        public static Document From(PhxState state) => new()
        {
            Version = CurrentVersion,
            LastRun = state.LastRun,
            Providers = state.Providers.ToDictionary(entry => entry.Key, entry => (ProviderState?)entry.Value),
            Files = state.Files.ToDictionary(entry => entry.Key, entry => (Dictionary<string, FileStamp?>?)entry.Value.ToDictionary(file => file.Key, file => (FileStamp?)file.Value)),
            Published = state.Published.ToDictionary(entry => entry.Key, entry => (Dictionary<string, string?>?)entry.Value.ToDictionary(file => file.Key, file => (string?)file.Value)),
            PublishedTo = state.PublishedTo,
            Refs = state.Refs.ToDictionary(entry => entry.Key, entry => (string?)entry.Value),
            Staged = state.Staged.ToDictionary(entry => entry.Key, entry => (Dictionary<string, StagedRecord?>?)entry.Value.ToDictionary(file => file.Key, file => (StagedRecord?)file.Value)),
        };

        public PhxState ToState()
        {
            PhxState state = new()
            {
                LastRun = LastRun is null ? null : LastRun with
                {
                    At = Utc(LastRun.At),
                    Providers = Names(LastRun.Providers),
                    Failed = Names(LastRun.Failed),
                },
                PublishedTo = PublishedTo,
            };
            foreach ((string name, ProviderState? provider) in Providers ?? [])
            {
                if (provider is not null)
                {
                    state.Providers[name] = provider with { LastRun = provider.LastRun is { } last ? Utc(last) : null, Withheld = Names(provider.Withheld) };
                }
            }
            foreach ((string name, Dictionary<string, FileStamp?>? files) in Files ?? [])
            {
                state.Files[name] = Copy(files);
            }
            foreach ((string name, Dictionary<string, string?>? hashes) in Published ?? [])
            {
                state.Published[name] = Copy(hashes);
            }
            foreach ((string name, Dictionary<string, StagedRecord?>? records) in Staged ?? [])
            {
                Dictionary<string, StagedRecord> kept = new(StringComparer.Ordinal);
                foreach ((string path, StagedRecord? record) in records ?? [])
                {
                    if (record is not null && record.Options is not null)
                    {
                        kept[path] = record with { Findings = record.Findings ?? [] };
                    }
                }
                state.Staged[name] = kept;
            }
            foreach ((string path, string? hash) in Refs ?? [])
            {
                if (hash is not null)
                {
                    state.Refs[path] = hash;
                }
            }
            return state;
        }

        /// <summary>
        /// A list of names without empty entries: the PowerShell version recorded a run in which
        /// nothing was due as <c>"providers":[null]</c>.
        /// </summary>
        private static string[] Names(IReadOnlyList<string?>? names)
            => names?.Where(name => !string.IsNullOrEmpty(name)).Select(name => name!).ToArray() ?? [];

        private static Dictionary<string, T> Copy<T>(Dictionary<string, T?>? source)
            where T : class
        {
            Dictionary<string, T> copy = PathComparison.NewDictionary<T>();
            foreach ((string key, T? value) in source ?? [])
            {
                if (value is not null)
                {
                    copy[key] = value;
                }
            }
            return copy;
        }
    }
}
