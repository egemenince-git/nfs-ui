import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct NFSConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ConnectionModel()
    @StateObject private var sshMount = SSHMountManager()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model, sshMount: sshMount)
                .frame(minWidth: 420)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.openMainWindow = { openWindow(id: "main") }
                    appDelegate.observeConnection(model, sshMount: sshMount)
                    DispatchQueue.main.async {
                        NSApplication.shared.keyWindow?.setContentSize(NSSize(width: 460, height: 520))
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var openMainWindow: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var connectionObservation: AnyCancellable?
    private var sshObservation: AnyCancellable?
    private weak var sshMountManager: SSHMountManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "NFS Connect")
        item.button?.toolTip = "NFS Connect"
        item.menu = makeStatusMenu()
        statusItem = item
        updateStatusIcon(isMounted: false)
    }

    func observeConnection(_ model: ConnectionModel, sshMount: SSHMountManager) {
        sshMountManager = sshMount
        connectionObservation = model.$isMounted.sink { [weak self] isMounted in
            self?.updateStatusIcon(isMounted: isMounted || sshMount.isMounted)
        }
        sshObservation = sshMount.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusIcon(isMounted: sshMount.isMounted || model.isMounted)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sshMountManager, sshMountManager.hasManagedProcess else { return .terminateNow }
        sshMountManager.stopForApplicationTermination { didDisconnect in
            NSApplication.shared.reply(toApplicationShouldTerminate: didDisconnect)
        }
        return .terminateLater
    }

    private func updateStatusIcon(isMounted: Bool) {
        guard let button = statusItem?.button else { return }
        let description = isMounted ? "NFS Connect — Bağlı" : "NFS Connect — Bağlı değil"
        guard let symbol = NSImage(
            systemSymbolName: "externaldrive.connected.to.line.below",
            accessibilityDescription: description
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)) else { return }

        if isMounted {
            let coloredSymbol = NSImage(size: symbol.size)
            coloredSymbol.lockFocus()
            let bounds = NSRect(origin: .zero, size: symbol.size)
            symbol.draw(in: bounds)
            NSColor.systemBlue.set()
            bounds.fill(using: .sourceAtop)
            coloredSymbol.unlockFocus()
            coloredSymbol.isTemplate = false
            button.image = coloredSymbol
        } else {
            symbol.isTemplate = true
            button.image = symbol
        }
        button.toolTip = isMounted ? "NFS Connect — Bağlı" : "NFS Connect — Bağlı değil"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func menuWillOpen(_ menu: NSMenu) { populateStatusMenu(menu) }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populateStatusMenu(menu)
        return menu
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Ayarlar", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
    }

    @objc private func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "NFS Connect" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

@MainActor
final class ConnectionModel: ObservableObject {
    @Published var server = "192.168.3.6:/nfs_server"
    @Published var mountPoint = "\(NSHomeDirectory())/nfs_server"
    @Published private(set) var isMounted = false
    @Published private(set) var isWorking = false
    @Published private(set) var message = "Bağlantı bekleniyor"
    @Published private(set) var messageIsError = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var helperStatus = SMAppService.daemon(plistName: nfsPrivilegedDaemonPlist).status

    private var refreshTimer: Timer?
    private let privilegedService = SMAppService.daemon(plistName: nfsPrivilegedDaemonPlist)

