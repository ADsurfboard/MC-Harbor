import Foundation

/// Short-lived public GET metadata only. Player data, tokens and downloads never enter it.
actor ResourceMetadataCache {
    static let shared=ResourceMetadataCache()
    private var values:[String:(Date,Data)]=[:]
    private var flights:[String:Task<Data,Error>]=[:]
    private var bytes=0
    func data(_ key:String,ttl:TimeInterval=60,load:@escaping @Sendable ()async throws->Data)async throws->Data {
        try Task.checkCancellation()
        if let (date,value)=values[key],Date().timeIntervalSince(date)<ttl{return value}
        if let task=flights[key]{let value=try await task.value;try Task.checkCancellation();return value}
        let task=Task{try await load()};flights[key]=task
        do {
            let value=try await task.value;flights.removeValue(forKey:key)
            if value.count<=2_000_000 {
                if let old=values.removeValue(forKey:key){bytes-=old.1.count}
                while (bytes+value.count>8_000_000 || values.count>=64),let oldest=values.min(by:{$0.value.0<$1.value.0}){values.removeValue(forKey:oldest.key);bytes-=oldest.value.1.count}
                values[key]=(Date(),value);bytes+=value.count
            }
            try Task.checkCancellation();return value
        }catch{flights.removeValue(forKey:key);throw error}
    }
}
