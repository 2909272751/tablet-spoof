// ============================================================================
// tablet-spoof / tablet_spoof.cpp
// ============================================================================
// Native Zygisk payload.
//
// ===========================================================================
// VERIFIED SO FAR (all confirmed on device, hash-checked)
// ===========================================================================
//   * the payload compiles, links, exports `zygisk_module_entry`, is loaded and
//     registered by Zygisk Next
//   * `postAppSpecialize` IS delivered to both target apps, and the strict
//     2-package whitelist decision fires correctly (exact string equality;
//     subprocesses are seen and skipped)
//   * the target method RESOLVES in both apps, per-process, via the app's own
//     ClassLoader (the recipe below)
//   * WeCom : com.tencent.wework.foundation.logic.Application.isAndroidPad()
//             -> ArtMethod resolved, access_flags=0x0009 (public|static, native=0)
//   * WeChat: com.tencent.mm.ui.gk.B() -> ArtMethod resolved, same flags
//
// ===========================================================================
// WHAT THIS BUILD DOES
// ===========================================================================
// It resolves the target method (proven recipe) AND **calls the app's own Java
// APIs to read the runtime verdict**. Calling a method is safe: it reads a value
// the app computes and touches no ART structures.
//
// The question it answers, which we never actually measured: the MMKV cache
// `local_save_pad_type_android` held 2 (TABLET) while the UI stayed phone mode.
// We *inferred* "the cache is re-measured and overridden". This reads the live
// value instead:
//     Application.isAndroidPad()Z   -> TRUE / false
//     Application.getDeviceType()I  -> 131076 = PAD, 131073 = phone
//     (WeChat) gk.B()Z              -> TRUE / false
//
// A `false` verdict means the 8.0" size test genuinely fails at runtime, so any
// fix must make the MEASUREMENT succeed. A `true` verdict means the verdict is
// fine and something ELSE gates the UI -- which would mean our earlier model was
// incomplete. Either answer is decisive.
//
// ===========================================================================
// WHAT IS DELIBERATELY NOT DONE
// ===========================================================================
// No ART write. To hook the method we would need to know whether it is
// JIT/AOT-COMPILED or INTERPRETER-BRIDGED:
//   * COMPILED -> the quick entry point is real code; hooking it is standard.
//   * BRIDGED  -> there is no native code there, and the only remaining technique
//                 (native-ify: writing ArtMethod::data_/access_flags) has the
//                 failure mode of SILENTLY CORRUPTING the host app.
// `libart.so` does not export the bridge symbols we would compare against
// (all resolved to 0x0), so the classification could not be evaluated at all.
// We recorded that as *instrument-unavailable*, NOT as "bridged" -- conflating
// those two is the error that produced three wrong conclusions already.
//
// Guessing an offset here does not fail loudly, it corrupts. The user already has
// a working mechanism (the LSPosed companion), so the native path is a voluntary
// improvement. Hence: measure, do not write.
// ===========================================================================
// THREADING (verified)
// ===========================================================================
// Resolution runs on a background thread, which is NOT attached to the JVM by
// default. `AttachCurrentThread` is called FIRST and its result is checked; on
// failure the thread aborts rather than making JNI calls with a null env
// (measured: rc=0, valid env).
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

constexpr const char* kPkgWeChat = "com.tencent.mm";
constexpr const char* kPkgWeWork = "com.tencent.wework";

constexpr const char* kWeWorkClass = "com.tencent.wework.foundation.logic.Application";
constexpr const char* kWeWorkMeth  = "isAndroidPad";
constexpr const char* kWeChatClass = "com.tencent.mm.ui.gk";
constexpr const char* kWeChatMeth  = "B";

char g_dataDir[256] = {0};
bool g_haveDir = false;

enum class Target { None, WeWork, WeChat };
Target g_target = Target::None;

inline bool inScope(const char* pkg) {
    if (pkg == nullptr) return false;
    return std::strcmp(pkg, kPkgWeChat) == 0 || std::strcmp(pkg, kPkgWeWork) == 0;
}

void logMsg(int prio, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    __android_log_vprint(prio, kTag, fmt, ap);
    va_end(ap);
}

