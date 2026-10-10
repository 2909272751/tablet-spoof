// ============================================================================
// tablet-spoof / stability_probe.cpp
// ============================================================================
// READ-ONLY. Establishes whether `Application.getDeviceType()` is a STABLE
// measurement, before anything is concluded from it.
//
// WHY THIS IS NECESSARY
// ---------------------
// Across this session getDeviceType() has returned BOTH:
//     131073 (0x20001, PHONE)   -- two separate runs, and twice in the timeline
//     131076 (0x20004, PAD)     -- once, AFTER a KV write that DID NOT HAPPEN
// And the MMKV store's md5 changed from 1d9413f9173f29e2c6f408f7c5bbfc12 to
// 2cd508ab972494ee9b6a921a8bcfdc70 during that same window.
//
// So we have (a) a value that changed, (b) a state store that changed, and
// (c) no write of ours we can attribute it to. Under that condition ANY
// conclusion -- including "the KV is the gap" -- is unsupported.
//
// The single cheapest thing that resolves it: call the getter many times in a
// row with NOTHING in between, and see whether it is self-consistent.
//
//   * all N calls identical  -> the getter is stable; a single sample is valid,
//                               and the earlier 131076 needs another explanation
//   * N calls differ         -> the getter is value-unstable, and EVERY
//                               single-sample reading in this project is void
//
// This probe WRITES NOTHING to the app. It only reads. The only file it creates
// is its own log in the app's data dir.
// ============================================================================

#include "zygisk.hpp"

#include <android/log.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <unistd.h>

