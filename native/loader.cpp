// The Zygisk entry itself has no C++ runtime dependency. Runtime/engine libraries
// are loaded in the forked target process only, before privileges are dropped.
#include "zygisk.hpp"
#include <android/dlext.h>
#include <android/log.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <cstdio>

namespace {
zygisk::Api *realApi;
zygisk::internal::module_abi *engine;
bool capture(zygisk::internal::api_table *, zygisk::internal::module_abi *module) { engine = module; return true; }
int getDir(void *) { return realApi->getModuleDir(); }
void option(void *, zygisk::Option o) { realApi->setOption(o); }
uint32_t flags(void *) { return realApi->getFlags(); }
bool exempt(int fd) { return realApi->exemptFd(fd); }
void *load(int dir, const char *name, int mode) {
    int fd = openat(dir, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nullptr;
    android_dlextinfo ext{};
    ext.flags = ANDROID_DLEXT_USE_LIBRARY_FD;
    ext.library_fd = fd;
    void *handle = android_dlopen_ext(name, mode, &ext);
    close(fd);
    return handle;
}
}
class Loader : public zygisk::ModuleBase {
    JNIEnv *env_ = nullptr;
    bool active_ = false;
    bool allowed_ = false;
    char data_[512]{};
    char phase_[512] = "PRE_NOT_STARTED";
    void phase(const char *text) { snprintf(phase_, sizeof(phase_), "%s", text ? text : "LOAD_FAILED"); }
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override { realApi = api; env_ = env; }
    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        const char *name = env_->GetStringUTFChars(args->nice_name, nullptr);
        allowed_ = name && (!strcmp(name, "com.tencent.mm") || !strcmp(name, "com.tencent.wework"));
        if (name) env_->ReleaseStringUTFChars(args->nice_name, name);
        if (!allowed_) { realApi->setOption(zygisk::DLCLOSE_MODULE_LIBRARY); return; }
        const char *appDir = env_->GetStringUTFChars(args->app_data_dir, nullptr);
        if (appDir) { snprintf(data_, sizeof(data_), "%s", appDir); env_->ReleaseStringUTFChars(args->app_data_dir, appDir); }
        int dir = realApi->getModuleDir();
        if (dir < 0) { phase("MODULE_DIRECTORY_UNAVAILABLE"); return; }
        phase("TARGET_PRE_SPECIALIZE");
        int off = openat(dir, "off", O_RDONLY | O_CLOEXEC);
        if (off >= 0) { close(off); close(dir); phase("OFF"); return; }
        void *runtime = load(dir, "lib/libc++_shared.so", RTLD_NOW | RTLD_GLOBAL);
        phase(runtime ? "RUNTIME_LOADED" : dlerror());
        void *payload = runtime ? load(dir, "lib/libtablet-spoof-engine.so", RTLD_NOW | RTLD_LOCAL) : nullptr;
        if (runtime) phase(payload ? "ENGINE_LOADED" : dlerror());
        close(dir);
        if (!payload) {
            __android_log_print(ANDROID_LOG_ERROR, "tablet-spoof-native", "LOAD_FAILED %s", dlerror()); return;
        }
        auto entry = reinterpret_cast<void (*)(zygisk::internal::api_table *, JNIEnv *)>(dlsym(payload, "zygisk_module_entry"));
        if (!entry) { phase("ENGINE_ENTRY_MISSING"); return; }
        static zygisk::internal::api_table api{};
        api.registerModule = capture;
        api.getModuleDir = getDir;
        api.setOption = option;
        api.getFlags = flags;
        api.exemptFd = exempt;
        entry(&api, env_);
        if (!engine) { phase("ENGINE_REGISTER_FAILED"); return; }
        phase("ENGINE_REGISTERED");
        active_ = true;
        engine->preAppSpecialize(engine->impl, args);
        phase("PRE_COMPLETE");
    }
    void postAppSpecialize(const zygisk::AppSpecializeArgs *args) override {
        if (active_) engine->postAppSpecialize(engine->impl, args);
        // The zygote domain cannot write /data/adb, even with root UID. Persist
        // diagnostics only after specialization, in the target's own data dir.
        if (allowed_ && data_[0]) {
            char path[600]; snprintf(path, sizeof(path), "%s/tablet-spoof-native-loader.txt", data_);
            FILE *f = fopen(path, "w");
            if (f) { fprintf(f, "pid=%d\nphase=%s\n", getpid(), phase_); fclose(f); }
        }
    }
};
REGISTER_ZYGISK_MODULE(Loader)
