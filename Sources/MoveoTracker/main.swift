import AppKit
import Darwin

if CommandLine.arguments.contains("--self-test") {
    exit(CameraFreeSelfTest.run())
}

// Launch Services normally reuses an existing app, but `open -n`, direct
// executable launches, and two copied bundles can bypass that behavior. Keep a
// per-user advisory lock open for the entire process so only one camera/OSC
// owner can run. flock is released by macOS even if the process crashes.
let instanceLockPath = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("site.posedtx.moveo-tracker.\(getuid()).lock")
let instanceLockFileDescriptor = Darwin.open(
    instanceLockPath,
    O_CREAT | O_RDWR,
    S_IRUSR | S_IWUSR
)
if instanceLockFileDescriptor >= 0,
   flock(instanceLockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
    NSRunningApplication.runningApplications(
        withBundleIdentifier: "site.posedtx.moveo-tracker"
    )
    .first(where: { $0.processIdentifier != getpid() })?
    .activate(options: [.activateAllWindows])
    Darwin.close(instanceLockFileDescriptor)
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
