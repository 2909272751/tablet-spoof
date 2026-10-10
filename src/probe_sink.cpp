// ============================================================================
// tablet-spoof / probe_sink.cpp
// ============================================================================
// A MINIMAL, SELF-CONTAINED probe answering exactly one question:
//
//     Is postAppSpecialize delivered to com.tencent.wework / com.tencent.mm,
//     and can we observe it through the app's OWN data dir?
//
// Why a separate probe: two of us have now disagreed about whether the callback
// fires. The disagreement traces to the OBSERVATION channel, not the loader. So
// rather than argue, this probe makes the observation unambiguous:
//
//   * it writes to BOTH <app_data_dir>/ts_probe.txt AND the fallbacks
//   * it writes the process name and the phase, so a write proves delivery
//   * it writes from EVERY phase (constructor, onLoad, pre, post) so we can tell
//     WHICH phases run
//   * it uses only open/write (no stdio buffering) so a crash mid-way still
//     leaves the earlier bytes -- a truncated file is itself evidence
//
// If this probe produces output for WeCom, the callback is delivered and the
// earlier "not delivered" conclusion was an instrument artifact. If it produces
// nothing even here, then delivery genuinely fails and we need a different
// explanation. Either way the answer is unambiguous.
// ============================================================================

#include "zygisk.hpp"

#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <ctime>

namespace {

// Cached app data dir, learned from AppSpecializeArgs::app_data_dir.
char g_dir[256] = {0};
bool g_haveDir = false;

void setDir(const char* d) {
    if (d == nullptr || d[0] == '\0') return;
    std::strncpy(g_dir, d, sizeof(g_dir) - 1);
    g_dir[sizeof(g_dir) - 1] = '\0';
    g_haveDir = true;
}

// Unbuffered append: no stdio, so bytes hit the file immediately.
void writeTo(const char* path, const char* buf) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    size_t n = std::strlen(buf);
    ssize_t rc = write(fd, buf, n);
    (void)rc;
    close(fd);
}

// Write one line to every sink we can reach. Each line is prefixed so we can tell
// which SINK accepted it, which is the whole point.
void note(const char* phase, const char* detail) {
    char line[320];
    int n = snprintf(line, sizeof(line), "PROBE[%d] %s %s\n",
                     (int)getpid(), phase, detail ? detail : "");
    if (n <= 0) return;

    if (g_haveDir) {
        char p[320];
        snprintf(p, sizeof(p), "%s/ts_probe.txt", g_dir);
        writeTo(p, line);
    }
    writeTo("/data/local/tmp/ts-probe.txt", line);
    writeTo("/sdcard/ts-probe.txt", line);
}

// Runs at dlopen time, before any Zygisk handshake. Proves the .so was loaded.
__attribute__((constructor)) void probeCtor() {
    // app_data_dir is not known yet, so this necessarily lands in the fallbacks
    // (which an app uid cannot write) -- keep it for privileged processes.
    note("CTOR", "so-loaded");
}

class SinkProbe : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api* api, JNIEnv* env) override {
        api_ = api;
        env_ = env;
        note("ONLOAD", "reached");
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs* args) override {
        if (args != nullptr) {
            char pkg[256] = {0};
            if (readStr(args->nice_name, pkg, sizeof(pkg))) {
                note("PRE", pkg);
            } else {
                note("PRE", "(no name)");
            }
            char dir[256] = {0};
            if (readStr(args->app_data_dir, dir, sizeof(dir))) {
                setDir(dir);
                note("PRE-DIR", dir);   // now the app-data sink is live
            }
        }
        note("PRE-END", "done");
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs* args) override {
        if (args != nullptr) {
            char pkg[256] = {0};
            if (readStr(args->nice_name, pkg, sizeof(pkg))) {
                note("POST", pkg);
            }
            if (!g_haveDir) {
                char dir[256] = {0};
                if (readStr(args->app_data_dir, dir, sizeof(dir))) {
                    setDir(dir);
                    note("POST-DIR", dir);
                }
            }
            // Record whether the app's OWN class is resolvable from here -- this is
            // the question that decides if the ART hook is reachable.
            if (env_ != nullptr) {
                jclass c = env_->FindClass("com/tencent/wework/foundation/logic/Application");
                if (c != nullptr) {
                    note("POST-FINDCLASS", "wework Application OK");
                } else {
                    if (env_->ExceptionCheck()) env_->ExceptionClear();
                    note("POST-FINDCLASS", "wework Application MISS");
                }
            }
        }
        note("POST-END", "done");
    }

private:
    bool readStr(jstring s, char* out, size_t len) {
        if (env_ == nullptr || s == nullptr) return false;
        const char* utf = env_->GetStringUTFChars(s, nullptr);
        if (utf == nullptr) return false;
        std::strncpy(out, utf, len - 1);
        out[len - 1] = '\0';
        env_->ReleaseStringUTFChars(s, utf);
        return true;
    }

    zygisk::Api* api_ = nullptr;
    JNIEnv* env_ = nullptr;
};

} // namespace

REGISTER_ZYGISK_MODULE(SinkProbe)
