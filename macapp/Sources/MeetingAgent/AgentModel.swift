import AppKit
import Foundation

enum Language: String, CaseIterable, Identifiable {
    case english = "en", thai = "th", auto = "auto"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thai: "ไทย"
        case .english: "English"
        case .auto: "Auto"
        }
    }
}

/// What is recorded: an online meeting (your mic + the meeting's audio through BlackHole), or just a mic.
enum RecordMode: String, CaseIterable, Identifiable {
    case online, micOnly
    var id: String { rawValue }
    var label: String { self == .online ? "ประชุมออนไลน์" : "อัดจากไมค์" }
}

struct MicDevice: Identifiable {
    let name: String
    let isDefault: Bool
    var id: String { name }
}

enum Phase: Equatable {
    case idle, recording, paused, noting, transcribing, summarizing, cancelling, done
    /// Cancelled by the user; `kept` = notes and recorded audio were kept (nothing transcribed or summarized).
    case cancelled(kept: Bool)
    case failed(String)
}

struct Meeting: Identifiable {
    let id: String
    let title: String
    let folder: URL
    var summary: URL? {
        let url = folder.appendingPathComponent("summary.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Drives the Python `meeting-agent` CLI as a subprocess for recordings: commands (/pause, /mute,
/// /end) go in through stdin, phase changes are read from its stdout lines.
/// Notes never go to Python or the LLM: the app saves them itself (see NotesController).
@MainActor
final class AgentModel: ObservableObject {
    static let shared = AgentModel()

    @Published var phase: Phase = .idle
    @Published var title = ""
    @Published var language: Language = .english
    @Published var mode: RecordMode = .online
    /// Input devices macOS reports (BlackHole left out). `micName` "" = whatever macOS uses as its input.
    @Published var mics: [MicDevice] = []
    @Published var micName = ""
    @Published var elapsed = 0
    @Published var micMuted = false
    /// The current / last run was Note only (no audio): no clock, "Save" instead of "Stop".
    @Published var noteOnlyRun = false
    /// Input level of each track, 0...1, fed by the CLI's "[level]" lines while recording.
    @Published var meLevel = 0.0
    @Published var othersLevel = 0.0
    /// Shown from the moment a meeting starts until the next one starts, so notes can be finished
    /// while transcription runs.
    @Published var notepadOpen = false
    let notepad = NotesController()
    @Published var meetings: [Meeting] = []
    @Published var lastSummary: URL?
    /// Folder of the finished run: holds notes.md, and (after a recording) meeting.m4a + transcript.txt.
    @Published var lastFolder: URL?
    /// 0...1 while Whisper transcribes; nil = indeterminate (summarizing, or before the first update).
    @Published var progress: Double?

    let notesRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("meeting-notes")

    private var process: Process?
    /// What to do once the process has exited after a cancel: keep notes + audio, or delete the folder.
    private var keepOnCancel = false
    private var discardFolder: URL?
    private var stdin: FileHandle?
    private var timer: Timer?
    private var startedAt = Date()
    private var buffer = ""
    private var logTail: [String] = []

    private let repo = Bundle.main.object(forInfoDictionaryKey: "MeetingAgentRepo") as? String ?? ""
    private let uv = Bundle.main.object(forInfoDictionaryKey: "MeetingAgentUV") as? String ?? "/opt/homebrew/bin/uv"

    init() {
        refreshMeetings()
        refreshMics()
    }

    var defaultMicName: String { mics.first(where: \.isDefault)?.name ?? "" }

    /// Asks the CLI for the input devices, so the names are exactly the ones `--mic` matches.
    func refreshMics() {
        guard !repo.isEmpty, FileManager.default.isExecutableFile(atPath: uv), !isBusy else { return }
        let uv = uv, repo = repo
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: uv)
            p.arguments = ["run", "--project", repo, "meeting-agent", "devices", "--json"]
            p.currentDirectoryURL = URL(fileURLWithPath: repo)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            // The JSON is the last line; uv or Python may print warnings before it.
            guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] else { return }
            let devices = json.compactMap { entry -> MicDevice? in
                guard let name = entry["name"] as? String, !name.localizedCaseInsensitiveContains("BlackHole") else { return nil }
                return MicDevice(name: name, isDefault: entry["default"] as? Bool ?? false)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mics = devices
                // A mic that was unplugged since it was chosen falls back to the system's input.
                if !self.micName.isEmpty, !devices.contains(where: { $0.name == self.micName }) { self.micName = "" }
            }
        }
    }

    // MARK: State

    var isLive: Bool { phase == .recording || phase == .paused || phase == .noting }
    var isBusy: Bool { isLive || phase == .transcribing || phase == .summarizing || phase == .cancelling }
    var canStart: Bool { !isBusy }
    var canCancel: Bool { isBusy && phase != .cancelling }
    /// Pause only exists while recording audio; note-only mode has nothing to pause.
    var canPause: Bool { phase == .recording || phase == .paused }
    /// A Python run is in flight (recording or processing). Note-only mode has none.
    var isProcessing: Bool { process != nil }

