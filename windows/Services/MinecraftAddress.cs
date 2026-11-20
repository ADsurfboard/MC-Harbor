using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace MCHarbor.Windows.Services;

internal static class MinecraftAddress
{
    public static string Parse(string address)
    {
        var value = address.Trim();
        if (value.Length is 0 or > 260 || value.Any(ch => char.IsWhiteSpace(ch) || char.IsControl(ch)
            || ch is '/' or '\\' or '@' or '?' or '#' or '%'))
            throw new FormatException("请输入服务器地址，例如 play.example.com:25565。");

        string host, portText;
        if (value.StartsWith('['))
        {
            var end = value.IndexOf(']');
            if (end < 2 || !IPAddress.TryParse(value[1..end], out var ip) || ip.AddressFamily != AddressFamily.InterNetworkV6)
                throw new FormatException("IPv6 地址应写为 [地址]:端口。");
            host = $"[{ip}]";
            var suffix = value[(end + 1)..];
            if (suffix.Length > 0 && !suffix.StartsWith(':')) throw new FormatException("IPv6 端口格式无效。");
            portText = suffix.Length == 0 ? "" : suffix[1..];
            if (suffix == ":") throw new FormatException("请输入端口号。");
        }
        else
        {
            var colon = value.IndexOf(':');
            host = colon < 0 ? value : value[..colon];
            portText = colon < 0 ? "" : value[(colon + 1)..];
            if (host.Length == 0 || host.Contains("..") || host.StartsWith('.') || host.EndsWith('.')
                || !host.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '.' or '-')
                || host.Split('.').Any(part => part.Length > 63 || part.StartsWith('-') || part.EndsWith('-')))
                throw new FormatException("服务器域名或 IP 格式无效。");
            if (colon >= 0 && portText.Length == 0) throw new FormatException("请输入端口号。");
        }
        if (portText.Length == 0) return host;
        if (!int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535)
            throw new FormatException("端口应为 1–65535。IPv6 请使用方括号。");
        return $"{host}:{port}";
    }

    public static bool HasQuickPlay(string version)
    {
        if (!Version.TryParse(version, out var number)) return true;
        return number.Major > 1 || number.Major == 1 && number.Minor >= 20;
    }
}