// Status sink: the app's OWN data dir. This is the only location an app uid can
// always write -- /data/adb is 0700 root, /data/local/tmp is not creatable by an
// app uid, and /sdcard needs a runtime permission. Writing somewhere else made
// an earlier diagnostic produce NO output for app-uid processes, which we
// misread as "the callback was never delivered". It was the sink.
void statusLine(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void statusLine(const char* fmt, ...) {
    if (!g_haveDir) return;
    char path[320];
    snprintf(path, sizeof(path), "%s/ts_native.log", g_dataDir);

    char msg[400];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    FILE* f = fopen(path, "a");
    if (f == nullptr) return;
    fprintf(f, "%s\n", msg);
    fflush(f);                 // per line: a truncated file is itself evidence
    fclose(f);
}

bool readJString(JNIEnv* env, jstring s, char* out, size_t outLen) {
    if (env == nullptr || s == nullptr || out == nullptr || outLen == 0) return false;
    const char* utf = env->GetStringUTFChars(s, nullptr);
    if (utf == nullptr) return false;
    std::strncpy(out, utf, outLen - 1);
    out[outLen - 1] = '\0';
    env->ReleaseStringUTFChars(s, utf);
    return true;
}

struct Job {
    JavaVM* vm = nullptr;
    bool wechat = false;
};

// ---------------------------------------------------------------------------
// Deferred resolution. Records what it finds and stops there -- no hook.
// ---------------------------------------------------------------------------
void* resolverThread(void* arg) {
    Job* job = static_cast<Job*>(arg);
    if (job == nullptr) return nullptr;

    JNIEnv* env = nullptr;
    if (job->vm == nullptr) { statusLine("resolver: no JavaVM"); return nullptr; }

    // Attach FIRST. A native thread is not attached by default, and every JNI
    // call is undefined without a valid env.
    jint rc = job->vm->AttachCurrentThread(&env, nullptr);
    if (rc != JNI_OK || env == nullptr) {
        statusLine("resolver: AttachCurrentThread FAILED rc=%d; aborting", (int)rc);
        return nullptr;
    }

    const char* cls = job->wechat ? kWeChatClass : kWeWorkClass;
    const char* meth = job->wechat ? kWeChatMeth : kWeWorkMeth;

    // Wait for the app's Application, then take its ClassLoader. FindClass is
    // too early here -- the app dex is not loaded at postAppSpecialize.
    jclass atClass = env->FindClass("android/app/ActivityThread");
    jmethodID currentApp = atClass ? env->GetStaticMethodID(
            atClass, "currentApplication", "()Landroid/app/Application;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();

    jobject app = nullptr;
    if (currentApp != nullptr) {
        for (int i = 0; i < 100 && app == nullptr; ++i) {   // up to ~20s
            app = env->CallStaticObjectMethod(atClass, currentApp);
            if (env->ExceptionCheck()) env->ExceptionClear();
            if (app == nullptr) usleep(200 * 1000);
        }
    }
    if (app == nullptr) {
        statusLine("resolver: Application never appeared; giving up");
        job->vm->DetachCurrentThread();
        return nullptr;
    }

    jclass ctxClass = env->FindClass("android/content/Context");
    jmethodID getCl = ctxClass ? env->GetMethodID(
            ctxClass, "getClassLoader", "()Ljava/lang/ClassLoader;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    jobject loader = getCl ? env->CallObjectMethod(app, getCl) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (loader == nullptr) {
        statusLine("resolver: no ClassLoader; giving up");
        job->vm->DetachCurrentThread();
        return nullptr;
    }

    jclass clClass = env->FindClass("java/lang/ClassLoader");
    jmethodID loadClass = clClass ? env->GetMethodID(
            clClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();

    jstring name = env->NewStringUTF(cls);
    jobject target = loadClass ? env->CallObjectMethod(loader, loadClass, name) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (target == nullptr) {
        statusLine("resolver: loadClass(%s) FAILED", cls);
        job->vm->DetachCurrentThread();
        return nullptr;
    }

    jclass tc = static_cast<jclass>(target);
    jmethodID mid = env->GetStaticMethodID(tc, meth, "()Z");
    bool isStatic = true;
    if (mid == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        mid = env->GetMethodID(tc, meth, "()Z");
        isStatic = false;
    }
    if (mid == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        statusLine("HOOK_MISS %s.%s()Z not found", cls, meth);
        job->vm->DetachCurrentThread();
        return nullptr;
    }

    // Record the resolved ArtMethod. FromReflectedMethod takes the reflected
    // Method object, not a jmethodID -- current JNI headers reject the latter.
    jobject reflected = env->ToReflectedMethod(tc, mid, isStatic ? JNI_TRUE : JNI_FALSE);
    void* artMethod = reflected ? env->FromReflectedMethod(reflected) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();

    statusLine("RESOLVED %s.%s() ArtMethod=%p", cls, meth, artMethod);

    // -----------------------------------------------------------------------
    // MEASURE THE RUNTIME VERDICT (read-only; touches no ART structures)
    // -----------------------------------------------------------------------
    // This is the question we never actually answered by measurement: the MMKV
    // cache `local_save_pad_type_android` held 2 (TABLET) and yet the UI stayed
    // phone mode. We INFERRED "the cache is re-measured and overridden". We never
    // read the live value.
    //
    // Reading a return value is safe -- it computes nothing about layouts and
    // writes nothing. It is the same class of measurement that has been reliable
    // throughout this project.
    //
    // CALL `isAndroidPad()` -- false means the 8.0" size test genuinely fails at
    // runtime; true means the verdict is fine and something ELSE gates the UI.
    // Either answer is decisive and worth having.
    {
        jmethodID call = env->GetStaticMethodID(tc, meth, "()Z");
        bool callStatic = true;
        if (call == nullptr) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            call = env->GetMethodID(tc, meth, "()Z");
            callStatic = false;
        }
        if (call != nullptr) {
            jboolean v = JNI_FALSE;
            if (callStatic) {
                v = env->CallStaticBooleanMethod(tc, call);
            } else if (app != nullptr) {
                v = env->CallBooleanMethod(app, call);
            }
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
                statusLine("CALL %s.%s()Z threw", cls, meth);
            } else {
                statusLine("CALL %s.%s()Z = %s", cls, meth, v ? "TRUE" : "false");
            }
        }
    }

    // CALL getDeviceType() on the same class if it exists -- 131076 (0x20004) is
    // ANDROID_PAD, 131073 (0x20001) is phone. This is the value the app reports.
    {
        jmethodID gdt = env->GetStaticMethodID(tc, "getDeviceType", "()I");
        bool gdtStatic = true;
        if (gdt == nullptr) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            gdt = env->GetMethodID(tc, "getDeviceType", "()I");
            gdtStatic = false;
        }
        if (gdt != nullptr) {
            jint dt = -1;
            if (gdtStatic) {
                dt = env->CallStaticIntMethod(tc, gdt);
            } else if (app != nullptr) {
                dt = env->CallIntMethod(app, gdt);
            }
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
                statusLine("CALL getDeviceType()I threw");
            } else {
                statusLine("CALL getDeviceType()I = %d (0x%x) -- 131076=0x20004 PAD, "
                           "131073=0x20001 phone", (int)dt, (unsigned)dt);
            }
        } else {
            if (env->ExceptionCheck()) env->ExceptionClear();
            statusLine("CALL getDeviceType()I: not present on %s", cls);
        }
    }

    // For WeChat, also read gk.B() -- the app's own "am I a tablet?" answer.
    if (job->wechat) {
        jmethodID bm = env->GetStaticMethodID(tc, "B", "()Z");
        if (bm != nullptr) {
            jboolean v = env->CallStaticBooleanMethod(tc, bm);
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
                statusLine("CALL gk.B()Z threw");
            } else {
                statusLine("CALL gk.B()Z = %s", v ? "TRUE" : "false");
            }
        } else if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
    }

    // -----------------------------------------------------------------------
    // TIMELINE OF isAndroidPad() -- WeCom. READ-ONLY. This is the experiment.
    // -----------------------------------------------------------------------
    // Measured earlier: isAndroidPad()Z = TRUE, but that was sampled ~2.9s after
    // process start, from a background thread. That is NOT the same claim as
    // "TRUE at LoginWxAuthActivity.initView() time".
    //
    // The two competing models:
    //   (M1) the value is FALSE early and only becomes TRUE later; initView()
    //        therefore sees false, which is why the pad entry needs the module.
    //   (M2) the value is TRUE throughout, and something else gates the entry.
    //
    // A single late sample cannot distinguish them. A high-frequency timeline can:
    // if it flips false->true at some t, M1 holds and the fix is to make it true
    // EARLY. If it is TRUE from the first sample, M2 holds.
    //
    // Read-only: calls a boolean getter and records it. Touches no structures.
    if (!job->wechat) {
        jmethodID gdt = env->GetStaticMethodID(tc, "isAndroidPad", "()Z");
        if (gdt == nullptr) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            gdt = env->GetMethodID(tc, "isAndroidPad", "()Z");
        }
        jmethodID getDeviceType = env->GetStaticMethodID(tc, "getDeviceType", "()I");
        if (getDeviceType == nullptr) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            getDeviceType = env->GetMethodID(tc, "getDeviceType", "()I");
        }

        if (gdt != nullptr) {
            bool sawFalse = false;
            bool sawTrue = false;
            int  firstTrueMs = -1;
            // ~5 seconds at ~10ms intervals, capturing EVERY transition.
            for (int i = 0; i < 500; ++i) {
                jboolean v = env->CallStaticBooleanMethod(tc, gdt);
                if (env->ExceptionCheck()) {
                    env->ExceptionClear();
                    statusLine("TIMELINE threw at sample %d", i);
                    break;
                }
                if (v) {
                    if (!sawTrue) {
                        sawTrue = true;
                        firstTrueMs = i * 10;
                        statusLine("TIMELINE first TRUE at t~%dms (sample %d)",
                                   firstTrueMs, i);
                        // On the first TRUE also record the device type, so we can
                        // see whether the two agree at that moment.
                        if (getDeviceType != nullptr) {
                            jint dt = env->CallStaticIntMethod(tc, getDeviceType);
                            if (env->ExceptionCheck()) env->ExceptionClear();
                            else statusLine("TIMELINE   getDeviceType()I at first TRUE = %d (0x%x)",
                                            (int)dt, (unsigned)dt);
                        }
                    }
                } else {
                    if (!sawFalse) {
                        sawFalse = true;
                        statusLine("TIMELINE first sample FALSE at t~%dms (sample %d)",
                                   i * 10, i);
                    }
                }
                usleep(10 * 1000);
            }
            if (!sawTrue) {
                statusLine("TIMELINE NEVER became TRUE in ~5s -> M1 strongly supported");
            } else if (firstTrueMs <= 0) {
                statusLine("TIMELINE TRUE on the FIRST sample -> M2 supported "
                           "(was already true when our thread ran)");
            } else {
                statusLine("TIMELINE flipped FALSE->TRUE at ~%dms -> M1 supported "
                           "(it starts false and later becomes true)", firstTrueMs);
            }
        } else {
            statusLine("TIMELINE isAndroidPad()Z not callable");
        }
    }

    // -----------------------------------------------------------------------
    // THE KV EXPERIMENT -- a WRITE, deliberately LAST, guarded, with before/after
    // -----------------------------------------------------------------------
    // Only reached if the read-only work above completed. Setting the app's own KV
    // makes the APP write its own MMKV (CRC correct by construction) and compute
    // its own device type -- zero ART surgery.
    //
    // Signature from the decoded bytecode: gqp.a is an INSTANCE (public final),
    // reached via the static singleton field Lgqp;->a, and the writer is
    // H(Ljava/lang/String;Ljava/lang/Object;)V.
    if (!job->wechat) {
        jobject gqpObj = nullptr;
        jclass gqpCls = nullptr;
        {
            jclass clCls = env->FindClass("java/lang/ClassLoader");
            jmethodID lc = clCls ? env->GetMethodID(
                    clCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : nullptr;
            if (lc != nullptr) {
                jstring nm = env->NewStringUTF("com.tencent.wework.foundation.logic.gqp");
                gqpCls = static_cast<jclass>(env->CallObjectMethod(loader, lc, nm));
                if (env->ExceptionCheck()) env->ExceptionClear();
            }
        }
        if (gqpCls == nullptr) {
            statusLine("KV: gqp class not resolvable -- KV write NOT attempted");
        } else {
            statusLine("KV: gqp resolved");
            // The singleton: static field 'a' of type Lgqp; (Leux.d() returns it too)
            jfieldID sf = env->GetStaticFieldID(
                    gqpCls, "a", "Lcom/tencent/wework/foundation/logic/gqp;");
            if (sf == nullptr) {
                if (env->ExceptionCheck()) env->ExceptionClear();
                statusLine("KV: static field gqp.a not found -- KV write NOT attempted");
            } else {
                gqpObj = env->GetStaticObjectField(gqpCls, sf);
                statusLine("KV: gqp.a singleton = %p", (void*)gqpObj);
            }
        }

        if (gqpObj != nullptr) {
            // Writer: H(String, Object) -> void (instance method)
            jmethodID H = env->GetMethodID(gqpCls, "H",
                    "(Ljava/lang/String;Ljava/lang/Object;)V");
            if (H == nullptr) {
                if (env->ExceptionCheck()) env->ExceptionClear();
                statusLine("KV: writer H(String,Object)V not found -- KV write NOT attempted");
            } else {
                // before
                jmethodID rd = env->GetMethodID(gqpCls, "l",
                        "(Ljava/lang/String;Ljava/lang/Object;)Ljava/lang/Object;");
                if (rd != nullptr) {
                    jstring k = env->NewStringUTF("KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE");
                    jobject before = env->CallObjectMethod(gqpObj, rd, k, nullptr);
                    if (env->ExceptionCheck()) env->ExceptionClear();
                    statusLine("KV: before = %s", before ? "non-null" : "null(sentinel)");
                }
                // write TRUE
                jstring key = env->NewStringUTF("KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE");
                jclass boolCls = env->FindClass("java/lang/Boolean");
                jmethodID valueOf = boolCls ? env->GetStaticMethodID(
                        boolCls, "valueOf", "(Z)Ljava/lang/Boolean;") : nullptr;
                jobject boxed = valueOf ? env->CallStaticObjectMethod(boolCls, valueOf, JNI_TRUE)
                                        : nullptr;
                if (env->ExceptionCheck()) env->ExceptionClear();
                if (boxed != nullptr) {
                    env->CallVoidMethod(gqpObj, H, key, boxed);
                    if (env->ExceptionCheck()) {
                        env->ExceptionClear();
                        statusLine("KV: writer call THREW -- no state changed by us");
                    } else {
                        statusLine("KV: writer call returned cleanly (KV set TRUE)");
                    }
                } else {
                    statusLine("KV: could not box Boolean.TRUE -- KV write NOT attempted");
                }
            }
        }
    }

    // ---- THE TEST: does getDeviceType() now report PAD? ---------------------
    if (!job->wechat) {
        jmethodID gdt2 = env->GetStaticMethodID(tc, "getDeviceType", "()I");
        if (gdt2 == nullptr) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            gdt2 = env->GetMethodID(tc, "getDeviceType", "()I");
        }
        if (gdt2 != nullptr) {
            jint dt = env->CallStaticIntMethod(tc, gdt2);
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
                statusLine("PROBE-FINAL getDeviceType() threw");
            } else {
                statusLine("PROBE-FINAL getDeviceType()I = %d (0x%x)  "
                           "131076=0x20004 PAD => KV took effect; "
                           "131073=0x20001 phone => did not",
                           (int)dt, (unsigned)dt);
            }
        }
    }

    statusLine("HOOK_MISS ART write not implemented: cannot classify the method as "
               "compiled vs interpreter-bridged on this ART build, and an incorrect "
               "ArtMethod write would silently corrupt the target app "
               "(native-ify deliberately not attempted; runtime verdict measured above)");

    job->vm->DetachCurrentThread();
    return nullptr;
}

