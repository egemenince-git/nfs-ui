# NFS Connect

NFS Connect is a native macOS menu bar app for mounting network folders. It supports an NFS v3 export and multiple SSHFS connections to Linux or other SSH servers from one compact glass-style interface.

The app keeps its main window out of the Dock. Closing the window hides it; use the menu bar item to reopen settings or quit. The menu bar icon changes appearance while a managed network mount is connected.

## What it can do

### NFS v3

- Mount an NFS export entered as `server:/export` to a local folder.
- Use NFS v3 with the reserved source port option (`resvport`), for servers that require it.
- Use a bundled macOS privileged helper for the mount operation. After the helper is approved in macOS, connecting does not ask for the administrator password each time.
- Choose whether NFS Connect starts when you sign in.

The NFS screen manages one NFS mount configuration at a time. Its default local folder is `~/nfs_server`; both values can be changed in the app.

### SSHFS

- Create and manage multiple SSHFS mounts at once.
- Set the server name or IP address, SSH port, username, remote folder, and local mount folder for each connection.
- Use an automatic local folder under `~/Mounts/` or enter a different path under your home folder.
- Open a mount in Finder, unmount it normally, or confirm a forced unmount when the normal operation cannot detach a busy mount.
- Discover existing NFS-style SSHFS mounts with an `ssh-` Finder location when the app starts, so a mounted volume can still be managed after the app has restarted.
- Show the SSH host in Finder using a local `ssh-<host>` alias.

SSH passwords are requested when connecting and are kept in memory only for that connection. NFS Connect does not save them to a profile or Keychain. A small local `SSH_ASKPASS` bridge supplies the password to SSHFS without putting it in the process arguments. The first connection to an unknown SSH host can show a host-key confirmation.

## Requirements

- macOS 14 or later.
- For NFS, an NFS server and network access to its export.
- For SSHFS, macFUSE and an `sshfs` executable. NFS Connect checks `/opt/homebrew/bin/sshfs`, `/usr/local/bin/sshfs`, and `/opt/local/bin/sshfs`.
- For NFS mounts, the bundled privileged service must be enabled in macOS. The app guides you through its one-time approval.

## Install

1. Download the latest `NFS Connect-macOS.zip` from the repository’s Releases page, or use the app bundle built from source.
2. Move `NFS Connect.app` into `/Applications` and open it.
3. If macOS asks to approve the privileged NFS service, open **System Settings → General → Login Items** and enable NFS Connect’s service.
4. Open **Settings** from the menu bar item to configure NFS, SSHFS, and launch-at-login preferences.

The SSHFS mount feature does not require the privileged NFS helper. It does require a working `sshfs` executable and macFUSE.

## Connect to a share

### NFS

Enter the export in `server:/export` form, choose a local folder, then click **Bağlan**. For example, a server might provide `nas.example.net:/volume/media`.

### SSHFS

Open **SSH Mount → Yeni SSH Mount**, enter the SSH server, username, port, password, and remote folder, then choose a local mount location. After connection, the SSH mount list provides controls to open and unmount each folder. Use **Zorla Ayır** if Finder or another process is preventing a normal unmount; forced unmount can interrupt open file operations.

## Build

Open `NFSConnect.xcodeproj` in Xcode, select the `NFSConnect` scheme, and build for macOS. The project uses a Developer ID signing identity for the maintainer’s distribution builds. To build locally with your own Apple Developer certificate, select your signing team and identity in Xcode.

For the maintainer’s signed Release build:

```sh
xcodebuild \
  -project NFSConnect.xcodeproj \
  -scheme NFSConnect \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="Developer ID Application: Egemen Ince (99U7KZC748)" \
  build
```

The app product is written to `build/Build/Products/Release/NFS Connect.app`.

## Project layout

- `Sources/` — SwiftUI interface, NFS connection model, SSHFS controller, and multi-mount manager.
- `Helper/` and `Shared/` — privileged NFS helper and its XPC protocol/client.
- `SSHAskpass/` — small helper used by SSHFS to obtain the in-memory password through a local Unix socket.
- `LaunchDaemons/` — ServiceManagement configuration for the privileged helper.
- `Assets.xcassets/` — app icon assets.
- `nfs-ping.md` — proposed architecture for future mount reachability monitoring; the monitor itself is not implemented yet.

## Security notes

- NFS Connect asks macOS to authorize its privileged NFS helper once; the helper is limited to validated mount and unmount requests and managed Finder host aliases.
- SSH credentials are not written to disk by the app. They live in the app process only while the SSHFS session runs.
- Finder’s SSH label uses a local `/etc/hosts` alias pointing at loopback. The SSHFS connection itself still targets the server address entered in the UI.
- Do not expose private keys, passwords, access tokens, or local machine configuration when filing an issue.

## License

No license has been selected yet. Until one is added, all rights are reserved by the copyright holder.
