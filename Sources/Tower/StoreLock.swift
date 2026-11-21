import Foundation

/// The one way to take the store's cross process lock.
///
/// flock(2) locks an inode, not a path. The support rename publishes a tree whose lock file is a
/// different inode, so a writer already queued on the old file would wake holding a lock no later
/// writer can see. After the lock is granted, confirm the path still names the file that was
/// locked; if it does not, drop it and take the current one.
enum StoreLock {
    private static let maxAttempts = 8

    /// Returns a descriptor holding LOCK_EX, or nil when the lock cannot be taken. The caller
    /// unlocks and closes it.
    static func acquire(at url: URL, mode: mode_t = 0o644) -> Int32? {
        for _ in 0..<maxAttempts {
            let fd = open(url.path, O_CREAT | O_RDWR, mode)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX) == 0 else {
                close(fd)
                return nil
            }
            var held = stat(), current = stat()
            if fstat(fd, &held) == 0, stat(url.path, &current) == 0,
               held.st_dev == current.st_dev, held.st_ino == current.st_ino {
                return fd
            }
            close(fd)
        }
        return nil
    }
}

