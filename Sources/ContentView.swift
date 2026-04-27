import SwiftUI
import Foundation

enum AppStatus {
    case idle
    case busy(String)
    case done(String)
    case failed(String)
}

struct ContentView: View {
    @State private var query = ""
    @State private var appleMusicURL = ""
    @State private var appStatus: AppStatus = .idle
    @State private var history: [String] = []
    @FocusState private var queryFocused: Bool

    private var isBusy: Bool {
        if case .busy = appStatus { return true }
        return false
    }

    private var canDownload: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        let a = appleMusicURL.trimmingCharacters(in: .whitespaces)
        return (!q.isEmpty || !a.isEmpty) && !isBusy
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

            // Search field
            VStack(alignment: .leading, spacing: 4) {
                Text("Search")
                    .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                TextField("Artist – Song title, or paste a YouTube URL…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit { startDownload() }
                    .disabled(isBusy)
            }

            // Apple Music field
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Music Link")
                    .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField("https://music.apple.com/…", text: $appleMusicURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { startDownload() }
                        .disabled(isBusy)
                    Button {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            appleMusicURL = text
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
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

            // Download button
            Button(action: startDownload) {
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75)
                        Text("Working…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canDownload)

            // Status
            statusView
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .frame(minWidth: 500, idealWidth: 520, minHeight: 360)
        .onAppear { queryFocused = true }
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

    private func startDownload() {
        guard canDownload else { return }
        let rawQuery = query.trimmingCharacters(in: .whitespaces)
        let rawAM = appleMusicURL.trimmingCharacters(in: .whitespaces)

        query = ""
        appStatus = .busy("Starting…")

        DispatchQueue.global(qos: .userInitiated).async {
            // If Apple Music URL is provided, resolve it first
            var searchQuery = rawQuery
            if !rawAM.isEmpty {
                DispatchQueue.main.async { appStatus = .busy("Looking up track info from Apple Music…") }
                if let info = resolveAppleMusicURL(rawAM) {
                    searchQuery = "\(info.artist) \(info.title)"
                    DispatchQueue.main.async { appStatus = .busy("Found \"\(info.title)\" — downloading…") }
                } else if rawQuery.isEmpty {
                    DispatchQueue.main.async { appStatus = .failed("Couldn't read that Apple Music link — try the search field instead") }
                    return
                }
                // if lookup failed but rawQuery is set, fall through to rawQuery
            } else {
                DispatchQueue.main.async { appStatus = .busy("Searching for \"\(searchQuery)\"…") }
            }

            let result = ytDownload(searchQuery)
            DispatchQueue.main.async {
                if let name = result.file {
                    history.insert(name, at: 0)
                    appleMusicURL = ""
                    appStatus = .done("Saved: \(name)")
                } else {
                    appStatus = .failed(result.error ?? "Unknown error")
                }
                queryFocused = true
            }
        }
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

func ytDownload(_ query: String) -> YTResult {
    let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    func find(_ bin: String) -> String? {
        for dir in searchPaths {
            let p = "\(dir)/\(bin)"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    guard let ytdlp = find("yt-dlp") else {
        return YTResult(error: "yt-dlp not found — open Terminal and run: brew install yt-dlp")
    }
    guard let ffmpeg = find("ffmpeg") else {
        return YTResult(error: "ffmpeg not found — open Terminal and run: brew install ffmpeg")
    }

    let fm = FileManager.default
    let downloadsURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    let downloads = downloadsURL.path
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
            : "Try: brew upgrade yt-dlp"
        return YTResult(error: "Download failed — \(hint)")
    }

    // yt-dlp prints the final filepath via --print after_move:%(filepath)s
    let printed = outText.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? ""
    if !printed.isEmpty {
        return YTResult(file: (printed as NSString).lastPathComponent)
    }

    // Fallback: scan Downloads for newest .mp3
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
