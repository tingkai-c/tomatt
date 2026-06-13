import Foundation
import SwiftUI

protocol TBLogEvent: Encodable {
    var type: String { get }
    var timestamp: Date { get }
}

class TBLogEventAppStart: TBLogEvent {
    internal let type = "appstart"
    internal let timestamp: Date = Date()
}

class TBLogEventSettingsOpenFailed: TBLogEvent {
    internal let type = "settingsOpenFailed"
    internal let timestamp: Date = Date()
}

class TBLogEventTransition: TBLogEvent {
    internal let type = "transition"
    internal let timestamp: Date = Date()

    private let event: String
    private let fromState: String
    private let toState: String

    init(fromContext ctx: TBStateMachine.Context) {
        event = "\(ctx.event!)"
        fromState = "\(ctx.fromState)"
        toState = "\(ctx.toState)"
    }
}

class TBLogEventSyncDiagnostic: TBLogEvent {
    internal let type = "syncDiagnostic"
    internal let timestamp: Date = Date()

    private let component: String
    private let event: String
    private let message: String?
    private let peerID: String?
    private let endpoint: String?
    private let reason: String?
    private let error: String?
    private let counts: [String: Int]?
    private let details: [String: String]?
    private let flags: [String: Bool]?

    init(component: String,
         event: String,
         message: String? = nil,
         peerID: String? = nil,
         endpoint: String? = nil,
         reason: String? = nil,
         error: String? = nil,
         counts: [String: Int]? = nil,
         details: [String: String]? = nil,
         flags: [String: Bool]? = nil) {
        self.component = component
        self.event = event
        self.message = message
        self.peerID = peerID
        self.endpoint = endpoint
        self.reason = reason
        self.error = error
        self.counts = counts
        self.details = details
        self.flags = flags
    }
}

private let logFileName = "tomatt.log"
private let lineEnd = "\n".data(using: .utf8)!

internal let logger = TBLogger()

class TBLogger {
    private let logHandle: FileHandle?
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970

        let fileManager = FileManager.default
        let logPath = fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(logFileName)
            .path

        if !fileManager.fileExists(atPath: logPath) {
            guard fileManager.createFile(atPath: logPath, contents: nil) else {
                print("cannot create log file")
                logHandle = nil
                return
            }
        }

        logHandle = FileHandle(forUpdatingAtPath: logPath)
        guard logHandle != nil else {
            print("cannot open log file")
            return
        }
    }

    func append(event: TBLogEvent) {
        guard let logHandle = logHandle else {
            return
        }
        do {
            let jsonData = try encoder.encode(event)
            try logHandle.seekToEnd()
            try logHandle.write(contentsOf: jsonData + lineEnd)
            try logHandle.synchronize()
        } catch {
            print("cannot write to log file: \(error)")
        }
    }

    func appendSyncDiagnostic(component: String,
                              event: String,
                              message: String? = nil,
                              peerID: String? = nil,
                              endpoint: String? = nil,
                              reason: String? = nil,
                              error: String? = nil,
                              counts: [String: Int]? = nil,
                              details: [String: String]? = nil,
                              flags: [String: Bool]? = nil) {
        append(event: TBLogEventSyncDiagnostic(component: component,
                                               event: event,
                                               message: message,
                                               peerID: peerID,
                                               endpoint: endpoint,
                                               reason: reason,
                                               error: error,
                                               counts: counts,
                                               details: details,
                                               flags: flags))
    }
}
