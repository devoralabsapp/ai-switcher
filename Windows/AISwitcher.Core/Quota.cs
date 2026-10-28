using System.Text.Json;

namespace AISwitcher.Core;
public sealed record Identity(string? Email, string? PlanType, string? AccountId = null) {
    public bool Matches(Identity other) => AccountId is { Length: >0 } ? AccountId == other.AccountId : !string.IsNullOrWhiteSpace(Email) && string.Equals(Email, other.Email, StringComparison.OrdinalIgnoreCase);
}
public sealed record QuotaWindow(double? UsedPercent, int? WindowDurationMins, long? ResetsAt, double? RemainingAmount = null) {
    public double? Remaining => UsedPercent is double x && double.IsFinite(x) ? Math.Clamp(100 - x, 0, 100) : null;
    public DateTimeOffset? Reset => ResetsAt is long value && value is >= -62135596800 and <= 253402300799 ? DateTimeOffset.FromUnixTimeSeconds(value) : null;
    public bool Expired(DateTimeOffset now) => Reset.HasValue && Reset <= now;
    public string Duration(Localizer l) => WindowDurationMins switch { 10080 => l["Week"], >0 and var mins when mins % 1440 == 0 => l.Format(mins == 1440 ? "%@ day" : "%@ days", mins/1440), >0 and var mins when mins%60 == 0 => l.Format(mins == 60 ? "%@ hour" : "%@ hours", mins/60), >0 and var mins => l.Format(mins == 1 ? "%@ minute" : "%@ minutes", mins), _ => l["Quota window"] };
}
public sealed record Bucket(string? LimitId, string? LimitName, QuotaWindow? Primary, QuotaWindow? Secondary, string? PlanType = null);
public sealed record Limits(string? AccountId, Bucket? RateLimits, Dictionary<string, Bucket>? RateLimitsByLimitId) {
    public IEnumerable<KeyValuePair<string, Bucket>> Buckets => RateLimitsByLimitId is { Count: >0 } ? RateLimitsByLimitId.OrderBy(x => x.Key == "codex" ? 0 : 1).ThenBy(x => x.Key) : RateLimits != null ? [new(RateLimits.LimitId ?? "codex", RateLimits)] : [];
}
public sealed record QuotaSnapshot(Limits Limits, DateTimeOffset FetchedAt) {
    public bool IsStale(DateTimeOffset now) => now - FetchedAt > TimeSpan.FromMinutes(6) || Limits.Buckets.Any(x => new[] { x.Value.Primary, x.Value.Secondary }.Any(w => w?.Expired(now) == true));
}
public sealed record Connection(Identity Identity, QuotaSnapshot? Quota = null);
public static class QuotaOverview {
    public static IEnumerable<Account> Sort(IEnumerable<Account> accounts, Preferences prefs, ISet<Guid>? failed = null, DateTimeOffset? time = null) {
        var now = time ?? DateTimeOffset.UtcNow;
        double? Value(Account a) {
            var quota = a.Connection?.Quota;
            var bucket = quota?.Limits.Buckets.FirstOrDefault().Value;
            if (prefs.QuotaSortKey == SortKey.LastUpdated) return quota?.FetchedAt.ToUnixTimeMilliseconds();
            if (quota == null || quota.IsStale(now) || failed?.Contains(a.Id) == true) return null;
            return prefs.QuotaSortKey switch { SortKey.PrimaryRemaining => bucket?.Primary?.Expired(now) != true ? bucket?.Primary?.Remaining : null, SortKey.SecondaryRemaining => bucket?.Secondary?.Expired(now) != true ? bucket?.Secondary?.Remaining : null, SortKey.NextReset => new[]{bucket?.Primary?.Reset,bucket?.Secondary?.Reset}.Where(x=>x>now).Select(x=>(double?)x?.ToUnixTimeMilliseconds()).Min(), _=>null };
        }
        var comparer = StringComparer.CurrentCultureIgnoreCase;
        if (prefs.QuotaSortKey == SortKey.Name) return prefs.QuotaSortAscending ? accounts.OrderBy(x=>x.Name,comparer).ThenBy(x=>x.Id) : accounts.OrderByDescending(x=>x.Name,comparer).ThenBy(x=>x.Id);
        return accounts.OrderBy(a => Value(a) == null ? 1 : 0).ThenBy(a => (prefs.QuotaSortAscending ? 1 : -1)*(Value(a) ?? 0)).ThenBy(x=>x.Name,comparer).ThenBy(x=>x.Id);
    }
}
public sealed record QuotaAlert(string Window, bool Recovered, double Remaining);
public static class AlertTracker {
    public static IReadOnlyList<QuotaAlert> Evaluate(Account account, Preferences prefs, DateTimeOffset now) {
        var connection=account.Connection; var quota=connection?.Quota;
        if (!prefs.AlertsEnabled || connection == null || quota == null || quota.IsStale(now)) return [];
        var identity=connection.Identity.AccountId ?? connection.Identity.Email?.ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(identity)) return [];
        List<QuotaAlert> result=[];
        foreach(var bucket in quota.Limits.Buckets) {
            foreach(var (slot, window) in new[]{("primary",bucket.Value.Primary),("secondary",bucket.Value.Secondary)}) {
                if(window?.Remaining is not double remaining || window.Expired(now)) continue;
                var key=$"{account.Id}|{account.EffectiveMode}|{identity}|{bucket.Key}|{slot}|{window.WindowDurationMins}";
                var low=remaining<=prefs.AlertThreshold;
                var had=prefs.AlertObservations.TryGetValue(key,out var wasLow);
                if(low && (!had || !wasLow)) result.Add(new(slot,false,remaining));
                if(!low && had && wasLow && prefs.AlertRecovery) result.Add(new(slot,true,remaining));
                prefs.AlertObservations[key]=low;
            }
        }
        return result;
    }
}
