import SwiftUI
import Foundation

enum AppStatus {
    case idle
    case busy(String)
    case done(String)
    case failed(String)
}

struct QueueItem: Identifiable {
    let id = UUID()
    let query: String
    let appleMusicURL: String
    var outputDir: String? = nil

    var displayLabel: String {
        if !query.isEmpty { return query }
        return appleMusicURL
    }
}

struct ContentView: View {
    @State private var query = ""
    @State private var appleMusicURL = ""
    @State private var appStatus: AppStatus = .idle
    @State private var history: [String] = []
    @State private var downloadQueue: [QueueItem] = []
    @StateObject private var installer = ToolInstaller()
    @State private var showSetup = false
    @State private var setupTools: [String] = []
    @FocusState private var queryFocused: Bool

    private var isBusy: Bool {
        if case .busy = appStatus { return true }
        return false
    }

    private var canAdd: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        let a = appleMusicURL.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty || !a.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Music to MP3")
                        .font(.title2).fontWeight(.bold)
                    Text("MP3s are saved to ~/Downloads")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Search field (multiline — one song per line)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Search")
                        .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                    Spacer()
                    Text("Enter adds to queue — Shift+Enter for a new line")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                ZStack(alignment: .topLeading) {
                    if query.isEmpty {
                        Text("Artist – Song title, or paste a YouTube URL…")
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .font(.body)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $query)
                        .font(.body)
                        .frame(minHeight: 64, maxHeight: 120)
                        .focused($queryFocused)
                        .scrollContentBackground(.hidden)
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            // Shift+Enter falls through to TextEditor and inserts a newline.
                            if press.modifiers.contains(.shift) { return .ignored }
                            addToQueueOrDownload()
                            return .handled
                        }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            // Apple Music field
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Music Link")
                    .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField("https://music.apple.com/…", text: $appleMusicURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addToQueueOrDownload() }
                    Button {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            appleMusicURL = text
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    if !appleMusicURL.isEmpty {
                        Button {
                            appleMusicURL = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text("Paste a link — the app looks up the exact title and artist automatically.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Action buttons — main (6/7) + choose-location (1/7)
            GeometryReader { geo in
                HStack(spacing: 6) {
                    Button(action: addToQueueOrDownload) {
                        Group {
                            if isBusy {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.75)
                                    Text("Add to Queue")
                                }
                            } else {
                                Label("Download", systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdd)
                    .frame(width: (geo.size.width - 6) * 6 / 7)

                    Button(action: addWithLocationPicker) {
                        Image(systemName: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdd)
                    .frame(width: (geo.size.width - 6) * 1 / 7)
                    .help("Download and choose where to save")
                }
            }
            .frame(height: 38)

            // Status
            statusView
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Queue
            if !downloadQueue.isEmpty {
                Divider()
                HStack {
                    Text("Up Next (\(downloadQueue.count))")
                        .font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button("Clear") {
                        downloadQueue.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                ForEach(downloadQueue) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(item.displayLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            downloadQueue.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            // History
            if !history.isEmpty {
                Divider()
                HStack {
                    Text("Downloaded")
                        .font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(
                            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                        )
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
                ForEach(history.prefix(5), id: \.self) { name in
                    Label(name, systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
        }
        .padding(22)
        .frame(minWidth: 500, idealWidth: 520, minHeight: 420)
        .onAppear {
            queryFocused = true
            promptForToolsIfNeeded()
        }
        .sheet(isPresented: $showSetup) {
            SetupView(installer: installer, tools: setupTools) {
                showSetup = false
                installer.state = .idle
                queryFocused = true
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch appStatus {
        case .idle:
            Text("Fill in a search or paste an Apple Music link, then click Download")
                .foregroundColor(.secondary)
        case .busy(let msg):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text(msg).foregroundColor(.secondary)
            }
        case .done(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundColor(.red)
        }
    }

    /// Shows the one-time setup popup when yt-dlp or ffmpeg can't be found.
    @discardableResult
    private func promptForToolsIfNeeded() -> Bool {
        let missing = Tools.missing
        guard !missing.isEmpty else { return false }
        setupTools = missing
        installer.state = .idle
        showSetup = true
        return true
    }

    private func addToQueueOrDownload() {
        guard canAdd else { return }
        if promptForToolsIfNeeded() { return }

        // Split search field by newlines; each non-empty line is a separate song
        let lines = query
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let rawAM = appleMusicURL.trimmingCharacters(in: .whitespaces)

        query = ""
        appleMusicURL = ""

        // Build the full list of items to enqueue (Apple Music link only pairs with the first line, or alone)
        var items: [QueueItem] = []
        if lines.isEmpty {
            // Apple Music link only
            if !rawAM.isEmpty { items.append(QueueItem(query: "", appleMusicURL: rawAM)) }
        } else {
            // First line gets the Apple Music URL if provided
            items.append(QueueItem(query: lines[0], appleMusicURL: rawAM))
            for line in lines.dropFirst() {
                items.append(QueueItem(query: line, appleMusicURL: ""))
            }
        }

        guard !items.isEmpty else { return }

        if isBusy {
            downloadQueue.append(contentsOf: items)
        } else {
            let first = items[0]
            downloadQueue.append(contentsOf: items.dropFirst())
            startDownload(query: first.query, appleMusicURL: first.appleMusicURL)
        }
    }

    private func addWithLocationPicker() {
        guard canAdd else { return }
        if promptForToolsIfNeeded() { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Save Location"
        panel.message = "Select the folder where the MP3(s) will be saved"
        guard panel.runModal() == .OK, let dir = panel.url?.path else { return }

        let lines = query
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let rawAM = appleMusicURL.trimmingCharacters(in: .whitespaces)

        query = ""
        appleMusicURL = ""

        var items: [QueueItem] = []
        if lines.isEmpty {
            if !rawAM.isEmpty { items.append(QueueItem(query: "", appleMusicURL: rawAM, outputDir: dir)) }
        } else {
            items.append(QueueItem(query: lines[0], appleMusicURL: rawAM, outputDir: dir))
            for line in lines.dropFirst() {
                items.append(QueueItem(query: line, appleMusicURL: "", outputDir: dir))
            }
        }

        guard !items.isEmpty else { return }

        if isBusy {
            downloadQueue.append(contentsOf: items)
        } else {
            let first = items[0]
            downloadQueue.append(contentsOf: items.dropFirst())
            startDownload(query: first.query, appleMusicURL: first.appleMusicURL, outputDir: first.outputDir)
        }
    }

    private func startDownload(query rawQuery: String, appleMusicURL rawAM: String, outputDir: String? = nil) {
        appStatus = .busy("Starting…")

        DispatchQueue.global(qos: .userInitiated).async {
            var searchQuery = rawQuery
            if !rawAM.isEmpty {
                DispatchQueue.main.async { appStatus = .busy("Looking up track info from Apple Music…") }
                if let info = resolveAppleMusicURL(rawAM) {
                    searchQuery = "\(info.artist) \(info.title)"
                    DispatchQueue.main.async { appStatus = .busy("Found \"\(info.title)\" — downloading…") }
                } else if rawQuery.isEmpty {
                    DispatchQueue.main.async {
                        appStatus = .failed("Couldn't read that Apple Music link — try the search field instead")
                        drainQueue()
                    }
                    return
                }
            } else {
                DispatchQueue.main.async { appStatus = .busy("Searching for \"\(searchQuery)\"…") }
            }

            let result = ytDownload(searchQuery, outputDir: outputDir)
            DispatchQueue.main.async {
                if let name = result.file {
                    history.insert(name, at: 0)
                    appStatus = .done("Saved: \(name)")
                } else {
                    appStatus = .failed(result.error ?? "Unknown error")
                }
                queryFocused = true
                drainQueue()
            }
        }
    }

    private func drainQueue() {
        guard !downloadQueue.isEmpty else { return }
        let next = downloadQueue.removeFirst()
        startDownload(query: next.query, appleMusicURL: next.appleMusicURL, outputDir: next.outputDir)
    }
}

// MARK: - Apple Music → iTunes Lookup

struct TrackInfo {
    let artist: String
    let title: String
}

func resolveAppleMusicURL(_ urlString: String) -> TrackInfo? {
    guard let url = URL(string: urlString),
          let host = url.host,
          host.hasSuffix("music.apple.com"),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let trackID = components.queryItems?.first(where: { $0.name == "i" })?.value
    else { return nil }

    return fetchItunesTrackInfo(trackID: trackID)
}

func fetchItunesTrackInfo(trackID: String) -> TrackInfo? {
    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(trackID)") else { return nil }

    var trackInfo: TrackInfo?
    let sem = DispatchSemaphore(value: 0)

    URLSession.shared.dataTask(with: url) { data, _, _ in
        defer { sem.signal() }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let artist = first["artistName"] as? String,
              let title = first["trackName"] as? String
        else { return }
        trackInfo = TrackInfo(artist: artist, title: title)
    }.resume()

    sem.wait()
    return trackInfo
}

// MARK: - Download engine

struct YTResult {
    var file: String?
    var error: String?
}

func ytDownload(_ query: String, outputDir: String? = nil) -> YTResult {
    guard let ytdlp = Tools.find("yt-dlp") else {
        return YTResult(error: "yt-dlp is missing — restart the app to download it")
    }
    guard let ffmpeg = Tools.find("ffmpeg") else {
        return YTResult(error: "ffmpeg is missing — restart the app to download it")
    }

    let fm = FileManager.default
    let downloadsURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    let downloads = outputDir ?? downloadsURL.path
    let ffmpegDir = (ffmpeg as NSString).deletingLastPathComponent

    let isURL = query.hasPrefix("http://") || query.hasPrefix("https://")
    let target = isURL ? query : "ytsearch1:\(query)"

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ytdlp)
    proc.arguments = [
        target,
        "--extract-audio",
        "--audio-format", "mp3",
        "--audio-quality", "0",
        "--ffmpeg-location", ffmpegDir,
        "--output", "\(downloads)/%(title)s.%(ext)s",
        "--no-playlist",
        "--no-progress",
        "--quiet",
        "--print", "after_move:%(filepath)s"
    ]

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    do { try proc.run() } catch {
        return YTResult(error: "Failed to launch yt-dlp: \(error.localizedDescription)")
    }
    proc.waitUntilExit()

    let outText = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    if proc.terminationStatus != 0 {
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let hint = errText.contains("Unable to download") || errText.contains("No video formats")
            ? "Couldn't find that track — try a different search"
            : "yt-dlp may be out of date"
        return YTResult(error: "Download failed — \(hint)")
    }

    let printed = outText.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? ""
    if !printed.isEmpty {
        return YTResult(file: (printed as NSString).lastPathComponent)
    }

    let contents = (try? fm.contentsOfDirectory(atPath: downloads)) ?? []
    let newest = contents
        .filter { $0.hasSuffix(".mp3") }
        .map { (name: $0, date: (try? fm.attributesOfItem(atPath: "\(downloads)/\($0)")[.modificationDate] as? Date) ?? Date.distantPast) }
        .sorted { $0.date > $1.date }
        .first
    if let f = newest, Date().timeIntervalSince(f.date) < 30 {
        return YTResult(file: f.name)
    }

    return YTResult(error: "Downloaded but couldn't locate the file — check ~/Downloads")
}