    var statusText: String {
        let muted = micMuted ? "   🔇 Muted" : ""
        switch phase {
        case .idle: return "พร้อม"
        case .recording: return "● กำลังอัด  \(Self.clock(elapsed))\(muted)"
        case .paused: return "⏸ พักอยู่ (ไม่ได้อัด)  \(Self.clock(elapsed))\(muted)"
        default: return otherStatusText
        }
    }

    private var otherStatusText: String {
        switch phase {
        case .idle, .recording, .paused: ""
        case .noting: "📝 โหมด Note"
        case .transcribing: "⏳ กำลังถอดเสียง (Whisper)" + (progress.map { "  \(Int($0 * 100))%" } ?? " ...")
        case .summarizing: "⏳ กำลังสรุป (Claude Code) ..."
        case .cancelling: "⏳ กำลังยกเลิก ..."
        case .cancelled(let kept):
            if noteOnlyRun { kept ? savedText : "✕ ไม่บันทึก Note" }
            else { kept ? "✕ ยกเลิกแล้ว — เก็บ Note และเสียงที่อัดไว้" : "✕ ยกเลิกแล้ว — ลบประชุมนี้แล้ว" }
        case .done: noteOnlyRun ? savedText : "✓ เสร็จแล้ว"
        case .failed(let message): "✗ ผิดพลาด: \(message)"
        }
    }

    /// lastFolder is nil when a Note-only session ended with nothing written (its empty folder is removed).
    private var savedText: String { lastFolder == nil ? "ไม่มี Note ให้บันทึก" : "✓ บันทึก Note แล้ว" }

    var menuTitle: String {
        switch phase {
        case .recording, .paused: Self.clock(elapsed)
        case .noting: "Note"
        case .transcribing: progress.map { "ถอดเสียง \(Int($0 * 100))%" } ?? "ถอดเสียง"
        case .summarizing: "กำลังสรุป"
        default: "Meeting"
        }
    }

