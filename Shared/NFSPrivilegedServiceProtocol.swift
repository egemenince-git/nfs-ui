import Foundation

let nfsPrivilegedServiceName = "com.egemenince.NFSConnect.PrivilegedHelper"
let nfsPrivilegedDaemonPlist = "com.egemenince.NFSConnect.PrivilegedHelper.plist"

@objc(NFSPrivilegedServiceProtocol) protocol NFSPrivilegedServiceProtocol {
    func mount(server: String, at mountPoint: String, withReply reply: @escaping (Bool, String) -> Void)
    func unmount(at mountPoint: String, withReply reply: @escaping (Bool, String) -> Void)
    func ensureFinderHostAlias(_ alias: String, withReply reply: @escaping (Bool, String) -> Void)
    func removeFinderHostAlias(_ alias: String, withReply reply: @escaping (Bool, String) -> Void)
}
