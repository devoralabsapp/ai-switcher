namespace AISwitcher.Core;

public static class BrowserSignIn
{
    public const string AntigravityURLPrefix = "ANTIGRAVITY_OPEN_URL: ";
    public const string AntigravityBrowserHost = "ANTIGRAVITY_VSCODE_HOST";

    public static Uri? AntigravityURL(string line)
    {
        if (!line.StartsWith(AntigravityURLPrefix, StringComparison.Ordinal)) return null;
        var value = line[AntigravityURLPrefix.Length..].Trim();
        if (value.Length > 16384 || !Uri.TryCreate(value, UriKind.Absolute, out var url)
            || url.Scheme != "https" || url.Host != "accounts.google.com"
            || url.UserInfo.Length != 0 || !url.IsDefaultPort)
            throw new AppError(ProviderQuota.Invalid);
        string? Parameter(string name) => url.Query.TrimStart('?').Split('&')
            .Where(part => part.StartsWith(name + "=", StringComparison.Ordinal))
            .Select(part => Uri.UnescapeDataString(part[(name.Length + 1)..])).FirstOrDefault();
        if (string.IsNullOrEmpty(Parameter("state")) || !Uri.TryCreate(Parameter("redirect_uri"), UriKind.Absolute, out var callback)
            || callback.Scheme != "http" || callback.Host is not ("127.0.0.1" or "localhost" or "[::1]")
            || callback.UserInfo.Length != 0 || callback.Port is < 1024 or > 65535)
            throw new AppError(ProviderQuota.Invalid);
        return url;
    }
}