void startResolver(JNIEnv* env, bool wechat) {
    if (env == nullptr) return;
    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK || vm == nullptr) {
        statusLine("start: GetJavaVM failed");
        return;
    }
    Job* job = new Job();       // leaked on purpose: the detached thread owns it
    job->vm = vm;
    job->wechat = wechat;

    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    if (pthread_create(&th, &attr, resolverThread, job) != 0) {
        statusLine("start: pthread_create failed");
        delete job;
    }
    pthread_attr_destroy(&attr);
}

} // namespace

class TabletSpoofModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api* api, JNIEnv* env) override {
        api_ = api;
        env_ = env;
        logMsg(ANDROID_LOG_INFO, "onLoad (api=%d)", ZYGISK_API_VERSION);
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs* args) override {
        if (args == nullptr) return;
        char pkg[256] = {0};
        if (!readJString(env_, args->nice_name, pkg, sizeof(pkg))) return;

        // Strict whitelist: exact equality only. Out-of-scope processes perform
        // no work and write nothing.
        if (!inScope(pkg)) { g_target = Target::None; return; }

        if (std::strcmp(pkg, kPkgWeWork) == 0)      g_target = Target::WeWork;
        else if (std::strcmp(pkg, kPkgWeChat) == 0) g_target = Target::WeChat;
        else { g_target = Target::None; return; }

        char dir[256] = {0};
        if (readJString(env_, args->app_data_dir, dir, sizeof(dir))) {
            std::strncpy(g_dataDir, dir, sizeof(g_dataDir) - 1);
            g_haveDir = true;
        }
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs* args) override {
        if (g_target == Target::None) return;

        if (!g_haveDir && args != nullptr) {
            char dir[256] = {0};
            if (readJString(env_, args->app_data_dir, dir, sizeof(dir))) {
                std::strncpy(g_dataDir, dir, sizeof(g_dataDir) - 1);
                g_haveDir = true;
            }
        }
        if (!g_haveDir) return;

        // Main process only: subprocesses never render the login UI.
        startResolver(env_, g_target == Target::WeChat);
    }

private:
    zygisk::Api* api_ = nullptr;
    JNIEnv* env_ = nullptr;
};

REGISTER_ZYGISK_MODULE(TabletSpoofModule)
