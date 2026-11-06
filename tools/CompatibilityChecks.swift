import Foundation

// The production networking and translation code is compiled alongside this
// harness. Only the shared error constructor is supplied here.
enum FileTransactions {
    static func error(_ description:String)->NSError{NSError(domain:"MC Harbor QA",code:1,userInfo:[NSLocalizedDescriptionKey:description])}
}

@main struct CompatibilityChecks {
    static func main() async throws {
        var checks:[String:Bool]=[:]
        func check(_ name:String,_ passed:Bool){checks[name]=passed;print((passed ? "PASS ":"FAIL ")+name)}
        check("intel-architecture",HarborArchitecture.name=="x86_64" && HarborArchitecture.sakuraKey=="darwin_amd64")
        check("intel-mach-header",HarborArchitecture.machHeader==[207,250,237,254,7,0,0,1])
        let text=String(repeating:"A long quest with emoji 🌱 and many words. ",count:80)
        let chunks=try LegacyLanguageTranslation.chunks(text)
        check("online-chunks-byte-limit",chunks.filter(\.translate).allSatisfy{$0.text.utf8.count<=400})
        check("online-chunks-preserve-original",chunks.map(\.text).joined()==text)
        let source="§aWelcome %1$s, collect %2$d {item:minecraft:stone}.\nOpen [[quest:123]] ${name} https://example.org/a"
        let entry=PendingLanguageEntry(resource:"qa",id:"quest",source:source)
        let result=try await LegacyLanguageTranslation.translate(entry){"译"+$0}
        let translated=result["translation"] ?? ""
        check("online-preserves-placeholders",["§a","%1$s","%2$d","{item:minecraft:stone}","\n","[[quest:123]]","${name}","https://example.org/a"].allSatisfy{translated.contains($0)})
        check("online-retains-source-for-revision-check",result["source"]==source && result["resource"]=="qa")
        let quota=Data(#"{"responseStatus":200,"responseData":{"translatedText":"MYMEMORY WARNING: quota reached"}}"#.utf8)
        do{_ = try LegacyLanguageTranslation.parseResponse(quota,source:"Hello");check("quota-message-never-saved",false)}catch LegacyLanguageTranslation.Failure.unavailable{check("quota-message-never-saved",true)}
        let unchanged=Data(#"{"responseStatus":200,"responseData":{"translatedText":"Hello"}}"#.utf8)
        do{_ = try LegacyLanguageTranslation.parseResponse(unchanged,source:"Hello");check("unchanged-result-remains-pending",false)}catch LegacyLanguageTranslation.Failure.unchanged{check("unchanged-result-remains-pending",true)}
        do{_ = try await LegacyLanguageTranslation.translate(PendingLanguageEntry(resource:"qa",id:"number",source:"123")){_ in "不应调用"};check("no-fake-translation",false)}catch LegacyLanguageTranslation.Failure.unchanged{check("no-fake-translation",true)}
        let cancel=Task{try await HarborDelay.sleep(seconds:60)};cancel.cancel()
        do{try await cancel.value;check("backported-delay-cancellation",false)}catch is CancellationError{check("backported-delay-cancellation",true)}
        if ProcessInfo.processInfo.environment["HARBOR_LIVE_TEST"]=="1" {
            let value=try await LegacyLanguageTranslation.query("Reload Shaders")
            check("live-online-Chinese",value.range(of:"[\\p{Han}]",options:.regularExpression) != nil)
        }
        print("Compatibility checks: \(checks.values.filter{$0}.count) passed, \(checks.values.filter{!$0}.count) failed")
        if checks.values.contains(false){exit(1)}
    }
}
