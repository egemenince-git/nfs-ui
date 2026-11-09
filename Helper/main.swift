import Foundation
import Security
import Darwin

private let allowedClientRequirement = "identifier \"com.egemenince.NFSConnect\" and anchor apple generic and certificate leaf[subject.OU] = \"99U7KZC748\""

private final class ServiceHost: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: nfsPrivilegedServiceName)
    private let service = NFSPrivilegedService()

    func run() -> Never {
        listener.delegate = self
        listener.resume()
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0,
              CodeSignatureValidator.isTrustedClient(pid: connection.processIdentifier) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: NFSPrivilegedServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private enum CodeSignatureValidator {
    static func isTrustedClient(pid: pid_t) -> Bool {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(allowedClientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

private final class NFSPrivilegedService: NSObject, NFSPrivilegedServiceProtocol {
    private static let hostsURL = URL(fileURLWithPath: "/etc/hosts")
    private static let finderAliasMarker = "# NFS Connect SSHFS"

    func mount(server: String, at mountPoint: String, withReply reply: @escaping (Bool, String) -> Void) {
        guard Self.isValidExport(server) else {
            reply(false, "NFS adresi geçersiz.")
            return
        }
        guard let safeMountPoint = Self.validatedMountPoint(mountPoint, for: currentUserID) else {
            reply(false, "Bağlama konumu kullanıcı klasörü içinde güvenli bir klasör olmalı.")
            return
        }
        if let existingMount = Self.mountedEntry(at: safeMountPoint) {
            if existingMount.contains(" (nfs") {
                reply(true, "NFS zaten bağlı.")
            } else {
                reply(false, "Bağlama konumu başka bir dosya sistemi tarafından kullanılıyor.")
            }
            return
        }
        let result = Self.run("/sbin/mount", ["-t", "nfs", "-o", "vers=3,resvport", server, safeMountPoint])
        reply(result.success, result.message)
    }

    func unmount(at mountPoint: String, withReply reply: @escaping (Bool, String) -> Void) {
        guard let safeMountPoint = Self.validatedMountPoint(mountPoint, for: currentUserID) else {
            reply(false, "Bağlama konumu kullanıcı klasörü içinde güvenli bir klasör olmalı.")
            return
        }
        guard let existingMount = Self.mountedEntry(at: safeMountPoint) else {
            reply(true, "Bu konumda NFS bağlantısı yok.")
            return
        }
        guard existingMount.contains(" (nfs") else {
            reply(false, "Bu konumdaki dosya sistemi NFS değil; ayırma yapılmadı.")
            return
        }
        let normal = Self.run("/sbin/umount", [safeMountPoint])
        if normal.success {
            reply(true, normal.message)
            return
        }
        let forced = Self.run("/sbin/umount", ["-f", safeMountPoint])
        reply(forced.success, forced.message.isEmpty ? normal.message : forced.message)
    }

    func ensureFinderHostAlias(_ alias: String, withReply reply: @escaping (Bool, String) -> Void) {
        guard Self.isValidFinderAlias(alias) else {
            reply(false, "Finder alias biçimi geçersiz.")
            return
        }
        do {
            var contents = try String(contentsOf: Self.hostsURL, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)
            for line in lines {
                let activeLine = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let fields = activeLine.split(whereSeparator: \.isWhitespace)
                guard fields.dropFirst().contains(where: { String($0).caseInsensitiveCompare(alias) == .orderedSame }) else { continue }
                guard fields.first == "127.0.0.1" else {
                    reply(false, "Finder alias /etc/hosts içinde başka bir adrese bağlı.")
                    return
                }
                if line.contains(Self.finderAliasMarker) {
                    reply(true, "Finder alias hazır.")
                    return
                }
                // Keep user-managed localhost aliases intact; do not claim ownership.
                reply(true, "Finder alias zaten yerel adrese bağlı.")
                return
            }
            if !contents.isEmpty && !contents.hasSuffix("\n") { contents.append("\n") }
            contents.append("127.0.0.1 \(alias) \(Self.finderAliasMarker)\n")
            try Self.writeHostsFile(contents)
            Self.flushResolverCache()
            reply(true, "Finder alias hazır.")
        } catch {
            reply(false, "Finder alias /etc/hosts dosyasına eklenemedi: \(error.localizedDescription)")
        }
    }

    func removeFinderHostAlias(_ alias: String, withReply reply: @escaping (Bool, String) -> Void) {
        guard Self.isValidFinderAlias(alias) else {
            reply(false, "Finder alias biçimi geçersiz.")
            return
        }
        do {
            if Self.finderAliasIsMounted(alias) {
                reply(true, "Finder alias diğer bağlı SSHFS mount’ları için korundu.")
                return
            }
            let contents = try String(contentsOf: Self.hostsURL, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)
            let filtered = lines.filter { line in
                guard line.contains(Self.finderAliasMarker) else { return true }
                let activeLine = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let fields = activeLine.split(whereSeparator: \.isWhitespace)
                return !fields.dropFirst().contains(where: { String($0).caseInsensitiveCompare(alias) == .orderedSame })
            }
            let updated = filtered.joined(separator: "\n")
            if updated != contents {
                try Self.writeHostsFile(updated.hasSuffix("\n") ? updated : updated + "\n")
                Self.flushResolverCache()
            }
            reply(true, "Finder alias temizlendi.")
        } catch {
            reply(false, "Finder alias /etc/hosts dosyasından kaldırılamadı: \(error.localizedDescription)")
        }
    }

    private var currentUserID: uid_t {
        NSXPCConnection.current()?.effectiveUserIdentifier ?? 0
    }

    private static func isValidExport(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: ":") else { return false }
        let host = String(value[..<separator])
        let export = String(value[value.index(after: separator)...])
        guard !host.isEmpty, !host.hasPrefix("-"), !export.isEmpty, export.hasPrefix("/") else { return false }
        let hostAllowed = host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
        let pathAllowed = export.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil
        return hostAllowed && pathAllowed && !export.split(separator: "/").contains("..")
    }

    private static func isValidFinderAlias(_ alias: String) -> Bool {
        alias.range(of: "^ssh-[a-z0-9-]{1,59}$", options: .regularExpression) != nil
    }

    private static func finderAliasIsMounted(_ alias: String) -> Bool {
        let result = run("/sbin/mount", [])
        return result.output.split(separator: "\n").contains { line in
            line.hasPrefix("\(alias):") || line.contains("location=\(alias)")
        }
    }

    private static func writeHostsFile(_ contents: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: hostsURL.path)
        try Data(contents.utf8).write(to: hostsURL, options: .atomic)
        var preserved: [FileAttributeKey: Any] = [:]
        for key in [.posixPermissions, .ownerAccountID, .groupOwnerAccountID] as [FileAttributeKey] {
            if let value = attributes[key] { preserved[key] = value }
        }
        try FileManager.default.setAttributes(preserved, ofItemAtPath: hostsURL.path)
    }

    private static func flushResolverCache() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-flushcache"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func validatedMountPoint(_ input: String, for uid: uid_t) -> String? {
        guard uid > 0, input.hasPrefix("/"), !input.contains("\n"), !input.contains("\r") else { return nil }
        guard let userHome = homeDirectory(for: uid) else { return nil }
        let standardizedHome = URL(fileURLWithPath: userHome).standardizedFileURL.path
        let requested = URL(fileURLWithPath: input).standardizedFileURL
        guard requested.path.hasPrefix(standardizedHome + "/") else { return nil }
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == standardizedHome || parent.hasPrefix(standardizedHome + "/") else { return nil }
        if mountedEntry(at: requested.path) != nil { return requested.path }
        let resolved = requested.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(standardizedHome + "/") else { return nil }
        var info = stat()
        guard lstat(resolved.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == uid else { return nil }
        return resolved.path
    }

    private static func homeDirectory(for uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let path = entry.pointee.pw_dir else { return nil }
        return String(cString: path)
    }

    private static func mountedEntry(at path: String) -> String? {
        let result = run("/sbin/mount", [])
        return result.output.split(separator: "\n").first { $0.contains(" on \(path) (") }.map(String.init)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (success: Bool, message: String, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let output = (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = process.terminationStatus == 0
            return (status, output.isEmpty ? (status ? "İşlem tamamlandı." : "NFS işlemi başarısız oldu.") : output, out)
        } catch {
            return (false, error.localizedDescription, "")
        }
    }
}

private let serviceHost = ServiceHost()
serviceHost.run()
