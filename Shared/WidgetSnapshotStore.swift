import Foundation
import Darwin

public enum TokenBarWidgetSnapshotStore {
    public static func containerDirectory(bundle: Bundle = .main) throws -> URL {
        guard let group = bundle.object(forInfoDictionaryKey: "TokenBarAppGroup") as? String,
              group.range(of: "\\A[A-Za-z0-9][A-Za-z0-9.-]{1,254}\\z", options: .regularExpression) != nil,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw TokenBarWidgetSnapshotError.unavailableContainer
        }
        return directory
    }

    public static func read(directory: URL) throws -> TokenBarWidgetSnapshot {
        let file = directory.appendingPathComponent(TokenBarWidgetConstants.snapshotFilename)
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TokenBarWidgetSnapshotError.unavailableFile }
            guard let size = values.fileSize, size <= TokenBarWidgetConstants.maximumBytes else { throw TokenBarWidgetSnapshotError.oversizedSnapshot }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: TokenBarWidgetConstants.maximumBytes + 1) ?? Data()
            guard data.count <= TokenBarWidgetConstants.maximumBytes else { throw TokenBarWidgetSnapshotError.oversizedSnapshot }
            let snapshot: TokenBarWidgetSnapshot
            do { snapshot = try JSONDecoder().decode(TokenBarWidgetSnapshot.self, from: data) }
            catch { throw TokenBarWidgetSnapshotError.invalidSnapshot }
            try snapshot.validate()
            return snapshot
        } catch let error as TokenBarWidgetSnapshotError { throw error }
        catch { throw TokenBarWidgetSnapshotError.unavailableFile }
    }

    public static func write(_ snapshot: TokenBarWidgetSnapshot, directory: URL) throws {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= TokenBarWidgetConstants.maximumBytes else { throw TokenBarWidgetSnapshotError.oversizedSnapshot }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw TokenBarWidgetSnapshotError.unavailableFile }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let temporary = directory.appendingPathComponent(".widget-\(UUID().uuidString).tmp")
            let destination = directory.appendingPathComponent(TokenBarWidgetConstants.snapshotFilename)
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TokenBarWidgetSnapshotError.unavailableFile }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard rename(temporary.path, destination.path) == 0 else { throw TokenBarWidgetSnapshotError.unavailableFile }
        } catch let error as TokenBarWidgetSnapshotError { throw error }
        catch { throw TokenBarWidgetSnapshotError.unavailableFile }
    }
}
