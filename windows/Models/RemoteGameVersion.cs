namespace MCHarbor.Windows.Models;

public sealed record RemoteGameVersion(string Id, string Version, string Type, string ReleaseTime)
{
    public string ReleaseDate => ReleaseTime.Length >= 10 ? ReleaseTime[..10] : ReleaseTime;
}
