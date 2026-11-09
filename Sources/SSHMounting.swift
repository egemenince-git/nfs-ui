import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

private final class SSHAskpassBroker {
    private let password: String
    private let queue = DispatchQueue(label: "com.egemenince.NFSConnect.ssh-askpass")
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var socketPath: String?
    private var stopped = false

    init(password: String) {
        self.password = password
    }

    func start() throws -> String {
        let path = "/tmp/nfsc-\(UUID().uuidString).sock"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.socketError("SSH parola köprüsü açılamadı") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            Darwin.close(fd)
            throw NSError(domain: "NFSConnect.SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSH parola köprüsü yolu çok uzun."])
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    _ = strncpy(destination, source.baseAddress!, source.count)
                }
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(addressLength)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addressLength) }
        }
        guard bindResult == 0, Darwin.listen(fd, 4) == 0 else {
            let error = Self.socketError("SSH parola köprüsü başlatılamadı")
            Darwin.close(fd)
            _ = path.withCString { Darwin.unlink($0) }
            throw error
        }
        _ = path.withCString { Darwin.chmod($0, mode_t(S_IRUSR | S_IWUSR)) }

        lock.lock()
        socketFD = fd
        socketPath = path
        lock.unlock()

        queue.async { [weak self] in self?.serve(fd: fd) }
        return path
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = socketFD
        let path = socketPath
        socketFD = -1
        socketPath = nil
        lock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        if let path { _ = path.withCString { Darwin.unlink($0) } }
    }

    private func serve(fd: Int32) {
        while true {
            var peer = sockaddr()
            var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(fd, &peer, &peerLength)
            if client < 0 {
                lock.lock(); let shouldStop = stopped; lock.unlock()
                if shouldStop { return }
                continue
            }

            var request = Data()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(client, buffer.baseAddress, buffer.count)
                }
                if count <= 0 { break }
                request.append(contentsOf: bytes.prefix(count))
                if request.count > 8192 { break }
            }

            let prompt = String(data: request, encoding: .utf8) ?? ""
            let answer = DispatchQueue.main.sync { Self.response(for: prompt, password: password) } + "\n"
            let response = Data(answer.utf8)
            response.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                _ = Darwin.write(client, baseAddress, buffer.count)
            }
            Darwin.close(client)
        }
    }

    private static func response(for prompt: String, password: String) -> String {
        let normalized = prompt.lowercased()
        guard normalized.contains("continue connecting") || normalized.contains("yes/no") else {
            return password
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SSH sunucu anahtarını doğrula"
        alert.informativeText = "Bu sunucu bu Mac’te daha önce doğrulanmamış. Ekrandaki anahtar parmak izini kontrol edip güveniyorsanız devam edin.\n\n\(prompt)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Güven ve devam et")
        alert.addButton(withTitle: "İptal")
        return alert.runModal() == .alertFirstButtonReturn ? "yes" : "no"
    }

    private static func socketError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"])
    }
}

@MainActor
final class SSHMountController: ObservableObject, Identifiable {
    let id = UUID()
    @Published var host = ""
    @Published var port = "22"
    @Published var username = ""
    @Published var password = ""
    @Published var remotePath = "."
    @Published var mountPath = "~/Mounts/server1" {
        didSet {
            if mountPath != automaticMountPath { usesAutomaticMountPath = false }
        }
    }
    @Published private(set) var isMounted = false
    @Published private(set) var isWorking = false
    @Published private(set) var message = "SSH bağlantısı bekleniyor"
    @Published private(set) var messageIsError = false

    private var process: Process?
    private var broker: SSHAskpassBroker?
    private var stderr = SSHStderrCapture()
    private var mountedPath: String?
    private var finderAlias: String?
    private var automaticMountPath = "~/Mounts/server1"
    private var usesAutomaticMountPath = true

    var displayName: String {
        guard !host.isEmpty else { return "SSH Mount" }
        return "\(username.isEmpty ? "SSH" : username)@\(host)"
    }
    var hasManagedProcess: Bool { process?.isRunning == true || isMounted }

    func restoreMountedSession(path: String, alias: String) {
        host = String(alias.dropFirst("ssh-".count)).replacingOccurrences(of: "-", with: ".")
        mountPath = path
        automaticMountPath = path
        usesAutomaticMountPath = true
        mountedPath = path
        finderAlias = alias
        isMounted = true
        message = "Mevcut SSHFS bağlantısı bulundu"
        messageIsError = false
    }