namespace {

constexpr const char* kTag = "tablet-spoof";
constexpr const char* kPkgWeWork = "com.tencent.wework";
constexpr const char* kPkgWeChat = "com.tencent.mm";

char g_dir[256] = {0};
bool g_haveDir = false;

void out(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void out(const char* fmt, ...) {
    if (!g_haveDir) return;
    char path[320];
    snprintf(path, sizeof(path), "%s/ts_stable.log", g_dir);

    char msg[400];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    FILE* f = fopen(path, "a");
    if (f == nullptr) return;
    fprintf(f, "%s\n", msg);
    fflush(f);
    fclose(f);
}

bool readJString(JNIEnv* env, jstring s, char* o, size_t n) {
    if (env == nullptr || s == nullptr || o == nullptr || n == 0) return false;
    const char* u = env->GetStringUTFChars(s, nullptr);
    if (u == nullptr) return false;
    std::strncpy(o, u, n - 1);
    o[n - 1] = '\0';
    env->ReleaseStringUTFChars(s, u);
    return true;
}

void* worker(void* arg) {
    JavaVM* vm = static_cast<JavaVM*>(arg);
    if (vm == nullptr) return nullptr;

    JNIEnv* env = nullptr;
    if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK || env == nullptr) {
        out("STABLE attach FAILED -- cannot measure");
        return nullptr;
    }

    // wait for Application, take its ClassLoader (proven recipe)
    jclass at = env->FindClass("android/app/ActivityThread");
    jmethodID cur = at ? env->GetStaticMethodID(
            at, "currentApplication", "()Landroid/app/Application;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    jobject app = nullptr;
    for (int i = 0; i < 100 && app == nullptr && cur != nullptr; ++i) {
        app = env->CallStaticObjectMethod(at, cur);
        if (env->ExceptionCheck()) env->ExceptionClear();
        if (app == nullptr) usleep(200 * 1000);
    }
    if (app == nullptr) { out("STABLE no Application"); vm->DetachCurrentThread(); return nullptr; }

    jclass ctx = env->FindClass("android/content/Context");
    jmethodID getCl = ctx ? env->GetMethodID(
            ctx, "getClassLoader", "()Ljava/lang/ClassLoader;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    jobject ld = getCl ? env->CallObjectMethod(app, getCl) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (ld == nullptr) { out("STABLE no ClassLoader"); vm->DetachCurrentThread(); return nullptr; }

    jclass clCls = env->FindClass("java/lang/ClassLoader");
    jmethodID lc = clCls ? env->GetMethodID(
            clCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();

    jstring nm = env->NewStringUTF("com.tencent.wework.foundation.logic.Application");
    jclass appCls = lc ? static_cast<jclass>(env->CallObjectMethod(ld, lc, nm)) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (appCls == nullptr) { out("STABLE Application class not loadable"); vm->DetachCurrentThread(); return nullptr; }

    jmethodID isPad = env->GetStaticMethodID(appCls, "isAndroidPad", "()Z");
    if (isPad == nullptr) { if (env->ExceptionCheck()) env->ExceptionClear();
                            isPad = env->GetMethodID(appCls, "isAndroidPad", "()Z"); }
    jmethodID gdt = env->GetStaticMethodID(appCls, "getDeviceType", "()I");
    if (gdt == nullptr) { if (env->ExceptionCheck()) env->ExceptionClear();
                          gdt = env->GetMethodID(appCls, "getDeviceType", "()I"); }

    if (gdt == nullptr) { out("STABLE getDeviceType not callable"); vm->DetachCurrentThread(); return nullptr; }

    // --- N consecutive reads of BOTH quantities, interleaved ---------------
    // The previous build sampled getDeviceType() 20x but isAndroidPad() only
    // ONCE per process -- which left the crucial question unanswered: does
    // isAndroidPad() vary WITHIN a process, or only BETWEEN processes?
    // Measured then: TRUE once, false three times, across four process starts.
    // So it varies between processes. Whether it is stable within one is what
    // this measures, and it is the missing prerequisite for any model claim.
    out("STABLE begin: %d interleaved pairs, no intervention", 20);
    int firstDt = -999; bool dtAllSame = true;
    int firstPad = -1;  bool padAllSame = true;
    int dtDistinct = 0; int dtSeen[8]; int dtN = 0;
    for (int i = 0; i < 20; ++i) {
        jint dt = env->CallStaticIntMethod(appCls, gdt);
        bool dtThrew = false;
        if (env->ExceptionCheck()) { env->ExceptionClear(); dtThrew = true; }

        jboolean pd = JNI_FALSE; bool padThrew = false;
        if (isPad != nullptr) {
            pd = env->CallStaticBooleanMethod(appCls, isPad);
            if (env->ExceptionCheck()) { env->ExceptionClear(); padThrew = true; }
        }

        if (dtThrew || padThrew) {
            out("STABLE pair[%02d] THREW (dt=%d pad=%d)", i, (int)dtThrew, (int)padThrew);
            dtAllSame = false; padAllSame = false;
            break;
        }

        if (i == 0) { firstDt = (int)dt; firstPad = pd ? 1 : 0; }
        else {
            if ((int)dt != firstDt) dtAllSame = false;
            if ((pd ? 1 : 0) != firstPad) padAllSame = false;
        }
        bool dup = false;
        for (int k = 0; k < dtN; ++k) if (dtSeen[k] == (int)dt) dup = true;
        if (!dup && dtN < 8) { dtSeen[dtN++] = (int)dt; dtDistinct++; }

        out("STABLE pair[%02d] getDeviceType=%d (0x%x)  isAndroidPad=%s",
            i, (int)dt, (unsigned)dt, pd ? "TRUE" : "false");
        usleep(20 * 1000);
    }

    out("STABLE getDeviceType distinct values: %d", dtDistinct);
    for (int k = 0; k < dtN; ++k) out("STABLE   dt value %d (0x%x)", dtSeen[k], (unsigned)dtSeen[k]);

    if (dtAllSame) out("STABLE getDeviceType() VERDICT: STABLE within process (all %d = %d)",
                       dtN > 0 ? 20 : 0, firstDt);
    else           out("STABLE getDeviceType() VERDICT: *** UNSTABLE within process ***");

    if (isPad != nullptr) {
        if (padAllSame) out("STABLE isAndroidPad() VERDICT: STABLE within process (all = %s)",
                            firstPad ? "TRUE" : "false");
        else            out("STABLE isAndroidPad() VERDICT: *** UNSTABLE within process ***");
    }
    out("STABLE done");
    vm->DetachCurrentThread();
    return nullptr;
}

} // namespace

class StabilityProbe : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api* api, JNIEnv* env) override { api_ = api; env_ = env; }

    void preAppSpecialize(zygisk::AppSpecializeArgs* args) override {
        if (args == nullptr) return;
        char pkg[256] = {0};
        if (!readJString(env_, args->nice_name, pkg, sizeof(pkg))) return;
        // Only WeCom: WeChat's gk has no getDeviceType().
        if (std::strcmp(pkg, kPkgWeWork) != 0) return;

        char d[256] = {0};
        if (readJString(env_, args->app_data_dir, d, sizeof(d))) {
            std::strncpy(g_dir, d, sizeof(g_dir) - 1);
            g_haveDir = true;
        }
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs* args) override {
        if (!g_haveDir) {
            if (args == nullptr || env_ == nullptr) return;
            char d[256] = {0};
            if (!readJString(env_, args->app_data_dir, d, sizeof(d))) return;
            std::strncpy(g_dir, d, sizeof(g_dir) - 1);
            g_haveDir = true;
        }
        JavaVM* vm = nullptr;
        if (env_->GetJavaVM(&vm) != JNI_OK || vm == nullptr) return;

        pthread_t th; pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        pthread_attr_setstacksize(&at, 512 * 1024);
        if (pthread_create(&th, &at, worker, vm) != 0) {
            out("STABLE pthread_create failed");
        }
        pthread_attr_destroy(&at);
    }

private:
    zygisk::Api* api_ = nullptr;
    JNIEnv* env_ = nullptr;
};

REGISTER_ZYGISK_MODULE(StabilityProbe)
