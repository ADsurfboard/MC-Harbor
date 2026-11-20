using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace MCHarbor.Windows.Services;

internal enum OnlineTranslator { Bilibili, Qwen, MyMemory, Google }

internal sealed partial class OnlineTranslationClient(OnlineTranslator provider, string? apiKey)
{
    private const string Bilibili = "https://index-translate.bilibili.com/v1/chat/completions";
    private const string Qwen = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions";
    private const string MyMemory = "https://api.mymemory.translated.net/get";
    private const string Google = "https://translate.googleapis.com/translate_a/single";

    public static string OriginName(OnlineTranslator service) => service switch
    {
        OnlineTranslator.Bilibili => "index-translate.bilibili.com",
        OnlineTranslator.Qwen => "dashscope.aliyuncs.com",
        OnlineTranslator.MyMemory => "api.mymemory.translated.net",
        _ => "translate.googleapis.com"
    };

    public async Task<string?[]> TranslateAsync(string[] texts, CancellationToken cancellation)
    {
        var output = new string?[texts.Length];
        for (var index = 0; index < texts.Length; index++)
        {
            cancellation.ThrowIfCancellationRequested();
            if (texts[index].Length is 0 or > 6000) continue;
            var phrases = SplitText(texts[index]).ToArray();
            var translated = new StringBuilder();
            foreach (var phrase in phrases)
            {
                if (!phrase.NeedsTranslation)
                {
                    translated.Append(phrase.Text);
                    continue;
                }
                foreach (var piece in SplitUtf8(phrase.Text, provider == OnlineTranslator.MyMemory ? 450 : 2700))
                {
                    if (!EnglishPattern().IsMatch(piece))
                    {
                        translated.Append(piece);
                        continue;
                    }
                    var value = await RequestAsync(piece.Trim(), cancellation);
                    translated.Append(piece[..(piece.Length - piece.TrimStart().Length)]);
                    translated.Append(value);
                    translated.Append(piece[piece.TrimEnd().Length..]);
                }
            }
            var result = translated.ToString();
            if (ChinesePattern().IsMatch(result) && !result.Equals(texts[index], StringComparison.OrdinalIgnoreCase))
                output[index] = result;
        }
        return output;
    }

    private async Task<string> RequestAsync(string source, CancellationToken cancellation)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                var (uri, method, body) = provider switch
                {
                    OnlineTranslator.Bilibili => (new Uri(Bilibili), HttpMethod.Post, (object?)new
                    {
                        model = "Index-Translate-35B-A3B", stream = false, max_tokens = 2048,
                        chat_template_kwargs = new { enable_thinking = false },
                        messages = new[] { new { role = "user", content = "Translate this Minecraft text to Simplified Chinese. Return only the translation.\n\n" + source } }
                    }),
                    OnlineTranslator.Qwen => (new Uri(Qwen), HttpMethod.Post, (object?)new
                    {
                        model = "qwen-mt-plus", messages = new[] { new { role = "user", content = source } },
                        translation_options = new { source_lang = "English", target_lang = "Chinese" }
                    }),
                    OnlineTranslator.MyMemory => (new Uri(MyMemory + "?langpair=en%7Czh-CN&q=" + Uri.EscapeDataString(source)), HttpMethod.Get, null),
                    _ => (new Uri(Google + "?client=gtx&sl=en&tl=zh-CN&dt=t&q=" + Uri.EscapeDataString(source)), HttpMethod.Get, null)
                };
                var bytes = await HarborHttp.RequestAsync(HarborHttp.Service, uri, 160_000, method, body, apiKey, cancellation);
                var root = JsonNode.Parse(bytes);
                var result = provider switch
                {
                    OnlineTranslator.MyMemory => root?["responseStatus"]?.ToString() == "200"
                        ? System.Net.WebUtility.HtmlDecode(root["responseData"]?["translatedText"]?.GetValue<string>()) : null,
                    OnlineTranslator.Google => string.Concat((root as JsonArray)?.FirstOrDefault()?.AsArray()
                        .OfType<JsonArray>().Select(row => row.FirstOrDefault()?.GetValue<string>()) ?? []),
                    _ => (root?["choices"] as JsonArray)?.FirstOrDefault() is JsonObject response
                        && response["finish_reason"]?.GetValue<string>() == "stop" ? response["message"]?["content"]?.GetValue<string>() : null
                };
                return !string.IsNullOrWhiteSpace(result) ? result.Trim() : throw new IOException("所选服务未返回完整译文。");
            }
            catch (HttpRequestException error) when (attempt == 0 && (error.StatusCode is null || (int)error.StatusCode >= 500))
            {
                await Task.Delay(850, cancellation);
            }
        }
    }

    private static IEnumerable<(string Text, bool NeedsTranslation)> SplitText(string text)
    {
        var offset = 0;
        foreach (Match token in ProtectedPattern().Matches(text))
        {
            if (token.Index > offset)
            {
                var phrase = text[offset..token.Index];
                yield return (phrase, EnglishPattern().IsMatch(phrase));
            }
            yield return (token.Value, false);
            offset = token.Index + token.Length;
        }
        if (offset < text.Length)
        {
            var phrase = text[offset..];
            yield return (phrase, EnglishPattern().IsMatch(phrase));
        }
    }

    private static IEnumerable<string> SplitUtf8(string text, int limit)
    {
        var buffer = new StringBuilder();
        var bytes = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (bytes + rune.Utf8SequenceLength > limit)
            {
                yield return buffer.ToString();
                buffer.Clear();
                bytes = 0;
            }
            buffer.Append(rune.ToString());
            bytes += rune.Utf8SequenceLength;
        }
        if (buffer.Length > 0) yield return buffer.ToString();
    }

    [GeneratedRegex(@"%(?:\d+\$)?[-+#0,(<]*\d*(?:\.\d+)?[tT]?[A-Za-z%]|\$\{[^{}]+\}|\$\([^()]+\)|\{[^{}\r\n]+\}|[&§](?:#[0-9a-fA-F]{6}|[0-9A-FK-ORZa-fk-orz])|https?://[^\s<>]+|\b[a-z0-9_.-]+:[a-z0-9_./-]+\b|\[\[[^\]\r\n]+\]\]|\r\n|\r|\n")]
    private static partial Regex ProtectedPattern();
    [GeneratedRegex("[A-Za-z]")]
    private static partial Regex EnglishPattern();
    [GeneratedRegex("[\u3400-\u9fff]")]
    private static partial Regex ChinesePattern();
}