    var menuIcon: String {
        switch phase {
        case .recording: micMuted ? "mic.slash.fill" : "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .noting: "square.and.pencil"
        case .transcribing, .summarizing: "hourglass"
        default: "mic"
        }
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    // MARK: Actions

    func start(audio: Bool) {
        guard canStart else { return }
        noteOnlyRun = !audio
        notepad.reset()
        notepadOpen = true
        micMuted = false
        meLevel = 0
        othersLevel = 0
        lastSummary = nil
        lastFolder = nil
        progress = nil
        buffer = ""
        logTail = []
        elapsed = 0
        startedAt = Date()

        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if !audio {
            // Note-only: nothing to record or analyse, so no Python process at all.
            do {
                notepad.folder = try makeMeetingFolder(name.isEmpty ? "meeting" : name)
            } catch {
                phase = .failed("สร้างโฟลเดอร์ไม่ได้: \(error.localizedDescription)")
                return
            }
            phase = .noting  // no clock: a note session has no recording to time
            return
        }

        guard !repo.isEmpty, FileManager.default.isExecutableFile(atPath: uv) else {
            phase = .failed("ไม่พบ repo หรือ uv — build ใหม่ด้วย macapp/build.sh")
            return
        }
        var args = ["run", "--project", repo, "meeting-agent", "record", name.isEmpty ? "meeting" : name]
        // "auto" must be passed explicitly: the CLI default is "en".
        args += ["--language", language.rawValue, "--levels"]
        if mode == .micOnly { args.append("--mic-only") }
        if !micName.isEmpty { args += ["--mic", micName] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        // Apps launched from Finder get a minimal PATH; ffmpeg, uv and claude live outside it.
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        stdin = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in self?.finished(status: status) }
        }

        do {
            try p.run()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        process = p
    }

    /// Same naming as the CLI's session_dir() (cli.py): YYYY-MM-DD_HHMM_<title with separators → "-">.
    private func makeMeetingFolder(_ title: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var slug = title.replacingOccurrences(of: #"[\s/\\:*?"<>|]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "meeting" }
        let base = "\(formatter.string(from: Date()))_\(slug)"
        var url = notesRoot.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = notesRoot.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stop() {
        guard isLive else { return }
        timer?.invalidate()
        notepad.save()
        if phase == .noting {
            // "Save": the pad is already on disk (autosave + the save() above). Nothing written → no folder.
            lastFolder = removeFolderIfEmpty(notepad.folder) ? nil : notepad.folder
            phase = .done
            refreshMeetings()
            return
        }
        phase = .transcribing
        send(raw: "/end")
    }

    /// The phase flips when Python confirms with its "⏸" / "▶" line, not on click.
    func togglePause() {
        switch phase {
        case .recording: send(raw: "/pause")
        case .paused: send(raw: "/resume")
        default: break
        }
    }

    /// Mute only silences the "Me" track; "Others" keeps recording. Same phase rule as pause.
    func toggleMute() {
        guard canPause else { return }
        send(raw: micMuted ? "/unmute" : "/mute")
    }

    /// Two questions, because they are two decisions: (1) really cancel? (2) keep what exists?
    /// Cancel means: no transcription, no summary or analysis. Only the second answer decides
    /// whether the notes and the recorded audio survive.
    func confirmCancel() {
        guard canCancel else { return }
        let hasAudio = phase != .noting

        if !hasAudio {
            // Note only: nothing was recorded, so a single question is enough.
            let save = NSAlert()
            save.messageText = "Save Note ไหม?"
            save.informativeText = "Save: เก็บ Note ของครั้งนี้ไว้ในโฟลเดอร์ประชุม\nไม่ Save: ลบ Note ของครั้งนี้ทั้งหมด กู้คืนไม่ได้"
            save.alertStyle = .warning
            save.addButton(withTitle: "Save")  // default button
            save.addButton(withTitle: "ไม่ Save").hasDestructiveAction = true
            cancel(keepFiles: save.runModal() == .alertFirstButtonReturn)
            return
        }

        let sure = NSAlert()
        sure.messageText = "ยกเลิกประชุมนี้?"
        sure.informativeText = hasAudio
            ? "จะหยุดอัด/ถอดเสียง (Whisper) และไม่สรุปหรือวิเคราะห์ประชุมนี้"
            : "จะหยุดโหมด Note"
        sure.alertStyle = .warning
        sure.addButton(withTitle: "ไม่ยกเลิก")
        sure.addButton(withTitle: "ยกเลิก")
        guard sure.runModal() == .alertSecondButtonReturn else { return }

        let keep = NSAlert()
        keep.messageText = hasAudio ? "เก็บ Note และเสียงที่อัดไว้ไหม?" : "เก็บ Note ไว้ไหม?"
        keep.informativeText = hasAudio
            ? "เก็บ: ได้ไฟล์เสียงกับ Note ในโฟลเดอร์ประชุม ถอดเสียงทีหลังได้ด้วย meeting-agent process\nลบ: ลบทั้งโฟลเดอร์ กู้คืนไม่ได้"
            : "ลบ: ลบ Note ของครั้งนี้ทั้งหมด กู้คืนไม่ได้"
        keep.alertStyle = .warning
        keep.addButton(withTitle: hasAudio ? "เก็บ Note และเสียง" : "เก็บ Note")  // default button
        keep.addButton(withTitle: hasAudio ? "ลบทั้งหมด" : "ลบ Note").hasDestructiveAction = true
        cancel(keepFiles: keep.runModal() == .alertFirstButtonReturn)
    }

    /// Stops whatever is running. Nothing is transcribed or summarized afterwards.
    /// The folder is touched only after the Python process has exited: it may still be writing.
    func cancel(keepFiles keep: Bool) {
        guard canCancel else { return }
        let wasRecording = phase == .recording || phase == .paused
        timer?.invalidate()
        micMuted = false
        meLevel = 0
        othersLevel = 0
        progress = nil
        lastFolder = nil
        lastSummary = nil
        keepOnCancel = keep
        if !keep {
            discardFolder = notepad.folder
            notepad.discard()  // also stops the autosave timer, so nothing re-creates the folder
            notepadOpen = false
        } else {
            notepad.save()
        }

        guard let process, process.isRunning else {  // note-only: no process
            finishCancel()
            return
        }
        phase = .cancelling
        if wasRecording {
            // Graceful: the CLI stops the recorders (closing the FLAC files) and exits without processing.
            send(raw: "/cancel")
        } else {
            process.terminate()  // transcribing / summarizing: the CLI turns SIGTERM into a clean exit
        }
        // Safety net if it doesn't exit (e.g. stuck inside a long native call).
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, let current = self.process, current.processIdentifier == pid, current.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    /// Runs once nothing is writing to the meeting folder any more.
    private func finishCancel() {
        if keepOnCancel {
            let folder = notepad.folder ?? discardFolder
            // Derived files an interrupted run can leave half-written: drop them, keep audio + notes.
            if let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
                for name in names where name.hasSuffix(".part") || name.hasSuffix(".part.m4a") {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
            }
            notepad.save()
            lastFolder = (noteOnlyRun && removeFolderIfEmpty(folder)) ? nil : folder
        } else {
            removeMeetingFolder(discardFolder)
        }
        phase = .cancelled(kept: keepOnCancel)
        discardFolder = nil
        refreshMeetings()
    }

    /// A Note-only session that never got any text leaves an empty folder behind: remove it.
    @discardableResult
    private func removeFolderIfEmpty(_ folder: URL?) -> Bool {
        guard let folder, (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true else { return false }
        removeMeetingFolder(folder)
        return true
    }

    /// Called when the app quits: the pad is saved, and an untouched Note-only folder doesn't stay behind.
    func prepareToQuit() {
        notepad.save()
        if phase == .noting { removeFolderIfEmpty(notepad.folder) }
    }

    /// Only ever deletes a direct child of ~/meeting-notes.
    private func removeMeetingFolder(_ folder: URL?) {
        guard let folder, folder.standardizedFileURL.deletingLastPathComponent().path == notesRoot.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Used when quitting mid-run. SIGTERM, not a graceful stop: the summary is skipped.
    func kill() {
        process?.terminate()
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func refreshMeetings() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: notesRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        meetings = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Meeting(id: $0.lastPathComponent, title: Self.display($0.lastPathComponent), folder: $0) }
            .sorted { $0.id > $1.id }
            .prefix(8)
            .map { $0 }
    }

    // MARK: Subprocess output

    private func send(raw line: String) {
        try? stdin?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func begin(_ newPhase: Phase) {
        phase = newPhase
        elapsed = 0
        startTimer()
    }

    /// Counts up from the current `elapsed`, so a resume continues where the pause stopped.
    private func startTimer() {
        startedAt = Date().addingTimeInterval(-Double(elapsed))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Int(Date().timeIntervalSince(self.startedAt))
            }
        }
    }

    private func consume(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[buffer.index(after: newline)...])
            handle(line)
        }
    }

    /// Python prints one status per line, but input()'s "note> " prompt is glued to the front of
    /// the next line, so match with contains(). Match plain text, not the leading emoji: some
    /// have text/emoji variants that compare unequal as Swift Characters.
    private func handle(_ line: String) {
        if phase == .cancelling {
            // The process is stopping; the only line worth keeping is where its folder is.
            if let range = line.range(of: "เก็บที่ ") {
                let folder = URL(fileURLWithPath: String(line[range.upperBound...]))
                if keepOnCancel { notepad.folder = folder } else { discardFolder = folder }
            }
            return
        }
        if let level = LevelLine.parse(line) {
            // Rise instantly, fall gradually: raw 100 ms peaks flicker too much to read.
            meLevel = max(level.me, meLevel * 0.8)
            othersLevel = max(level.others, othersLevel * 0.8)
        } else if line.contains("● กำลังอัด") {
            begin(.recording)
        } else if let range = line.range(of: "เก็บที่ ") {
            // The CLI created the meeting folder: notes.md + images/ go next to the audio.
            notepad.folder = URL(fileURLWithPath: String(line[range.upperBound...]))
        } else if line.contains("พักการอัดแล้ว") {
            phase = .paused
            timer?.invalidate()
        } else if line.contains("อัดต่อแล้ว") {
            phase = .recording
            startTimer()
        } else if line.contains("mic unmuted") {
            micMuted = false
        } else if line.contains("mic muted") {
            micMuted = true
        } else if line.contains("■ หยุดอัดแล้ว") || line.hasPrefix("Transcribing") {
            phase = .transcribing
        } else if let range = line.range(of: "[progress]"), let percent = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
            progress = percent / 100
        } else if line.contains("กำลังสรุปด้วย Claude Code") {
            phase = .summarizing
            progress = nil
        } else if line.hasPrefix("✓ "), line.hasSuffix("summary.md") {
            let file = URL(fileURLWithPath: String(line.dropFirst(2)))
            lastSummary = file
            lastFolder = file.deletingLastPathComponent()
            phase = .done
        } else if !line.isEmpty, !line.contains("Warning"), !line.contains("note>") {
            logTail = Array((logTail + [line]).suffix(6))
        }
    }

    private func finished(status: Int32) {
        timer?.invalidate()
        process = nil
        stdin = nil
        micMuted = false
        meLevel = 0
        othersLevel = 0
        if phase == .cancelling {
            finishCancel()
            return
        }
        notepad.save()
        if lastFolder == nil { lastFolder = notepad.folder }
        if status != 0 {
            let detail = logTail.last ?? "exit \(status)"
            phase = .failed(detail)
        } else if phase != .done {
            // e.g. "ไม่มี transcript — ข้ามการสรุป"
            phase = .idle
        }
        refreshMeetings()
    }

    private static func display(_ folder: String) -> String {
        // 2026-11-12_1017_Sprint-planning → "11-12 10:17 Sprint planning"
        let parts = folder.split(separator: "_", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[1].count == 4 else { return folder }
        let date = parts[0].dropFirst(5)
        let time = "\(parts[1].prefix(2)):\(parts[1].suffix(2))"
        return "\(date) \(time) \(parts[2].replacingOccurrences(of: "-", with: " "))"
    }
}
