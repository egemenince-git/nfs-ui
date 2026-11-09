import Foundation

enum PrivilegedServiceClient {
    // The embedded command-line helper is signed with its executable name as
    // the code identifier (it has no bundle Info.plist).
    private static let helperRequirement = "identifier \"NFSConnectPrivilegedHelper\" and anchor apple generic and certificate leaf[subject.OU] = \"99U7KZC748\""

    static func mount(server: String, at mountPoint: String, completion: @escaping (Result<String, Error>) -> Void) {
        withService(completion) { service, finish in
            service.mount(server: server, at: mountPoint) { success, message in
                finish(success, message)
            }
        }
    }

    static func unmount(at mountPoint: String, completion: @escaping (Result<String, Error>) -> Void) {
        withService(completion) { service, finish in
            service.unmount(at: mountPoint) { success, message in
                finish(success, message)
            }
        }
    }

    static func ensureFinderHostAlias(_ alias: String, completion: @escaping (Result<String, Error>) -> Void) {
        withService(completion) { service, finish in
            service.ensureFinderHostAlias(alias) { success, message in
                finish(success, message)
            }
        }
    }

    static func removeFinderHostAlias(_ alias: String, completion: @escaping (Result<String, Error>) -> Void) {
        withService(completion) { service, finish in
            service.removeFinderHostAlias(alias) { success, message in
                finish(success, message)
            }
        }
    }

    private static func withService(
        _ completion: @escaping (Result<String, Error>) -> Void,
        invoke: @escaping (NFSPrivilegedServiceProtocol, @escaping (Bool, String) -> Void) -> Void
    ) {
        let connection = NSXPCConnection(machServiceName: nfsPrivilegedServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: NFSPrivilegedServiceProtocol.self)
        connection.setCodeSigningRequirement(helperRequirement)
        connection.invalidationHandler = {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "NFSConnect.Service", code: 1, userInfo: [NSLocalizedDescriptionKey: "Yetkili NFS servisine bağlanılamadı. Servisin Sistem Ayarları’nda etkin olduğunu doğrulayın."])))
            }
        }
        connection.activate()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            connection.invalidationHandler = nil
            connection.invalidate()
            DispatchQueue.main.async { completion(.failure(error)) }
        }
        guard let service = proxy as? NFSPrivilegedServiceProtocol else {
            connection.invalidate()
            completion(.failure(NSError(domain: "NFSConnect.Service", code: 2, userInfo: [NSLocalizedDescriptionKey: "NFS servisi kullanılamıyor."])))
            return
        }
        invoke(service) { success, message in
            connection.invalidationHandler = nil
            connection.invalidate()
            DispatchQueue.main.async {
                if success { completion(.success(message)) }
                else { completion(.failure(NSError(domain: "NFSConnect.Service", code: 3, userInfo: [NSLocalizedDescriptionKey: message]))) }
            }
        }
    }
}