    func setAutomaticMountPath() {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        automaticMountPath = "~/Mounts/\(name.isEmpty ? "server1" : name)"
        usesAutomaticMountPath = true
        mountPath = automaticMountPath
    }

    func updateAutomaticMountPathForHostChange() {
        if usesAutomaticMountPath { setAutomaticMountPath() }
    }

    func connect() {
        guard !isWorking, !isMounted else { return }
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = password
        let expandedMountPath = (mountPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleanHost.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil,
              cleanUser.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            setError("Sunucu adı/IP ve kullanıcı adını kontrol edin.")
            return
        }
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            setError("SSH portu 1–65535 arasında olmalı.")
            return
        }
        guard !cleanPassword.isEmpty else {
            setError("SSH parolasını girin.")
            return
        }
        guard !cleanRemotePath.isEmpty,
              !cleanRemotePath.contains("\n"), !cleanRemotePath.contains("\r"),
              !expandedMountPath.isEmpty, expandedMountPath.hasPrefix(NSHomeDirectory() + "/") else {
            setError("Uzak klasörü girin ve yerel bağlama konumunu kullanıcı klasörünüz altında seçin.")
            return
        }
        guard let sshfsURL = Self.sshfsURL else {
            setError("SSHFS bulunamadı. macFUSE ile kurulu sshfs çalıştırılabilir dosyası gerekli.")
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: expandedMountPath, withIntermediateDirectories: true)
            let contents = try FileManager.default.contentsOfDirectory(atPath: expandedMountPath)
            guard contents.isEmpty else {
                setError("Yerel bağlama klasörü boş olmalı. Başka bir klasör seçin.")
                return
            }
        } catch {
            setError("Yerel bağlama klasörü hazırlanamadı: \(error.localizedDescription)")
            return
        }
        guard !Self.isMounted(at: expandedMountPath) else {
            setError("Bu klasörde zaten bir disk bağlı.")
            return
        }

        let newBroker = SSHAskpassBroker(password: cleanPassword)
        let socketPath: String
        do {
            socketPath = try newBroker.start()
        } catch {
            setError(error.localizedDescription)
            return
        }

        let alias = Self.finderAlias(for: cleanHost)
        isWorking = true
        message = "Finder konumu hazırlanıyor…"
        messageIsError = false
        broker = newBroker
        mountedPath = expandedMountPath
        finderAlias = alias

        PrivilegedServiceClient.ensureFinderHostAlias(alias) { [weak self] result in
            guard let self else { return }
            guard self.isWorking else {
                newBroker.stop()
                PrivilegedServiceClient.removeFinderHostAlias(alias) { _ in }
                return
            }
            switch result {
            case .success:
                self.launchSSHFS(
                    sshfsURL: sshfsURL,
                    host: cleanHost,
                    username: cleanUser,
                    remotePath: cleanRemotePath,
                    mountPath: expandedMountPath,
                    port: portNumber,
                    finderAlias: alias,
                    broker: newBroker,
                    socketPath: socketPath
                )
            case .failure(let error):
                self.isWorking = false
                self.broker?.stop()
                self.broker = nil
                self.mountedPath = nil
                self.finderAlias = nil
                self.setError("Finder için yerel alias hazırlanamadı: \(error.localizedDescription)")
            }
        }
    }

    private func launchSSHFS(
        sshfsURL: URL,
        host: String,
        username: String,
        remotePath: String,
        mountPath: String,
        port: Int,
        finderAlias: String,
        broker newBroker: SSHAskpassBroker,
        socketPath: String
    ) {
        let volumeName = URL(fileURLWithPath: mountPath).lastPathComponent
            .replacingOccurrences(of: ",", with: "-")
            .replacingOccurrences(of: "\n", with: "-")
        let process = Process()
        process.executableURL = sshfsURL
        process.arguments = [
            "-f", "-p", String(port),
            "\(username)@\(host):\(remotePath)", mountPath,
            "-o", "reconnect",
            "-o", "volname=\(volumeName)",
            "-o", "location=\(finderAlias)"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NFSConnectSSHAskpass").path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["NFS_CONNECT_ASKPASS_SOCKET"] = socketPath
        environment["DISPLAY"] = environment["DISPLAY"] ?? "NFSConnect"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let errorPipe = Pipe()
        process.standardError = errorPipe
        stderr = SSHStderrCapture()
        let capture = stderr
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                capture.append(data)
            }
        }

        message = "SSH sunucusuna bağlanıyor…"
        messageIsError = false
        self.process = process
        process.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                guard let self, self.process === terminatedProcess else { return }
                self.isWorking = false
                self.isMounted = false
                if !self.messageIsError {
                    let detail = capture.message
                    self.setError(detail.isEmpty ? "SSHFS bağlantısı kapandı (\(terminatedProcess.terminationStatus))." : detail)
                }
                self.broker?.stop()
                self.broker = nil
                self.process = nil
                self.mountedPath = nil
                if let alias = self.finderAlias {
                    self.finderAlias = nil
                    PrivilegedServiceClient.removeFinderHostAlias(alias) { _ in }
                }
            }
        }

        do {
            try process.run()
            password = ""
            waitForMount(process: process, path: mountPath, capture: capture)
        } catch {
            isWorking = false
            self.process = nil
            newBroker.stop()
            self.broker = nil
            self.mountedPath = nil
            self.finderAlias = nil
            PrivilegedServiceClient.removeFinderHostAlias(finderAlias) { _ in }
            setError("SSHFS başlatılamadı: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        disconnect(completion: nil)
    }

    func disconnect(completion: ((Bool) -> Void)?) {
        unmount(force: false, completion: completion)
    }

    func forceDisconnect(completion: ((Bool) -> Void)? = nil) {
        unmount(force: true, completion: completion)
    }

    private func unmount(force: Bool, completion: ((Bool) -> Void)?) {
        guard !isWorking, let path = mountedPath else {
            completion?(false)
            return
        }
        isWorking = true
        message = force ? "SSH sürücüsü zorla ayrılıyor…" : "SSH bağlantısı ayrılıyor…"
        messageIsError = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = Self.run("/sbin/umount", arguments: [path])
            if !result.success && force {
                result = Self.run("/usr/sbin/diskutil", arguments: ["unmount", "force", path])
                if !result.success {
                    let fallback = Self.run("/sbin/umount", arguments: ["-f", path])
                    if fallback.success || !Self.isMounted(at: path) { result = fallback }
                }
                if !Self.isMounted(at: path) { result = (true, result.message, result.output) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isWorking = false
                if result.success {
                    self.process?.terminate()
                    self.broker?.stop()
                    self.broker = nil
                    self.process = nil
                    self.mountedPath = nil
                    self.isMounted = false
                    let alias = self.finderAlias
                    self.finderAlias = nil
                    if let alias {
                        self.isWorking = true
                        PrivilegedServiceClient.removeFinderHostAlias(alias) { cleanupResult in
                            self.isWorking = false
                            switch cleanupResult {
                            case .success:
                                self.message = "SSH sürücüsü ayrıldı"
                                self.messageIsError = false
                            case .failure(let error):
                                self.setError("Bağlantı ayrıldı; Finder alias temizlenemedi: \(error.localizedDescription)")
                            }
                            completion?(true)
                        }
                    } else {
                        self.message = "SSH sürücüsü ayrıldı"
                        self.messageIsError = false
                        completion?(true)
                    }
                } else {
                    self.setError(result.message.isEmpty ? "SSH sürücüsü ayrılamadı. Finder’da açık dosya veya pencere varsa kapatıp tekrar deneyin; gerekirse zorla ayırın." : result.message)
                    completion?(false)
                }
            }
        }
    }

    func stopForApplicationTermination(completion: @escaping (Bool) -> Void) {
        if let mountedPath, Self.isMounted(at: mountedPath) {
            isMounted = true
            isWorking = false
            disconnect(completion: completion)
            return
        }
        process?.terminate()
        broker?.stop()
        broker = nil
        process = nil
        mountedPath = nil
        isWorking = false
        isMounted = false
        let alias = finderAlias
        finderAlias = nil
        if let alias {
            PrivilegedServiceClient.removeFinderHostAlias(alias) { _ in completion(true) }
        } else {
            completion(true)
        }
    }

    func openMountFolder() {
        guard let mountedPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mountedPath))
    }

    private func waitForMount(process: Process, path: String, capture: SSHStderrCapture) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for _ in 0..<60 {
                if Self.isMounted(at: path) {
                    DispatchQueue.main.async {
                        guard let self, self.process === process else { return }
                        self.isWorking = false
                        self.isMounted = true
                        self.message = "\(path) konumuna bağlandı"
                        self.messageIsError = false
                    }
                    return
                }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                guard let self, self.process === process, !self.isMounted else { return }
                if process.isRunning {
                    self.isWorking = false
                    self.message = "Bağlantı sürüyor; SSH parolası veya sunucu onayı bekleniyor."
                } else {
                    let detail = capture.message
                    self.setError(detail.isEmpty ? "SSH sunucusuna bağlanılamadı." : detail)
                }
            }
        }
    }

    private func setError(_ text: String) {
        message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messageIsError = true
    }

    nonisolated private static var sshfsURL: URL? {
        let candidates = ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs", "/opt/local/bin/sshfs"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func finderAlias(for host: String) -> String {
        let sanitized = host.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(sanitized)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = String(collapsed.prefix(59)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "ssh-\(suffix.isEmpty ? "server" : suffix)"
    }

    nonisolated private static func isMounted(at path: String) -> Bool {
        let result = run("/sbin/mount", arguments: [])
        return result.output.split(separator: "\n").contains { $0.contains(" on \(path) (") }
    }

    nonisolated fileprivate static func recoveredMounts() -> [(path: String, alias: String)] {
        let listing = run("/sbin/mount", arguments: []).output
        return listing.split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: " on "),
                  let options = line.range(of: " (nfs,") else { return nil }
            let source = String(line[..<marker.lowerBound])
            guard let separator = source.firstIndex(of: ":") else { return nil }
            let alias = String(source[..<separator])
            guard alias.hasPrefix("ssh-") else { return nil }
            let path = String(line[marker.upperBound..<options.lowerBound])
            guard path.hasPrefix(NSHomeDirectory() + "/") else { return nil }
            return (path, alias)
        }
    }

    nonisolated private static func run(_ executable: String, arguments: [String]) -> (success: Bool, message: String, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, err.trimmingCharacters(in: .whitespacesAndNewlines), out)
        } catch {
            return (false, error.localizedDescription, "")
        }
    }
}

