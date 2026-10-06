import AinkradAppKit
import Foundation
import WhisperFeature

/// The bundle's principal class (matches `NSPrincipalClass` in Info.plist).
@objc(WhisperPluginEntryPoint)
final class WhisperPluginEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { WhisperApp.self }
}
