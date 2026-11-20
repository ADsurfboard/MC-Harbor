namespace MCHarbor.Windows.Models;

public sealed record StoredAccount(
    string Id,
    string Name,
    string Uuid,
    string Kind,
    bool RequiresReauth)
{
    public string Status => RequiresReauth ? "需要重新登录" : "可用";
    public string KindLabel => Kind switch
    {
        "microsoft" => "Microsoft",
        "offline" => "离线账号",
        "external" => "第三方认证",
        _ => Kind
    };
}
