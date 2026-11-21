using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace MCHarbor.Windows;

public sealed partial class MainWindow
{
    private static readonly (string Page, string Label, string Glyph)[] SidebarPages =
    [
        ("games", "游戏", "\uF4A1"),
        ("downloads", "下载", "\uF151"),
        ("modfolders", "模组夹", "\uF419"),
        ("accounts", "账号", "\uF5BE"),
        ("multiplayer", "联机", "\uF47B"),
        ("friends", "好友", "\uF5A9"),
        ("settings", "设置", "\uF6AA")
    ];
    private static readonly FontFamily NavigationIcons =
        new("ms-appx:///Assets/Fonts/FluentSystemIcons-Regular.ttf#FluentSystemIcons-Regular");

    private void InitializeSidebar()
    {
        var style = (Style)RootShell.Resources["HarborNavigationRow"];
        foreach (var (page, label, glyph) in SidebarPages)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new FontIcon
            {
                Glyph = glyph, FontFamily = NavigationIcons, FontSize = 16,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            });
            var text = new TextBlock
            {
                Text = label, FontSize = 13, VerticalAlignment = VerticalAlignment.Center
            };
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            if (page == "games")
            {
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                LibraryGameCount = new TextBlock
                {
                    FontSize = 10, Opacity = 0.7,
                    VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed
                };
                Grid.SetColumn(LibraryGameCount, 2);
                row.Children.Add(LibraryGameCount);
            }

            var button = new Button { Content = row, Tag = page, Style = style };
            AutomationProperties.SetName(button, label);
            button.Click += (_, _) => NavigateTo(page);
            SidebarItems.Children.Add(button);
        }
    }

    private TextBlock LibraryGameCount = null!;

    private void Sidebar_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        var current = SidebarItems.Children.OfType<Button>().ToList();
        var index = current.FindIndex(button => button.FocusState != FocusState.Unfocused);
        if (index < 0) return;
        var next = e.Key switch
        {
            VirtualKey.Up => Math.Max(0, index - 1),
            VirtualKey.Down => Math.Min(current.Count - 1, index + 1),
            VirtualKey.Home => 0,
            VirtualKey.End => current.Count - 1,
            _ => -1
        };
        if (next < 0) return;
        current[next].Focus(FocusState.Keyboard);
        e.Handled = true;
    }

    private void UpdateNavigationSelection()
    {
        UpdateTabSelection(SidebarItems, IsInstancePage(_lastNavigationTag) ? "games" : _lastNavigationTag);
    }
}
