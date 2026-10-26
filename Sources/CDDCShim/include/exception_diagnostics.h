#pragma once
// Preserve the system crash reporter. This only prints an uncaught ObjC
// exception's original stack to the already-open per-session stderr file.
void JarvisInstallExceptionLogging(void);
