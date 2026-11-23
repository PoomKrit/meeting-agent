import AppKit
import SwiftUI

/// Hosts the app-owned NSTextView. SwiftUI's TextEditor can't hold pasted images.
struct NotesEditor: NSViewRepresentable {
    let controller: NotesController
    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

/// One meeting in the processing queue. Several can be listed while a new meeting is being recorded.
struct JobRow: View {
    @ObservedObject var model: AgentModel
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.title).lineLimit(1)
                Spacer()
                if job.isActive && job.state != .cancelling {
                    Button("✕") { model.confirmCancelJob(job.id) }
                        .buttonStyle(.link)
                        .help("ยกเลิกการประมวลผลประชุมนี้")
                }
            }
            Text(job.state.text).font(.caption).foregroundStyle(color)
            if case .transcribing(let percent) = job.state {
                ProgressView(value: percent).progressViewStyle(.linear)
            } else if job.state == .preparing || job.state == .summarizing {
                ProgressView().progressViewStyle(.linear)  // no measurable progress: animated bar
            }
            if case .done = job.state {
                HStack {
                    if let summary = job.summary { Button("เปิดสรุป") { model.open(summary) }.buttonStyle(.link) }
                    Button("โฟลเดอร์") { model.open(job.folder) }.buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }

    private var color: Color {
        switch job.state {
        case .done: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .primary
        }
    }
}

/// One input-level bar. Green normally, orange when loud, red near clipping.
struct LevelBar: View {
    let label: String
    let level: Double
    var disabled = false

    private var color: Color {
        if disabled { return .secondary }
        return level > 0.95 ? .red : (level > 0.8 ? .orange : .green)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(disabled ? .secondary : .primary)
                .frame(width: 92, alignment: .leading)
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: bar.size.width * (disabled ? 0 : level))
                }
            }
            .frame(height: 8)
        }
    }
}

struct ConsoleView: View {
    // No @State: in the current SDK it is a macro, and the SwiftUIMacros plugin ships only with
    // Xcode. This app builds with Command Line Tools, so all state lives in the model.
    @ObservedObject var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("ชื่อการประชุม", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)

            Picker("ภาษา", selection: $model.language) {
                ForEach(Language.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            Picker("โหมด", selection: $model.mode) {
                ForEach(RecordMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            HStack {
                Picker("ไมค์", selection: $model.micName) {
                    Text(model.defaultMicName.isEmpty ? "ค่าตั้งต้นของระบบ" : "ค่าตั้งต้นของระบบ (\(model.defaultMicName))").tag("")
                    ForEach(model.mics) { Text($0.name).tag($0.name) }
                }
                .disabled(model.isBusy)
                Button("↻") { model.refreshMics() }
                    .help("อ่านรายชื่อไมค์ใหม่ (เช่นหลังเสียบไมค์ภายนอก)")
                    .disabled(model.isBusy)
            }

            HStack {
                Button("● Record") { model.start(audio: true) }
                    .disabled(!model.canStart)
                Button("📝 Note only") { model.start(audio: false) }
                    .disabled(!model.canStart)
                Button(model.phase == .noting ? "💾 Save" : "■ Stop") { model.stop() }
                    .disabled(!model.isLive)
                Button("✕ Cancel") { model.confirmCancel() }
                    .disabled(!model.canCancel)
            }

            if model.canPause {
                HStack {
                    Button(model.phase == .paused ? "▶ Resume" : "⏸ Pause") { model.togglePause() }
                    // Mic-only has no meeting audio to keep: Pause is all it needs.
                    if model.mode == .online {
                        Button(model.micMuted ? "🎙 Unmute me" : "🔇 Mute me") { model.toggleMute() }
                    }
                }
            }

            Text(model.statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(statusColor)
                .textSelection(.enabled)

            if model.phase == .recording || model.phase == .paused {
                VStack(spacing: 4) {
                    LevelBar(label: model.mode == .micOnly ? "Mic" : (model.micMuted ? "Me (Muted)" : "Me (mic)"),
                             level: model.meLevel, disabled: model.micMuted)
                    if model.mode == .online {
                        LevelBar(label: "Others (ประชุม)", level: model.othersLevel)
                    }
                }
            }

            if model.notepadOpen {
                HStack(alignment: .firstTextBaseline) {
                    Text("Note").font(.headline)
                    Text("Markdown · ⌘B ⌘I · วางรูปด้วย ⌘V หรือลากมาวาง · จดเอง ไม่ส่งให้ AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Takes whatever height the window has left, so enlarging the window enlarges the pad.
                NotesEditor(controller: model.notepad)
                    .frame(minHeight: 160, maxHeight: .infinity)
            }

            if let folder = model.lastFolder {
                Button("เปิดโฟลเดอร์ประชุมนี้") { model.open(folder) }
            }

            if !model.jobs.isEmpty {
                Divider()
                HStack {
                    Text("คิวประมวลผล").font(.headline)
                    Spacer()
                    if model.jobs.contains(where: { !$0.isActive }) {
                        Button("ล้างรายการที่จบแล้ว") { model.clearFinishedJobs() }.buttonStyle(.link)
                    }
                }
                ForEach(model.jobs) { job in
                    JobRow(model: model, job: job)
                }
            }

            Divider()

            HStack {
                Text("ประชุมก่อนหน้า").font(.headline)
                Spacer()
                Button("เปิดโฟลเดอร์") { model.open(model.notesRoot) }.buttonStyle(.link)
            }
            if model.meetings.isEmpty {
                Text("ยังไม่มี").foregroundStyle(.secondary)
            }
            ForEach(model.meetings) { meeting in
                HStack {
                    Text(meeting.title).lineLimit(1)
                    Spacer()
                    Button(meeting.summary == nil ? "โฟลเดอร์" : "เปิดสรุป") {
                        model.open(meeting.summary ?? meeting.folder)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(16)
        // Resizable: 440 pt wide minimum (the control rows need it), no upper limit. Content stays
        // pinned to the top; only the note pad stretches.
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.refreshMeetings()
            model.refreshMics()
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .recording: .red
        case .failed: .orange
        case .done: .green
        default: .primary
        }
    }
}
