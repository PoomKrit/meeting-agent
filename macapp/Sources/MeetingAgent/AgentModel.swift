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

/// State of the *recording* only. What happens to a meeting after it was recorded (cleaning,
/// transcription, summary) belongs to its Job, so the next recording can start straight away.
enum Phase: Equatable {
    case idle, recording, paused, noting
    /// Stop pressed: the recorder is closing its audio files (about a second).
    case finishing
    case cancelling, done
    /// Cancelled by the user; `kept` = notes and recorded audio were kept (nothing transcribed or summarized).
    case cancelled(kept: Bool)
    case failed(String)
}

enum JobState: Equatable {
    case queued
    /// Echo cancellation and the .m4a, before Whisper starts.
    case preparing
    case transcribing(Double?)
    case summarizing
    case cancelling
    case done(hasSummary: Bool)
    case failed(String)
    case cancelled(kept: Bool)

    var text: String {
        switch self {
        case .queued: "⏳ รอคิว"
        case .preparing: "⏳ เตรียมเสียง (ล้างเสียงสะท้อน / ทำ .m4a)"
        case .transcribing(let p): "⏳ ถอดเสียง (Whisper)" + (p.map { "  \(Int($0 * 100))%" } ?? " ...")
        case .summarizing: "⏳ กำลังสรุป (Claude Code)"
        case .cancelling: "⏳ กำลังยกเลิก ..."
        case .done(let hasSummary): hasSummary ? "✓ เสร็จแล้ว" : "✓ เสร็จ (ไม่พบเสียงพูด จึงไม่มีสรุป)"
        case .failed(let message): "✗ ผิดพลาด: \(message)"
        case .cancelled(let kept): kept ? "✕ ยกเลิก (เก็บเสียงและ Note ไว้)" : "✕ ยกเลิก (ลบแล้ว)"
        }
    }
}

/// One recorded meeting waiting for, or going through, `meeting-agent process`. Jobs run one at a
/// time, in the order they were recorded.
struct Job: Identifiable {
    let id = UUID()
    let title: String
    let folder: URL
    let language: Language
    var state: JobState = .queued
    var summary: URL?

    var isActive: Bool {
        switch state {
        case .queued, .preparing, .transcribing, .summarizing, .cancelling: true
        default: false
        }
    }
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

/// Splits a stream of output chunks into lines.
final class LineBuffer {
    private var text = ""
    func feed(_ chunk: String) -> [String] {
        text += chunk
        var lines: [String] = []
        while let newline = text.firstIndex(of: "\n") {
            lines.append(String(text[..<newline]).trimmingCharacters(in: .whitespaces))
            text = String(text[text.index(after: newline)...])
        }
        return lines
    }
}

/// Drives the Python `meeting-agent` CLI as subprocesses. Recording: one `record --no-process`
/// process at a time, commands (/pause, /mute, /end) go in through stdin. Processing: a queue of
/// `process <folder>` processes, one at a time, started when a recording stops.
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
    /// while the meeting is being processed.
    @Published var notepadOpen = false
    let notepad = NotesController()
    @Published var meetings: [Meeting] = []
    /// Folder of a finished Note-only run, or of a cancelled / failed recording.
    @Published var lastFolder: URL?
    @Published var jobs: [Job] = []

    let notesRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("meeting-notes")

    // Recording process
    private var process: Process?
    /// What to do once the recorder has exited after a cancel: keep notes + audio, or delete the folder.
    private var keepOnCancel = false
    private var discardFolder: URL?
    private var stdin: FileHandle?
    private var timer: Timer?
    private var startedAt = Date()
    private var logTail: [String] = []
    /// Language of the meeting being recorded: its job needs it later.
    private var recordingLanguage: Language = .english