    var privilegedServiceReady: Bool { helperStatus == .enabled }
    var privilegedServiceLabel: String {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            return "Uygulamayı /Applications’a taşıyıp oradan açın"
        }
        return switch helperStatus {
        case .enabled: "Yetkili servis etkin"
        case .requiresApproval: "Sistem Ayarları’nda onay bekliyor"
        case .notFound: "macOS servis kaydı henüz oluşturulmadı"
        case .notRegistered: "İlk kurulum için bir kez onay gerekir"
        @unknown default: "Servis durumu denetlenemedi"
        }
    }

    init() {
        refreshStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        guard !isWorking else { return }
        helperStatus = privilegedService.status
        isMounted = Self.mounted(at: mountPoint)
        if isMounted {
            if !messageIsError {
                message = "Bağlı ve kullanıma hazır"
            }
        } else if messageIsError == false {
            message = "Bağlantı bekleniyor"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            setError("Girişte çalıştır ayarı değiştirilemedi: \(error.localizedDescription)")
        }
    }

    func preparePrivilegedService() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            setError("Kök servis güvenli konumdan çalışmalı. NFS Connect.app’i /Applications klasörüne taşıyıp oradan açın.")
            return
        }
        if privilegedService.status == .enabled {
            do {
                try privilegedService.unregister()
            } catch {
                setError("Yetkili servis yenilenemedi: \(error.localizedDescription)")
                return
            }
        }
        do {
            try privilegedService.register()
        } catch {
            helperStatus = privilegedService.status
            if helperStatus != .requiresApproval && helperStatus != .enabled {
                setError("Yetkili servis kaydedilemedi: \(error.localizedDescription)")
                return
            }
        }
        helperStatus = privilegedService.status
        if helperStatus == .requiresApproval {
            message = "Sistem Ayarları > Genel > Giriş Öğeleri bölümünde NFS Connect servisini etkinleştirin."
            messageIsError = false
            SMAppService.openSystemSettingsLoginItems()
        } else if helperStatus == .enabled {
            message = "Yetkili NFS servisi hazır."
            messageIsError = false
        }
    }

    func connect() {
        guard !isWorking else { return }
        let export = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = (mountPoint as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !export.isEmpty, !destination.isEmpty else {
            setError("Sunucu ve bağlama yolu boş bırakılamaz.")
            return
        }
        guard privilegedServiceReady else {
            setError("Önce Ayarlar bölümünden yetkili NFS servisini kurup etkinleştirin.")
            return
        }
        guard export.contains(":/") else {
            setError("Sunucu adresini sunucu:/paylaşım biçiminde girin.")
            return
        }

        isWorking = true
        message = "Bağlanıyor…"
        messageIsError = false
        do {
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        } catch {
            isWorking = false
            setError("Bağlama klasörü oluşturulamadı: \(error.localizedDescription)")
            return
        }

        PrivilegedServiceClient.mount(server: export, at: destination) { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success(let detail):
                self.isMounted = true
                self.message = detail.isEmpty ? "\(destination) konumuna bağlandı" : detail
                self.messageIsError = false
            case .failure(let error):
                self.setError(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        guard !isWorking else { return }
        let destination = (mountPoint as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            setError("Bağlama yolu boş bırakılamaz.")
            return
        }
        guard privilegedServiceReady else {
            setError("Önce Ayarlar bölümünden yetkili NFS servisini kurup etkinleştirin.")
            return
        }
        guard Self.mounted(at: destination) else {
            isMounted = false
            message = "Bu konumda etkin NFS bağlantısı yok"
            messageIsError = false
            return
        }

        isWorking = true
        message = "Bağlantı kapatılıyor…"
        messageIsError = false
        PrivilegedServiceClient.unmount(at: destination) { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success(let detail):
                self.isMounted = false
                self.message = detail.isEmpty ? "Bağlantı kapatıldı" : detail
                self.messageIsError = false
            case .failure(let error):
                self.setError(error.localizedDescription)
            }
        }
    }

    private func setError(_ text: String) {
        message = text
        messageIsError = true
    }

    private static func mounted(at path: String) -> Bool {
        let expandedPath = (path as NSString).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let listing = String(data: data, encoding: .utf8) ?? ""
            return listing.split(separator: "\n").contains { $0.contains(" on \(expandedPath) (") }
        } catch {
            return false
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var sshMount: SSHMountManager
    @FocusState private var focusedField: Field?
    @State private var showingSSHMount = false

    private enum Field: Hashable { case server, mount }

    var body: some View {
        ZStack(alignment: .top) {
            background
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    hero
                    connectionCard
                    settingsCard
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 4)
            }
        }
        .frame(minWidth: 420)
        .background(CompactWindowFrame())
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .onTapGesture { focusedField = nil }
        .sheet(isPresented: $showingSSHMount) {
            SSHMountManagerSheet(manager: sshMount)
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.105), Color(red: 0.055, green: 0.08, blue: 0.15), Color(red: 0.035, green: 0.045, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.cyan.opacity(0.17)).frame(width: 300).blur(radius: 100).offset(x: 210, y: -250)
            Circle().fill(Color.blue.opacity(0.16)).frame(width: 320).blur(radius: 110).offset(x: -230, y: 180)
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.12)).frame(width: 52, height: 52).blur(radius: 12)
                Circle().fill(.white.opacity(0.055)).frame(width: 42, height: 42)
                    .overlay(Circle().stroke(.white.opacity(0.13), lineWidth: 1))
                Image(systemName: model.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(model.isMounted ? Color.cyan : Color.white.opacity(0.88), Color.white.opacity(0.36))
                    .font(.system(size: 19, weight: .light))
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NFS Connect")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(.white)
                Text("Ağ sürücünüz, tek dokunuş uzağınızda.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer(minLength: 0)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(model.isMounted ? Color.green.opacity(0.13) : Color.white.opacity(0.075))
                        .frame(width: 32, height: 32)
                    Image(systemName: model.isMounted ? "checkmark.circle.fill" : "network")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.isMounted ? Color.green : Color.cyan.opacity(0.9))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isMounted ? "Bağlantı etkin" : "Bağlantı durumu")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.93))
                    Text(model.message)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(model.messageIsError ? Color.orange : Color.white.opacity(0.52))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 6)
                Text(model.isMounted ? "BAĞLI" : "HAZIR")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(model.isMounted ? Color.green : Color.white.opacity(0.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background((model.isMounted ? Color.green : Color.white).opacity(0.09), in: Capsule())
            }
            HStack(spacing: 11) {
                Button(action: model.connect) {
                    HStack(spacing: 8) {
                        if model.isWorking { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "link") }
                        Text(model.isWorking ? "İşleniyor" : "Bağlan")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                }
                .buttonStyle(PrimaryGlassButtonStyle())
                .disabled(model.isMounted || model.isWorking)
                Button {
                    showingSSHMount = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sshMount.isMounted ? "externaldrive.fill.badge.checkmark" : "terminal")
                        Text(sshMount.isMounted ? "SSH bağlı" : "SSH Mount")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                }
                .buttonStyle(SecondaryGlassButtonStyle())
                Button(action: model.disconnect) {
                    HStack(spacing: 8) {
                        Image(systemName: "link.badge.minus")
                        Text("Ayır")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                }
                .buttonStyle(SecondaryGlassButtonStyle())
                .disabled(!model.isMounted || model.isWorking)
            }
        }
        .padding(12)
        .glassPanel(radius: 22)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(Color.cyan.opacity(0.85))
                Text("BAĞLANTI AYARLARI")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.55))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Sunucu paylaşımı").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").foregroundStyle(.white.opacity(0.4)).frame(width: 16)
                    TextField("192.168.3.6:/nfs_server", text: $model.server)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .focused($focusedField, equals: .server)
                        .disabled(model.isWorking || model.isMounted)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.075), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Mac üzerindeki konum").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.white.opacity(0.4)).frame(width: 16)
                    TextField("~/nfs_server", text: $model.mountPoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .focused($focusedField, equals: .mount)
                        .disabled(model.isWorking || model.isMounted)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.075), lineWidth: 1))
            }
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Label("Girişte çalıştır", systemImage: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Button(action: model.preparePrivilegedService) {
                HStack(spacing: 8) {
                    Image(systemName: model.privilegedServiceReady ? "arrow.clockwise.circle" : "lock.shield")
                        .foregroundStyle(model.privilegedServiceReady ? Color.green : Color.cyan.opacity(0.85))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.privilegedServiceReady ? "Yetkili servisi yenile" : "Yetkili servisi kur")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                        if !model.privilegedServiceReady {
                            Text(model.privilegedServiceLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                    }
                    Spacer()
                    Image(systemName: model.privilegedServiceReady ? "arrow.clockwise" : "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 11))
                Text(model.privilegedServiceReady
                     ? "Servis macOS’ta bir kez onaylandı; bağlantı için parola gerekmez."
                     : "İlk kurulumda macOS servis onayı gerekir.")
                    .font(.system(size: 11, weight: .regular))
            }
            .foregroundStyle(.white.opacity(0.42))
            .padding(.top, 1)
        }
        .padding(12)
        .glassPanel(radius: 22)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi").font(.system(size: 10))
            Text(sshMount.isMounted ? "NFS v3  ·  SSHFS bağlı" : "NFS v3  ·  resvport")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(0.6)
        }
        .foregroundStyle(.white.opacity(0.35))
        .padding(.top, 1)
    }
}

