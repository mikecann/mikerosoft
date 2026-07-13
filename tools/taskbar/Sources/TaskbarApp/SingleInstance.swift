import Darwin
import Foundation

final class SingleInstance {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() -> SingleInstance? {
        let path = "/tmp/mikerosoft-taskbar.lock"
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            log("failed to open taskbar lock at \(path)")
            return nil
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }

        ftruncate(fd, 0)
        let pidText = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pidText.withCString { write(fd, $0, strlen($0)) }
        return SingleInstance(fileDescriptor: fd)
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
