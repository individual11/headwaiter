# Can Headwaiter run in the App Sandbox?

Short answer: no. It ships as a direct download, not through the Mac App Store.

Run it with `scripts/sandbox-spike.sh <pid> <port> <manifest> <kill-pid>`. It runs the same probe against a server the probe didn't start, first unsandboxed and then signed with the App Sandbox entitlement (plus network client and server). Measured on macOS 27, 2026-11-20:

| Call | Unsandboxed | Sandboxed |
| --- | --- | --- |
| `proc_listallpids` (list processes) | ✓ 862 | ✗ Operation not permitted |
| PID sweep 1…99999 with `PROC_PIDTBSDINFO` | ✓ 634 in 11 ms | ✓ 634 in 12 ms |
| `PROC_PIDTBSDINFO` on a known PID (parent, start time) | ✓ | ✓ |
| `proc_pidpath` (executable) | ✓ | ✓ |
| `PROC_PIDVNODEPATHINFO` (working directory) | ✓ | ✓ |
| `KERN_PROCARGS2` (arguments) | ✓ | ✓ |
| `PROC_PIDLISTFDS` / socket info (port → process) | ✓ | ✗ Operation not permitted |
| Read `package.json` in ~/Desktop | ✓ | ✗ denied (needs user-granted folder access) |
| Run `lsof` | ✓ 67 processes | ✗ 0, exit 1 (inherits the sandbox) |
| TCP connect / HTTP GET to localhost:port | ✓ | ✓ |
| Bind probe (port in use?) | ✓ | ✓ |
| `kill` a process it didn't start | (not run unsandboxed) | ✗ Operation not permitted |

**What a sandboxed edition could do:**
- Find listening ports by probing, and identify them over HTTP.
- Find your processes with a PID sweep and read their commands and working directories. With folder access granted (security-scoped bookmarks), it could also read manifests.

**What it could not do:**
- **Stop servers** at all.
- **Know which process owns which port.** It would have to guess from `--port` flags and framework defaults, so wrong or missing project names would be common.

**Risk:** the PID sweep works around a denial Apple clearly intends (`proc_listallpids` is blocked), so it risks App Review rejection and could be closed in any macOS update.

**Conclusion:** an App Store edition would be a different, much weaker product, missing the two things this app exists for: project-aware rows and Stop. Revisit if Apple adds an entitlement for process inspection.