@MainActor
final class SSHMountManager: ObservableObject {
    @Published private(set) var mounts: [SSHMountController] = []
    private var observations: [UUID: AnyCancellable] = [:]

    init() {
        for mount in SSHMountController.recoveredMounts() {
            let controller = SSHMountController()
            controller.restoreMountedSession(path: mount.path, alias: mount.alias)
            add(controller)
        }
    }

    var isMounted: Bool { mounts.contains(where: \.isMounted) }
    var hasManagedProcess: Bool { mounts.contains(where: \.hasManagedProcess) }

    func add(_ controller: SSHMountController) {
        guard !mounts.contains(where: { $0.id == controller.id }) else { return }
        mounts.append(controller)
        observations[controller.id] = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func removeIfIdle(_ controller: SSHMountController) {
        guard !controller.hasManagedProcess else { return }
        mounts.removeAll { $0.id == controller.id }
        observations[controller.id] = nil
    }

    func stopForApplicationTermination(completion: @escaping (Bool) -> Void) {
        let active = mounts.filter(\.hasManagedProcess)
        stop(active, at: 0, completion: completion)
    }

    private func stop(_ active: [SSHMountController], at index: Int, completion: @escaping (Bool) -> Void) {
        guard index < active.count else { completion(true); return }
        active[index].stopForApplicationTermination { [weak self] success in
            guard success else { completion(false); return }
            self?.stop(active, at: index + 1, completion: completion)
        }
    }
}

private final class SSHStderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(newData)
    }

    var message: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct SSHMountManagerSheet: View {
    @ObservedObject var manager: SSHMountManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SSHMountController?
    @State private var forceTarget: SSHMountController?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.105), Color(red: 0.055, green: 0.08, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(Color.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SSH Mount").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        Text("Birden fazla SSHFS bağlantısını yönetin").font(.system(size: 11)).foregroundStyle(.white.opacity(0.54))
                    }
                    Spacer()
                    Button("Kapat") { dismiss() }.buttonStyle(SecondaryGlassButtonStyle())
                }

                if manager.mounts.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "externaldrive.badge.plus").font(.system(size: 26)).foregroundStyle(Color.cyan.opacity(0.8))
                        Text("Henüz SSH mount yok").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 18).glassPanel(radius: 16)
                } else {
                    VStack(spacing: 8) {
                        ForEach(manager.mounts) { mount in
                            HStack(spacing: 10) {
                                Image(systemName: mount.isMounted ? "externaldrive.fill.badge.checkmark" : "terminal")
                                    .foregroundStyle(mount.isMounted ? Color.cyan : Color.white.opacity(0.6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mount.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                    Text(mount.messageIsError ? mount.message : (mount.isMounted ? mount.mountPath : mount.message))
                                        .font(.system(size: 10, design: mount.messageIsError ? .default : .monospaced))
                                        .foregroundStyle(mount.messageIsError ? Color.orange : Color.white.opacity(0.52))
                                        .lineLimit(2).textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                                if mount.isMounted {
                                    Button { mount.openMountFolder() } label: { Image(systemName: "folder") }
                                        .buttonStyle(SecondaryGlassButtonStyle()).help("Klasörü Aç")
                                    Button { mount.disconnect() } label: { Image(systemName: "eject") }
                                        .buttonStyle(SecondaryGlassButtonStyle()).help("Ayır")
                                        .disabled(mount.isWorking)
                                    Button { forceTarget = mount } label: { Image(systemName: "eject.fill") }
                                        .buttonStyle(SecondaryGlassButtonStyle()).help("Zorla Ayır")
                                        .disabled(mount.isWorking)
                                } else if mount.isWorking {
                                    ProgressView().controlSize(.small).tint(.cyan)
                                } else {
                                    Button { manager.removeIfIdle(mount) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(SecondaryGlassButtonStyle()).help("Listeden Kaldır")
                                }
                            }
                            .padding(10).glassPanel(radius: 12)
                        }
                    }
                }

                Button {
                    let controller = SSHMountController()
                    controller.setAutomaticMountPath()
                    draft = controller
                } label: {
                    Label("Yeni SSH Mount", systemImage: "plus.link")
                        .frame(maxWidth: .infinity).frame(height: 38)
                }
                .buttonStyle(PrimaryGlassButtonStyle())
                Text("Parolalar yalnızca bağlantı süresince bellekte tutulur.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.38))
            }
            .padding(16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(CompactWindowFrame())
        .preferredColorScheme(.dark)
        .sheet(item: $draft) { controller in
            SSHMountSheet(controller: controller, existingMountPaths: manager.mounts.map(\.mountPath)) {
                manager.add(controller)
                draft = nil
            }
        }
        .alert("SSH sürücüsünü zorla ayır?", isPresented: Binding(
            get: { forceTarget != nil },
            set: { if !$0 { forceTarget = nil } }
        )) {
            Button("İptal", role: .cancel) { forceTarget = nil }
            Button("Zorla Ayır", role: .destructive) {
                forceTarget?.forceDisconnect()
                forceTarget = nil
            }
        } message: {
            Text("Açık dosya işlemleri kesilebilir. macOS force unmount uygulayacak.")
        }
    }
}

struct SSHMountSheet: View {
    @ObservedObject var controller: SSHMountController
    var existingMountPaths: [String] = []
    var onConnected: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingForceUnmount = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.105), Color(red: 0.055, green: 0.08, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: controller.isMounted ? "externaldrive.fill.badge.checkmark" : "terminal")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(controller.isMounted ? Color.cyan : Color.white.opacity(0.85))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SSH Mount").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        Text("Linux sunucusuna SSHFS ile bağlan")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.54))
                    }
                    Spacer()
                    Button("Kapat") { dismiss() }.buttonStyle(SecondaryGlassButtonStyle())
                }

                VStack(alignment: .leading, spacing: 10) {
                    formField("Sunucu", icon: "server.rack") {
                        TextField("192.168.1.100 veya server.example.com", text: $controller.host)
                            .disabled(controller.isWorking || controller.isMounted)
                            .onChange(of: controller.host) { _, _ in
                                controller.updateAutomaticMountPathForHostChange()
                            }
                    }
                    HStack(spacing: 10) {
                        formField("Kullanıcı adı", icon: "person") {
                            TextField("ince", text: $controller.username)
                                .disabled(controller.isWorking || controller.isMounted)
                        }
                        formField("Port", icon: "number") {
                            TextField("22", text: $controller.port)
                                .frame(width: 50)
                                .disabled(controller.isWorking || controller.isMounted)
                        }
                    }
                    formField("Parola", icon: "lock") {
                        SecureField("SSH parolası", text: $controller.password)
                            .disabled(controller.isWorking || controller.isMounted)
                    }
                    formField("Sunucudaki klasör", icon: "folder") {
                        TextField(". (kullanıcı klasörü)", text: $controller.remotePath)
                            .disabled(controller.isWorking || controller.isMounted)
                    }
                    formField("Mac’te bağlama konumu", icon: "externaldrive") {
                        TextField("~/Mounts/server1", text: $controller.mountPath)
                            .disabled(controller.isWorking || controller.isMounted)
                        Button("Otomatik") { controller.setAutomaticMountPath() }
                            .font(.system(size: 10, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.cyan)
                            .disabled(controller.isWorking || controller.isMounted)
                    }
                }
                .padding(14)
                .glassPanel(radius: 18)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: controller.messageIsError ? "exclamationmark.triangle" : (controller.isMounted ? "checkmark.circle" : "lock.shield"))
                    Text(controller.message)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundStyle(controller.messageIsError ? Color.orange : Color.white.opacity(0.62))

                HStack(spacing: 10) {
                    if controller.isMounted {
                        Button(action: controller.openMountFolder) {
                            Label("Klasörü Aç", systemImage: "folder")
                                .frame(maxWidth: .infinity).frame(height: 38)
                        }
                        .buttonStyle(SecondaryGlassButtonStyle())
                        Button(action: controller.disconnect) {
                            Label(controller.isWorking ? "Ayrılıyor…" : "Ayır", systemImage: "eject")
                                .frame(maxWidth: .infinity).frame(height: 38)
                        }
                        .buttonStyle(PrimaryGlassButtonStyle())
                        .disabled(controller.isWorking)
                        Button(action: { confirmingForceUnmount = true }) {
                            Label("Zorla Ayır", systemImage: "eject.fill")
                                .frame(maxWidth: .infinity).frame(height: 38)
                        }
                        .buttonStyle(SecondaryGlassButtonStyle())
                        .disabled(controller.isWorking)
                    } else {
                        Button(action: connect) {
                            HStack(spacing: 8) {
                                if controller.isWorking { ProgressView().controlSize(.small).tint(.white) }
                                else { Image(systemName: "link") }
                                Text(controller.isWorking ? "Bağlanıyor…" : "SSH Mount")
                            }
                            .frame(maxWidth: .infinity).frame(height: 38)
                        }
                        .buttonStyle(PrimaryGlassButtonStyle())
                        .disabled(controller.isWorking)
                    }
                }
                Text("Parola yalnızca bu bağlantı süresince bellekte tutulur.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.38))
            }
            .padding(18)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(CompactWindowFrame())
        .preferredColorScheme(.dark)
        .alert("SSH sürücüsünü zorla ayır?", isPresented: $confirmingForceUnmount) {
            Button("İptal", role: .cancel) { }
            Button("Zorla Ayır", role: .destructive) { controller.forceDisconnect() }
        } message: {
            Text("Açık dosya işlemleri kesilebilir. Normal ayırma başarısız olduğunda macOS diskutil ile forced unmount denenir.")
        }
        .onChange(of: controller.isMounted) { _, mounted in
            if mounted { onConnected?() }
        }
    }

    private func formField<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.white.opacity(0.42)).frame(width: 16)
                content()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 9).frame(height: 32)
            .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.075), lineWidth: 1))
        }
    }

    private func connect() {
        let requestedPath = (controller.mountPath as NSString).expandingTildeInPath
        let usedPaths = Set(existingMountPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path })
        var candidate = URL(fileURLWithPath: requestedPath).standardizedFileURL
        let base = candidate.lastPathComponent
        var suffix = 2
        while usedPaths.contains(candidate.path) {
            candidate = candidate.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        if candidate.path != URL(fileURLWithPath: requestedPath).standardizedFileURL.path {
            controller.mountPath = candidate.path
        }
        controller.connect()
    }
}
