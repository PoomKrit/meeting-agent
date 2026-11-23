import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AgentModel.shared
        model.prepareToQuit()
        guard model.isProcessing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "กำลังทำงานอยู่ ออกเลยไหม?"
        alert.informativeText = "ถ้าออกตอนนี้ ประชุมที่ยังอยู่ในคิวจะไม่ถูกถอดเสียงหรือสรุป เสียงที่อัดไปแล้วยังอยู่ในโฟลเดอร์ประชุม ใช้ `meeting-agent process <โฟลเดอร์>` ทำต่อภายหลังได้"
        alert.addButton(withTitle: "ยกเลิก")
        alert.addButton(withTitle: "ออก")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.kill()
        return .terminateNow
    }
}

@main
struct MeetingAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AgentModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Meeting Agent", id: "console") {
            ConsoleView(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 700)

        MenuBarExtra {
            Button("เปิด Console…") {
                openWindow(id: "console")
                NSApp.activate(ignoringOtherApps: true)
            }
            if model.canPause {
                Button(model.phase == .paused ? "▶ Resume" : "⏸ Pause") { model.togglePause() }
                if model.mode == .online {
                    Button(model.micMuted ? "🎙 Unmute me" : "🔇 Mute me") { model.toggleMute() }
                }
            }
            if model.isLive {
                Button(model.phase == .noting ? "💾 Save" : "■ Stop") { model.stop() }
            }
            if model.canCancel {
                Button("✕ Cancel (ลบประชุมนี้)") { model.confirmCancel() }
            }
            Text(model.statusText)
            if let queue = model.queueSummary {
                Text(queue)
            }
            Divider()
            Button("เปิดโฟลเดอร์ประชุม") { model.open(model.notesRoot) }
            if let summary = model.latestSummary {
                Button("เปิดสรุปล่าสุด") { model.open(summary) }
            }
            if let folder = model.lastFolder {
                Button("เปิดโฟลเดอร์ประชุมล่าสุด") { model.open(folder) }
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Label(model.menuTitle, systemImage: model.menuIcon)
        }
    }
}