struct CompactWindowFrame: NSViewRepresentable {
    var height: CGFloat = 510
    func makeNSView(context: Context) -> CompactWindowFrameView { CompactWindowFrameView(height: height) }
    func updateNSView(_ view: CompactWindowFrameView, context: Context) { view.height = height }
}

final class CompactWindowFrameView: NSView {
    var height: CGFloat
    private var resizedWindow: ObjectIdentifier?

    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        height = 510
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let targetWindow = window, resizedWindow != ObjectIdentifier(targetWindow) else { return }
        resizedWindow = ObjectIdentifier(targetWindow)
        DispatchQueue.main.async {
            let currentFrame = targetWindow.frame
            let compactFrame = NSRect(x: currentFrame.minX,
                                      y: currentFrame.maxY - self.height,
                                      width: 480,
                                      height: self.height)
            targetWindow.setFrame(compactFrame, display: true, animate: false)
        }
    }
}

struct PrimaryGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.98))
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(LinearGradient(colors: [Color.cyan.opacity(configuration.isPressed ? 0.47 : 0.62), Color.blue.opacity(configuration.isPressed ? 0.45 : 0.58)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.26), lineWidth: 1))
                    .shadow(color: .cyan.opacity(0.17), radius: 14, y: 5)
            }
            .opacity(configuration.isPressed ? 0.84 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct SecondaryGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.86))
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(.white.opacity(configuration.isPressed ? 0.12 : 0.07))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.12), lineWidth: 1))
            }
            .opacity(isEnabled ? 1 : 0.38)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder
    func glassPanel(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.13), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 20, y: 12)
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 20, y: 12)
        }
    }
}
