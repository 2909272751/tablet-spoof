// ============================================================================
// tablet-spoof / status_file.hpp
// ============================================================================
// File-based execution/status signal -- the replacement for logcat.
//
// WHY: logcat cannot be trusted for Zygisk modules on this device (a known-good
// module emits nothing on some boots), so absence of logs proves nothing.
//
// WHY THE WRITE PATH IS SO CAREFUL
// --------------------------------
// I shipped one silently-dead status channel twice, so the writability of each
// candidate path was MEASURED rather than assumed:
//
//     path                      shell uid(2000)   app uid(10398)
//     /data/adb/...             no (0700 root)    no
//     /data/local/tmp           YES               NO   (drwxrwx--x shell:shell)
//     /sdcard                   YES               NO   (needs runtime permission)
//     <app_data_dir>/           n/a               YES
//
// Conclusion: a status file written from inside an app process MUST go into that
// app's own data dir. Writing only to /data/local/tmp would have made the channel
// dead for exactly the process we care about -- which is what produced the wrong
// "postAppSpecialize does not fire for third-party apps" reading.
//
// Zygisk hands us `app_data_dir` in AppSpecializeArgs for precisely this purpose,
// so we do not need reflection or a Context.
//
// Order of attempts:
//   1. <app_data_dir>/ts_status.txt   <- always works for the app's own uid
//   2. /data/local/tmp/...            <- works for system/privileged processes
// A line is written to EVERY path that is writable, so both an app-uid process
// and a system process are observable.
// ============================================================================
#pragma once

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <sys/stat.h>

namespace status_file {

// Fallback path, writable by shell/system uids only.
inline constexpr const char* kFallbackPath = "/data/local/tmp/tablet-spoof-status";

// Filename used inside app_data_dir (kept neutral, not obviously ours).
inline constexpr const char* kAppFileName = "ts_status.txt";

// Cached app data dir, set once per process from AppSpecializeArgs::app_data_dir.
// 256 bytes is plenty for /data/data/<pkg>.
inline char g_appDir[256] = {0};
inline bool g_haveAppDir = false;

// Called from preAppSpecialize/postAppSpecialize once we can read args->app_data_dir.
inline void setAppDir(const char* dir) {
    if (dir == nullptr) return;
    size_t n = strlen(dir);
    if (n == 0 || n >= sizeof(g_appDir)) return;
    memcpy(g_appDir, dir, n + 1);
    g_haveAppDir = true;
}

// Append one line to a specific file. Returns true if it was written.
inline bool appendTo(const char* path, const char* text) {
    if (path == nullptr || text == nullptr) return false;

    // Truncate if it has grown unreasonably large.
    struct stat st{};
    if (stat(path, &st) == 0 && st.st_size > 65536) {
        FILE* t = fopen(path, "w");
        if (t != nullptr) fclose(t);
    }

    FILE* f = fopen(path, "a");
    if (f == nullptr) return false;
    fputs(text, f);
    fflush(f);
    fclose(f);
    chmod(path, 0666);
    return true;
}

// Record which sink actually accepted the write, so "no output" can always be
// distinguished from "output went somewhere unexpected". Reported once per process.
inline char g_sink[32] = {0};

inline void noteSink(const char* which) {
    if (g_sink[0] != '\0') return;      // first successful sink wins
    snprintf(g_sink, sizeof(g_sink), "%s", which);
}

inline void line(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

inline void line(const char* fmt, ...) {
    char msg[400];
    int n = snprintf(msg, sizeof(msg), "[%d] EVENT ", (int)getpid());
    if (n < 0 || n >= (int)sizeof(msg)) return;

    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg + n, sizeof(msg) - n, fmt, ap);
    va_end(ap);

    size_t len = strlen(msg);
    if (len + 2 < sizeof(msg)) {
        msg[len] = '\n';
        msg[len + 1] = '\0';
    }

    // 1. The app's own data dir -- the ONLY path an app uid can always write.
    //    Measured on this device: app uid 10398 canNOT create files in
    //    /data/local/tmp (--x on other) nor /sdcard (needs runtime permission),
    //    but CAN write its own data dir.
    if (g_haveAppDir) {
        char path[320];
        snprintf(path, sizeof(path), "%s/%s", g_appDir, kAppFileName);
        if (appendTo(path, msg)) noteSink("appdata");
    }

    // 2. Fallbacks, for system/privileged processes and for the loader itself
    //    (which has no app_data_dir).
    if (appendTo(kFallbackPath, msg)) noteSink("tmp");
    if (appendTo("/sdcard/tablet-spoof-status.txt", msg)) noteSink(g_sink[0] ? g_sink : "sdcard");
}

} // namespace status_file
