import Darwin
import Foundation

/// A process's current working folder, read from the kernel.
///
/// This is how g8r follows `cd` in a pane: it works for every shell and
/// needs nothing set up in it, unlike OSC 7, which only a shell told to
/// send it reports.
public enum ProcessDirectory {
    /// `pid`'s working folder, or nil when the process is gone or isn't
    /// ours to read.
    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }
}

extension PTYProcess {
    /// The pane's working folder: that of the job in the terminal's
    /// foreground (a nested shell the user started, say), else the pane's
    /// own shell's.
    public var workingDirectory: String? {
        if let job = foregroundProcessGroup, job != pid, let path = ProcessDirectory.workingDirectory(of: job) {
            return path
        }
        return ProcessDirectory.workingDirectory(of: pid)
    }
}
