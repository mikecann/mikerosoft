import Foundation
import ServiceManagement
import SwiftUI

/// Registration must run from the signed app bundle. A `swift -` script has
/// its own bundle context and cannot manage this app's embedded LaunchAgent.
@main
enum MeetingArchiveEntry {
    @MainActor
    static func main() async {
        let service = SMAppService.agent(plistName: "com.mikerosoft.meeting-archive.plist")
        do {
            if CommandLine.arguments.contains("--disable-startup") {
                try await service.unregister()
                print("Meeting Archive login item disabled. Recordings and archive data were retained.")
                return
            }
            if CommandLine.arguments.contains("--enable-startup") {
                try service.register()
                print(service.status == .enabled ? "Meeting Archive login item enabled." : "Allow Meeting Archive in System Settings > Login Items.")
                return
            }
        } catch {
            FileHandle.standardError.write(Data("Could not change startup registration: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        MeetingArchiveApplication.main()
    }
}
