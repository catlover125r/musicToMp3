import SwiftUI

// MARK: - Locating the command-line tools

/// yt-dlp and ffmpeg live in the app's own Application Support folder once downloaded.
/// Homebrew / system copies are still picked up if they already exist.
enum Tools {
    static let required = ["yt-dlp", "ffmpeg"]

    static var dir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music to MP3/bin", isDirectory: true)
    }

    static func find(_ bin: String) -> String? {
        let dirs = [dir.path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for d in dirs {
            let p = "\(d)/\(bin)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var missing: [String] { required.filter { find($0) == nil } }
}

// MARK: - Downloading them

@MainActor
final class ToolInstaller: ObservableObject {
    enum State {
        case idle
        case working(label: String, progress: Double)
        case done
        case failed(String)
    }

    @Published var state: State = .idle

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    private struct Source {
        let url: URL
        let gzipped: Bool
        let label: String
    }

    private func source(for tool: String) -> Source {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        switch tool {
        case "yt-dlp":
            return Source(
                url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
                gzipped: false, label: "yt-dlp")
        default:
            return Source(
                url: URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-\(arch).gz")!,
                gzipped: true, label: "ffmpeg")
        }
    }

    func install(_ tools: [String]) async {
        guard !tools.isEmpty else { state = .done; return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Tools.dir, withIntermediateDirectories: true)

            for (index, tool) in tools.enumerated() {
                let src = source(for: tool)
                let count = Double(tools.count)
                let base = Double(index)
                state = .working(label: "Downloading \(src.label)…", progress: base / count)

                let downloader = FileDownloader { [weak self] fraction in
                    Task { @MainActor in
                        self?.state = .working(label: "Downloading \(src.label)…",
                                               progress: (base + fraction) / count)
                    }
                }
                let tmp = try await downloader.download(src.url)
                defer { try? fm.removeItem(at: tmp) }

                let dest = Tools.dir.appendingPathComponent(tool)
                let partial = Tools.dir.appendingPathComponent(tool + ".partial")
                try? fm.removeItem(at: partial)

                if src.gzipped {
                    state = .working(label: "Unpacking \(src.label)…", progress: (base + 1) / count)
                    try await Task.detached { try Self.gunzip(tmp, to: partial) }.value
                } else {
                    try fm.moveItem(at: tmp, to: partial)
                }

                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: partial, to: dest)
            }

            // Make sure everything we just installed actually launches.
            state = .working(label: "Checking tools…", progress: 1)
            for tool in tools {
                let ok = await Task.detached { Self.runs(Tools.dir.appendingPathComponent(tool).path, tool) }.value
                if !ok { throw InstallError.wontRun(tool) }
            }
            state = .done
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    enum InstallError: LocalizedError {
        case wontRun(String)
        case gunzip
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .wontRun(let t): return "\(t) downloaded but wouldn't start."
            case .gunzip: return "Couldn't unpack the download."
            case .badResponse(let c): return "The server answered with an error (HTTP \(c))."
            }
        }
    }

    nonisolated private static func gunzip(_ src: URL, to dest: URL) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", src.path]
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw InstallError.gunzip }
    }

    nonisolated private static func runs(_ path: String, _ tool: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = tool == "ffmpeg" ? ["-version"] : ["--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// One-shot URLSession download with progress reporting.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { onProgress(Double(written) / Double(total)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(ToolInstaller.InstallError.badResponse(http.statusCode)))
            return
        }
        // `location` is deleted when this returns, so move it somewhere we own.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            finish(.success(keep))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - First-launch popup

struct SetupView: View {
    @ObservedObject var installer: ToolInstaller
    let tools: [String]
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("One-time setup").font(.title3).fontWeight(.semibold)
                    Text("Music to MP3 needs a couple of free tools to find and convert songs.")
                        .font(.callout).foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(tools, id: \.self) { tool in
                    Label(tool == "yt-dlp" ? "yt-dlp — finds and downloads the audio"
                                           : "ffmpeg — converts it to MP3",
                          systemImage: "checkmark.circle")
                        .font(.callout)
                }
                Text("About 60 MB, saved inside the app's own folder. No Homebrew needed.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            statusArea

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 440)
        .interactiveDismissDisabled(installer.isWorking)
    }

    @ViewBuilder private var statusArea: some View {
        switch installer.state {
        case .idle:
            EmptyView()
        case .working(let label, let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text(label).font(.caption).foregroundColor(.secondary)
            }
        case .done:
            Label("All set — you're ready to download.", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green).font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red).font(.callout)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch installer.state {
        case .idle:
            Button("Not Now", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Download") { start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .working:
            Button("Download") {}.buttonStyle(.borderedProminent).disabled(true)
        case .done:
            Button("Continue", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Not Now", action: onClose)
            Button("Try Again") { start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func start() {
        Task { await installer.install(tools) }
    }
}
