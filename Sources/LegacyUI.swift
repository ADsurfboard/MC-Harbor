import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI's two-value onChange was introduced after macOS 13.
private struct HarborChangeObserver<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void
    @State private var previous: Value

    init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { newValue in
            let oldValue = previous
            previous = newValue
            action(oldValue, newValue)
        }
    }
}

extension View {
    func harborOnChange<Value: Equatable>(of value: Value, perform: @escaping (Value, Value) -> Void) -> some View {
        modifier(HarborChangeObserver(value: value, action: perform))
    }
    @ViewBuilder func harborHideScrollIndicators() -> some View {
        if #available(macOS 13.0, *) { self.scrollIndicators(.hidden) } else { self }
    }
    @ViewBuilder func harborHideScrollBackground() -> some View {
        if #available(macOS 13.0, *) { self.scrollContentBackground(.hidden) } else { self }
    }
    @ViewBuilder func harborSelectionMenu<MenuContent:View>(selection:Set<String>,@ViewBuilder menu:@escaping(Set<String>)->MenuContent)->some View {
        if #available(macOS 13.0, *) { self.contextMenu(forSelectionType:String.self,menu:menu) }
        else { self.contextMenu { menu(selection) } }
    }
    @ViewBuilder func harborDropFiles(action:@escaping([URL])->Void)->some View {
        if #available(macOS 13.0, *) { self.dropDestination(for:URL.self){urls,_ in action(urls);return true} }
        else { self.onDrop(of:[UTType.fileURL.identifier],isTargeted:nil){providers in
            let candidates=providers.filter{$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}
            guard !candidates.isEmpty else{return false}
            let group=DispatchGroup(),lock=NSLock();var urls:[URL]=[]
            for provider in candidates {
                group.enter();provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,_ in
                    let url:URL?
                    if let value=item as? URL{url=value}
                    else if let value=item as? Data{url=URL(dataRepresentation:value,relativeTo:nil)}
                    else if let value=item as? String{url=URL(string:value)}
                    else{url=nil}
                    if let url,url.isFileURL{lock.lock();urls.append(url);lock.unlock()};group.leave()
                }
            }
            group.notify(queue:.main){if !urls.isEmpty{action(urls)}}
            return true
        } }
    }
}

enum HarborDelay {
    static func sleep(seconds:Double) async throws {
        let bounded=seconds.isFinite ? max(0,min(seconds,86400)):0
        try await Task<Never,Never>.sleep(nanoseconds:UInt64(bounded*1_000_000_000))
    }
}

/// Keeps empty states readable on macOS versions without ContentUnavailableView.
struct HarborEmptyView: View {
    let title: String
    let systemImage: String
    var description: Text? = nil

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 9) {
            HarborSymbol(systemName: systemImage).font(.system(size: 30, weight: .light))
            Text(title).font(.system(size: 15, weight: .medium))
            if let description { description.font(.system(size: 11)).multilineTextAlignment(.center) }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

enum HarborArchitecture {
    #if arch(x86_64)
    static let name = "x86_64"
    static let sakuraKey = "darwin_amd64"
    static let machHeader: [UInt8] = [207, 250, 237, 254, 7, 0, 0, 1]
    #elseif arch(arm64)
    static let name = "arm64"
    static let sakuraKey = "darwin_arm64"
    static let machHeader: [UInt8] = [207, 250, 237, 254, 12, 0, 0, 1]
    #else
    #error("Unsupported macOS CPU architecture")
    #endif
}
