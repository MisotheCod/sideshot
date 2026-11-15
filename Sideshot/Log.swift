import Foundation
import os

/// Unified-log handle for capture diagnostics.
///
/// NSLog only writes to stderr, which is /dev/null for an app launched from Finder —
/// so NSLog-based tracing is invisible in exactly the case that matters. os.Logger is
/// persisted and readable with:
///   log show --last 10m --predicate 'subsystem == "com.cam.sideshot"'
let sideLog = Logger(subsystem: "com.cam.sideshot", category: "capture")
