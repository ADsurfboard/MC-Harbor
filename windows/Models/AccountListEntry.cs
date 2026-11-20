using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace MCHarbor.Windows.Models;

public sealed class AccountListEntry(StoredAccount account, bool selected, ImageSource? avatar) : INotifyPropertyChanged
{
    private ImageSource? _avatar = avatar;

    public StoredAccount Account { get; } = account;
    public string Name => Account.Name;
    public string KindLabel => Account.KindLabel;
    public Visibility SelectedVisibility => selected ? Visibility.Visible : Visibility.Collapsed;
    public ImageSource? Avatar
    {
        get => _avatar;
        set
        {
            if (ReferenceEquals(_avatar, value)) return;
            _avatar = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Avatar)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}