    // Processing queue: at most one job process at a time
    private var jobProcess: Process?
    private var runningJobID: UUID?
    private var jobLogs: [UUID: [String]] = [:]
    private var jobKeepOnCancel: [UUID: Bool] = [:]

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
    /// Recording is busy: a new one can't start. Meetings being processed don't count: they queue.
    var isBusy: Bool { isLive || phase == .finishing || phase == .cancelling }
    var canStart: Bool { !isBusy }
    var canCancel: Bool { isLive }
    /// Pause only exists while recording audio; note-only mode has nothing to pause.
    var canPause: Bool { phase == .recording || phase == .paused }
    /// Anything still running or waiting: the recorder, the current job, or jobs in the queue.
    var isProcessing: Bool { process != nil || jobProcess != nil || jobs.contains { $0.isActive } }

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
        case .finishing: "⏳ กำลังปิดไฟล์เสียง ..."
        case .cancelling: "⏳ กำลังยกเลิก ..."
        case .cancelled(let kept):
            if noteOnlyRun { kept ? savedText : "✕ ไม่บันทึก Note" }
            else { kept ? "✕ ยกเลิกแล้ว — เก็บ Note และเสียงที่อัดไว้" : "✕ ยกเลิกแล้ว — ลบประชุมนี้แล้ว" }
        case .done: savedText
        case .failed(let message): "✗ ผิดพลาด: \(message)"
        }
    }

    /// lastFolder is nil when a Note-only session ended with nothing written (its empty folder is removed).
    private var savedText: String { lastFolder == nil ? "ไม่มี Note ให้บันทึก" : "✓ บันทึก Note แล้ว" }

    /// The job being worked on, if any.
    var runningJob: Job? { jobs.first { $0.id == runningJobID } }
    var queuedCount: Int { jobs.filter { $0.state == .queued }.count }
    var latestSummary: URL? { jobs.last(where: { $0.summary != nil })?.summary }

    /// One line for the menu bar menu, nil when the queue is idle.
    var queueSummary: String? {
        guard jobs.contains(where: { $0.isActive }) else { return nil }
        let current = runningJob.map { "\($0.title): \($0.state.text)" } ?? "คิวประมวลผล"
        return queuedCount > 0 ? "\(current)  (รอคิว \(queuedCount))" : current
    }

    var menuTitle: String {
        switch phase {
        case .recording, .paused: return Self.clock(elapsed)
        case .noting: return "Note"
        default: break
        }
        guard let job = runningJob else { return "Meeting" }
        let waiting = queuedCount > 0 ? " +\(queuedCount)" : ""
        switch job.state {
        case .transcribing(let p): return (p.map { "ถอดเสียง \(Int($0 * 100))%" } ?? "ถอดเสียง") + waiting
        case .summarizing: return "กำลังสรุป" + waiting
        default: return "กำลังประมวลผล" + waiting
        }
    }

    var menuIcon: String {
        switch phase {
        case .recording: return micMuted ? "mic.slash.fill" : "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .noting: return "square.and.pencil"
        default: return runningJob != nil ? "hourglass" : "mic"
        }
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    // MARK: Subprocess plumbing

    /// Apps launched from Finder get a minimal PATH; ffmpeg, uv and claude live outside it.
    private func makeProcess(_ args: [String], lowPriority: Bool = false) -> Process {
        let p = Process()
        if lowPriority {
            // Transcribing a finished meeting must never starve the recorder of the meeting going on now.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
            p.arguments = ["-n", "10", uv] + args
        } else {
            p.executableURL = URL(fileURLWithPath: uv)
            p.arguments = args
        }
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["PATH"] = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        p.environment = env
        return p
    }

    private var toolsAvailable: Bool { !repo.isEmpty && FileManager.default.isExecutableFile(atPath: uv) }

    // MARK: Recording

    func start(audio: Bool) {
        guard canStart else { return }
        noteOnlyRun = !audio
        notepad.reset()
        notepadOpen = true
        micMuted = false
        meLevel = 0
        othersLevel = 0
        lastFolder = nil
        logTail = []
        elapsed = 0
        startedAt = Date()
        recordingLanguage = language

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

        guard toolsAvailable else {
            phase = .failed("ไม่พบ repo หรือ uv — build ใหม่ด้วย macapp/build.sh")
            return
        }
        // --no-process: the recorder only records and exits; this app queues the processing itself.
        var args = ["run", "--project", repo, "meeting-agent", "record", name.isEmpty ? "meeting" : name, "--no-process"]
        // "auto" must be passed explicitly: the CLI default is "en".
        args += ["--language", language.rawValue, "--levels"]
        if mode == .micOnly { args.append("--mic-only") }
        if !micName.isEmpty { args += ["--mic", micName] }

        let p = makeProcess(args)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        stdin = inPipe.fileHandleForWriting

        let lines = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in for line in lines.feed(text) { self?.handle(line) } }
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
        phase = .finishing
        send(raw: "/end")  // the recorder closes its files and exits; finished(status:) queues the meeting
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

        guard let keep = askCancel(what: "ประชุมนี้", detail: "จะหยุดอัดและไม่ถอดเสียงหรือสรุปประชุมนี้") else { return }
        cancel(keepFiles: keep)
    }

    /// The two cancel questions for a meeting that has audio. nil = user backed out; else keep?
    private func askCancel(what: String, detail: String) -> Bool? {
        let sure = NSAlert()
        sure.messageText = "ยกเลิก\(what)?"
        sure.informativeText = detail
        sure.alertStyle = .warning
        sure.addButton(withTitle: "ไม่ยกเลิก")
        sure.addButton(withTitle: "ยกเลิก")
        guard sure.runModal() == .alertSecondButtonReturn else { return nil }

        let keep = NSAlert()
        keep.messageText = "เก็บ Note และเสียงที่อัดไว้ไหม?"
        keep.informativeText = "เก็บ: ได้ไฟล์เสียงกับ Note ในโฟลเดอร์ประชุม ถอดเสียงทีหลังได้ด้วย meeting-agent process\nลบ: ลบทั้งโฟลเดอร์ กู้คืนไม่ได้"
        keep.alertStyle = .warning
        keep.addButton(withTitle: "เก็บ Note และเสียง")  // default button
        keep.addButton(withTitle: "ลบทั้งหมด").hasDestructiveAction = true
        return keep.runModal() == .alertFirstButtonReturn
    }

    /// Stops the recording. Nothing is transcribed or summarized afterwards.
    /// The folder is touched only after the Python process has exited: it may still be writing.
    func cancel(keepFiles keep: Bool) {
        guard canCancel else { return }
        timer?.invalidate()
        micMuted = false
        meLevel = 0
        othersLevel = 0
        lastFolder = nil
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
        // Graceful: the CLI stops the recorders (closing the FLAC files) and exits without processing.
        send(raw: "/cancel")
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
            removePartialFiles(in: folder)
            notepad.save()
            lastFolder = (noteOnlyRun && removeFolderIfEmpty(folder)) ? nil : folder
        } else {
            removeMeetingFolder(discardFolder)
        }
        phase = .cancelled(kept: keepOnCancel)
        discardFolder = nil
        refreshMeetings()
    }

    /// Derived files an interrupted run can leave half-written: drop them, keep audio + notes.
    private func removePartialFiles(in folder: URL?) {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".part") || name.hasSuffix(".part.m4a") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
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

    /// Used when quitting mid-run. SIGTERM, not a graceful stop. Meetings still in the queue keep
    /// their audio in their folders; `meeting-agent process <folder>` handles them later.
    func kill() {
        process?.terminate()
        jobProcess?.terminate()
    }

    // MARK: Recording output

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
        if phase == .finishing, status == 0, let folder = notepad.folder {
            // A normal stop: the audio is on disk, so the meeting goes to the back of the queue and
            // the next recording may start right away.
            enqueue(folder)
            phase = .idle
        } else if status != 0 {
            lastFolder = notepad.folder
            phase = .failed(logTail.last ?? "exit \(status)")
        } else {
            lastFolder = notepad.folder
            phase = .idle
        }
        refreshMeetings()
    }

    // MARK: Processing queue

    private func enqueue(_ folder: URL) {
        jobs.append(Job(title: Self.display(folder.lastPathComponent), folder: folder, language: recordingLanguage))
        startNextJob()
    }

    private func startNextJob() {
        guard jobProcess == nil, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return }
        guard toolsAvailable else {
            jobs[index].state = .failed("ไม่พบ repo หรือ uv — build ใหม่ด้วย macapp/build.sh")
            startNextJob()
            return
        }
        let id = jobs[index].id
        jobs[index].state = .preparing
        jobLogs[id] = []

        let p = makeProcess(["run", "--project", repo, "meeting-agent", "process", jobs[index].folder.path,
                             "--language", jobs[index].language.rawValue], lowPriority: true)
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        let lines = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in for line in lines.feed(text) { self?.handleJob(line, id: id) } }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in self?.jobFinished(id: id, status: status) }
        }
        do {
            try p.run()
        } catch {
            jobs[index].state = .failed(error.localizedDescription)
            startNextJob()
            return
        }
        jobProcess = p
        runningJobID = id
    }

    private func handleJob(_ line: String, id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .cancelling else { return }
        if let range = line.range(of: "[progress]"), let percent = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
            jobs[index].state = .transcribing(percent / 100)
        } else if line.hasPrefix("Transcribing") {
            if case .transcribing = jobs[index].state {} else { jobs[index].state = .transcribing(nil) }
        } else if line.contains("กำลังสรุปด้วย Claude Code") {
            jobs[index].state = .summarizing
        } else if line.hasPrefix("✓ "), line.hasSuffix("summary.md") {
            jobs[index].summary = URL(fileURLWithPath: String(line.dropFirst(2)))
        } else if !line.isEmpty, !line.contains("Warning") {
            jobLogs[id] = Array(((jobLogs[id] ?? []) + [line]).suffix(6))
        }
    }

    private func jobFinished(id: UUID, status: Int32) {
        jobProcess = nil
        runningJobID = nil
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            if jobs[index].state == .cancelling {
                applyJobCancel(at: index)
            } else if status == 0 {
                jobs[index].state = .done(hasSummary: jobs[index].summary != nil)
            } else {
                jobs[index].state = .failed(jobLogs[id]?.last ?? "exit \(status)")
            }
        }
        jobLogs[id] = nil
        refreshMeetings()
        startNextJob()
    }

    /// Cancelling a meeting that was already recorded: the same two questions as for a recording.
    func confirmCancelJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.isActive, job.state != .cancelling else { return }
        guard let keep = askCancel(what: "การประมวลผล “\(job.title)”", detail: "จะหยุดและไม่ถอดเสียงหรือสรุปประชุมนี้ (ประชุมอื่นในคิวไม่กระทบ)") else { return }
        cancelJob(id, keepFiles: keep)
    }

    func cancelJob(_ id: UUID, keepFiles keep: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isActive, jobs[index].state != .cancelling else { return }
        jobKeepOnCancel[id] = keep
        // The note pad may still be open on this meeting and would re-create a deleted folder when it autosaves.
        if notepad.folder?.standardizedFileURL == jobs[index].folder.standardizedFileURL {
            if keep { notepad.save() } else { notepad.discard(); notepadOpen = false }
        }
        guard runningJobID == id, let p = jobProcess else {  // still waiting in the queue
            applyJobCancel(at: index)
            return
        }
        jobs[index].state = .cancelling
        p.terminate()  // the CLI turns SIGTERM into a clean exit
        let pid = p.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, let current = self.jobProcess, current.processIdentifier == pid, current.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    /// The job's process is gone (or never started): keep the folder or delete it.
    private func applyJobCancel(at index: Int) {
        let id = jobs[index].id
        let keep = jobKeepOnCancel[id] ?? true
        if keep { removePartialFiles(in: jobs[index].folder) } else { removeMeetingFolder(jobs[index].folder) }
        jobs[index].state = .cancelled(kept: keep)
        jobKeepOnCancel[id] = nil
        refreshMeetings()
    }

    func clearFinishedJobs() {
        jobs.removeAll { !$0.isActive }
    }

    // MARK: Files

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

    private static func display(_ folder: String) -> String {
        // 2026-11-12_1017_Sprint-planning → "11-12 10:17 Sprint planning"
        let parts = folder.split(separator: "_", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[1].count == 4 else { return folder }
        let date = parts[0].dropFirst(5)
        let time = "\(parts[1].prefix(2)):\(parts[1].suffix(2))"
        return "\(date) \(time) \(parts[2].replacingOccurrences(of: "-", with: " "))"
    }
}
