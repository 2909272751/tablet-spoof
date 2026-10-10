// ============================================================================
// tablet-spoof / kv_read_probe.cpp
// ============================================================================
// ⚠️ THIS BUILD PERFORMS EXACTLY ONE MUTATION. It is not read-only.
//
// The write is the app's OWN setter:
//     g.H("KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE", Boolean.TRUE)
// which makes the APP write its OWN MMKV, so CRC is correct by construction --
// the one mutation with no corruption risk. The reverse is H(key, FALSE).
//
// It is guarded so it CANNOT run on a half-initialised state (see STEP 5), it
// runs strictly LAST after every read, a throw is caught and reported, and
// steps 6-7 are skipped if the write did not return cleanly.
//
// (An earlier revision of this header said "READ-ONLY". That became false the
// moment the write step was added; leaving the claim would have been exactly the
// kind of stale in-artifact prose this project has already been burned by.)
//
// ---------------------------------------------------------------------------
// WHAT IT ANSWERS, AND WHY A CONTROL PAIR IS REQUIRED
// ---------------------------------------------------------------------------
//   disk    : KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE = TRUE   (decoded byte-exact)
//   runtime : getDeviceType() = 131073, which by control flow PROVES qrMode==FALSE
//
// The decoded getDeviceType() branches:
//     if (isAndroidBox())                  return 327681
//     if (qrMode == FALSE)  JUMP ->        return 131073   <-- observed
//     if (isAndroidPad())                  return 131076
// so `isAndroidPad()` is never called on the observed path, and disk TRUE +
// runtime FALSE means either the reader does not read that file, or something
// writes FALSE between load and the getter call.
//
// THE CONTROL PAIR
//   pad key  : disk = TRUE    -> reader should give TRUE  if it reads that file
//   ctrl key : disk = FALSE   -> reader should give FALSE
//
//   ctrl==FALSE, pad==FALSE  -> the reader WORKS and the app genuinely reads FALSE
//   ctrl==FALSE, pad==TRUE   -> reader agrees with disk => the gate is NOT the KV
//   ctrl==TRUE or both null  -> the CALL is wrong; we learn nothing (reported as such)
//
// Without the control we could not tell a working reader returning FALSE from a
// broken call returning FALSE. That distinction is the whole point.
//
// toString() is logged alongside the Boolean decode so a non-Boolean return is
// VISIBLE rather than silently misread as FALSE -- a failure mode that would
// make the control useless.
// ============================================================================

#include "zygisk.hpp"

#include <android/log.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <unistd.h>

namespace {

constexpr const char* kPkgWeWork = "com.tencent.wework";
constexpr const char* kPadKey  = "KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE";
constexpr const char* kCtrlKey = "KV_ANDROID_PAD_FOLDABLE_SUPPORT_GRAY_OPEN";

char g_dir[256] = {0};
bool g_haveDir = false;

void out(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void out(const char* fmt, ...) {
    if (!g_haveDir) return;
    char path[320];
    snprintf(path, sizeof(path), "%s/ts_kvread.log", g_dir);
    char msg[420];
    va_list ap; va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    FILE* f = fopen(path, "a");
    if (f == nullptr) return;
    fprintf(f, "%s\n", msg);
    fflush(f);
    fclose(f);
}

bool readJString(JNIEnv* e, jstring s, char* o, size_t n) {
    if (e == nullptr || s == nullptr || o == nullptr || n == 0) return false;
    const char* u = e->GetStringUTFChars(s, nullptr);
    if (u == nullptr) return false;
    std::strncpy(o, u, n - 1); o[n - 1] = '\0';
    e->ReleaseStringUTFChars(s, u);
    return true;
}

// Load a class through the APP's ClassLoader (FindClass from a native thread uses
// the system loader and misses app classes -- proven earlier in this project).
jclass loadAppClass(JNIEnv* env, jobject loader, const char* name) {
    jclass clCls = env->FindClass("java/lang/ClassLoader");
    jmethodID lc = clCls ? env->GetMethodID(
            clCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (lc == nullptr) return nullptr;
    jstring nm = env->NewStringUTF(name);
    jclass c = static_cast<jclass>(env->CallObjectMethod(loader, lc, nm));
    if (env->ExceptionCheck()) { env->ExceptionClear(); return nullptr; }
    return c;
}

// Call gqp.l(String, Object) -> Object and describe the result.
//
// `defaultTrue` selects the DEFAULT argument passed to the app's reader, and it
// is load-bearing: l() returns the default when the key is ABSENT or the read
// fails. So a probe whose default EQUALS the expected disk value cannot
// distinguish "read the value" from "returned my default" -- a vacuous control.
// Every call site below therefore passes a default that DIFFERS from the value
// it expects, which is what makes a matching result informative.
//
// Returns: 1 = Boolean.TRUE, 0 = Boolean.FALSE, -1 = null, -2 = threw/not found
int readKv(JNIEnv* env, jobject gqp, jclass gqpCls, const char* key,
           const char* label, bool defaultTrue) {
    jmethodID l = env->GetMethodID(gqpCls, "l",
            "(Ljava/lang/String;Ljava/lang/Object;)Ljava/lang/Object;");
    if (l == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        out("KVREAD %s: reader l(String,Object) NOT FOUND", label);
        return -2;
    }
    jstring k = env->NewStringUTF(key);

    jclass boolCls = env->FindClass("java/lang/Boolean");
    jmethodID valueOf = boolCls ? env->GetStaticMethodID(
            boolCls, "valueOf", "(Z)Ljava/lang/Boolean;") : nullptr;
    jobject def = valueOf ? env->CallStaticObjectMethod(
            boolCls, valueOf, defaultTrue ? JNI_TRUE : JNI_FALSE) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    out("KVREAD %s: (default passed = %s)", label, defaultTrue ? "TRUE" : "FALSE");

    jobject r = env->CallObjectMethod(gqp, l, k, def);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        out("KVREAD %s: reader THREW", label);
        return -2;
    }
    if (r == nullptr) { out("KVREAD %s: reader returned null", label); return -1; }

    // Decode without assuming the class: ask toString(), then compare BOOLEAN.
    jclass boolCls2 = env->FindClass("java/lang/Boolean");
    jmethodID bv = boolCls2 ? env->GetMethodID(boolCls2, "booleanValue", "()Z") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();

    jboolean asBool = JNI_FALSE;
    bool isBool = false;
    if (boolCls2 != nullptr && env->IsInstanceOf(r, boolCls2)) {
        isBool = true;
        if (bv != nullptr) {
            asBool = env->CallBooleanMethod(r, bv);
            if (env->ExceptionCheck()) env->ExceptionClear();
        }
    }

    // Always also log toString() so a non-Boolean result is visible, not misread.
    jclass objCls = env->FindClass("java/lang/Object");
    jmethodID ts = objCls ? env->GetMethodID(objCls, "toString", "()Ljava/lang/String;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    char repr[128] = "(no toString)";
    if (ts != nullptr) {
        jstring s = static_cast<jstring>(env->CallObjectMethod(r, ts));
        if (env->ExceptionCheck()) env->ExceptionClear();
        if (s != nullptr) {
            const char* c = env->GetStringUTFChars(s, nullptr);
            if (c != nullptr) {
                std::strncpy(repr, c, sizeof(repr) - 1);
                repr[sizeof(repr) - 1] = '\0';
                env->ReleaseStringUTFChars(s, c);
            }
        }
    }

    if (isBool) {
        out("KVREAD %s: type=Boolean value=%s  (toString=%s)",
            label, asBool ? "TRUE" : "FALSE", repr);
        return asBool ? 1 : 0;
    }
    out("KVREAD %s: type=NON-BOOLEAN toString=%s", label, repr);
    return -3;
}

void* worker(void* arg) {
    JavaVM* vm = static_cast<JavaVM*>(arg);
    if (vm == nullptr) return nullptr;
    JNIEnv* env = nullptr;
    if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK || env == nullptr) {
        out("KVREAD attach FAILED"); return nullptr;
    }

    // --- wait for Application, take its ClassLoader (proven recipe) ---------
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
    if (app == nullptr) { out("KVREAD no Application"); vm->DetachCurrentThread(); return nullptr; }

    jclass ctx = env->FindClass("android/content/Context");
    jmethodID getCl = ctx ? env->GetMethodID(
            ctx, "getClassLoader", "()Ljava/lang/ClassLoader;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    jobject loader = getCl ? env->CallObjectMethod(app, getCl) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (loader == nullptr) { out("KVREAD no ClassLoader"); vm->DetachCurrentThread(); return nullptr; }

    // --- GET THE SINGLETON: gqp.a is a STATIC FIELD of type Lgqp; -----------
    // NOTE: the class name is the obfuscated short name "gqp" (default package),
    // NOT ...foundation.logic.gqp -- that mistake is why the earlier KV attempt
    // logged "gqp not resolvable".
    jclass gqpCls = nullptr;
    const char* candidates[] = { "gqp", "com.tencent.wework.foundation.logic.gqp" };
    for (int i = 0; i < 2 && gqpCls == nullptr; ++i) {
        gqpCls = loadAppClass(env, loader, candidates[i]);
        out("KVREAD loadClass(%s) = %s", candidates[i], gqpCls ? "OK" : "FAIL");
    }
    if (gqpCls == nullptr) { out("KVREAD gqp not loadable"); vm->DetachCurrentThread(); return nullptr; }

    jfieldID sf = env->GetStaticFieldID(gqpCls, "a", "Lgqp;");
    if (sf == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        out("KVREAD static field gqp.a (Lgqp;) NOT FOUND");
        vm->DetachCurrentThread(); return nullptr;
    }
    jobject gqp = env->GetStaticObjectField(gqpCls, sf);
    if (env->ExceptionCheck()) { env->ExceptionClear(); }
    out("KVREAD gqp.a singleton = %p", (void*)gqp);
    if (gqp == nullptr) { out("KVREAD singleton null"); vm->DetachCurrentThread(); return nullptr; }

    // --- THE CONTROL PAIR, with defaults chosen to CONTRAST the disk values ---
    // Defaults are load-bearing: l() returns the default when the key is absent
    // or the read fails, so each call passes a default OPPOSITE to what it
    // expects. A matching result is then informative rather than vacuous.
    //
    //   PAD-KEY  disk=TRUE  -> read with default FALSE  => TRUE means "read it"
    //   CTRL-KEY disk=FALSE -> read with default TRUE   => FALSE means "read it"
    out("---- CONTROLS (defaults deliberately CONTRAST the expected disk value) ----");
    int pad       = readKv(env, gqp, gqpCls, kPadKey,  "PAD-KEY(def=FALSE)", false);
    int ctrl      = readKv(env, gqp, gqpCls, kCtrlKey, "CTRL-KEY(def=TRUE)", true);
    // The Lead's stronger same-key pattern: read the SAME key with the OPPOSITE
    // default. TRUE/TRUE => genuinely TRUE. FALSE/FALSE => genuinely FALSE.
    // TRUE/FALSE => the reader is non-deterministic (itself a finding).
    int padDefTrue = readKv(env, gqp, gqpCls, kPadKey, "PAD-KEY(def=TRUE) ", true);

    out("---- CONTROL INTERPRETATION ----");
    out("  PAD-KEY def=FALSE -> %s   CTRL-KEY def=TRUE -> %s   PAD-KEY def=TRUE -> %s",
        pad == 1 ? "TRUE" : (pad == 0 ? "FALSE" : "ERR"),
        ctrl == 0 ? "FALSE" : (ctrl == 1 ? "TRUE" : "ERR"),
        padDefTrue == 1 ? "TRUE" : (padDefTrue == 0 ? "FALSE" : "ERR"));
    if (ctrl == 0 && pad == 0) {
        out("  => reader WORKS and PAD-KEY reads FALSE at runtime (disk says TRUE)");
        out("  => the persisted value is NOT what the app consumes");
    } else if (ctrl == 0 && pad == 1) {
        out("  => reader works and PAD-KEY reads TRUE (agrees with disk)");
        out("  => the KV is NOT the gate; look elsewhere");
    } else if (pad == 1 && padDefTrue == 0) {
        out("  *** NON-DETERMINISTIC READER: same key, opposite defaults, opposite "
            "results. Impossible for a working store -> interpret NOTHING from this run.");
    } else if (ctrl == -1 && pad == -1) {
        out("  => both null: call shape wrong; learn nothing");
    } else {
        out("  => mixed (ctrl=%d pad=%d padDefTrue=%d) -> interpret cautiously",
            ctrl, pad, padDefTrue);
    }

    if (pad == 1 && padDefTrue == 1) {
        out("  => PAD-KEY reads TRUE under BOTH defaults => genuinely TRUE, not a default");
    } else if (pad == 0 && padDefTrue == 0) {
        out("  => PAD-KEY reads FALSE under BOTH defaults => genuinely FALSE");
    }

    // --- does the isAndroidBox() short-circuit fire? ------------------------
    {
        jclass impl = loadAppClass(env, loader,
                "com.tencent.wework.foundation.impl.WeworkServiceImpl");
        if (impl != nullptr) {
            jmethodID box = env->GetStaticMethodID(impl, "isAndroidBox", "()Z");
            if (box == nullptr) {
                if (env->ExceptionCheck()) env->ExceptionClear();
                box = env->GetMethodID(impl, "isAndroidBox", "()Z");
            }
            if (box != nullptr) {
                jboolean b = env->CallStaticBooleanMethod(impl, box);
                if (env->ExceptionCheck()) { env->ExceptionClear(); out("KVREAD isAndroidBox() threw"); }
                else out("KVREAD isAndroidBox() = %s", b ? "TRUE" : "false");
            } else {
                out("KVREAD isAndroidBox() not found on WeworkServiceImpl");
            }
        } else {
            out("KVREAD WeworkServiceImpl not loadable");
        }
    }

    // --- resolve the getters once, for dt0 / dt1 ----------------------------
    jclass appCls = loadAppClass(env, loader,
            "com.tencent.wework.foundation.logic.Application");
    jmethodID gdt = nullptr, ip = nullptr;
    if (appCls != nullptr) {
        gdt = env->GetStaticMethodID(appCls, "getDeviceType", "()I");
        if (gdt == nullptr) { if (env->ExceptionCheck()) env->ExceptionClear();
                              gdt = env->GetMethodID(appCls, "getDeviceType", "()I"); }
        ip = env->GetStaticMethodID(appCls, "isAndroidPad", "()Z");
        if (ip == nullptr) { if (env->ExceptionCheck()) env->ExceptionClear();
                             ip = env->GetMethodID(appCls, "isAndroidPad", "()Z"); }
    }

    // --- dt0 : BEFORE the write --------------------------------------------
    int dt0 = -1;
    if (gdt != nullptr) {
        dt0 = (int)env->CallStaticIntMethod(appCls, gdt);
        if (env->ExceptionCheck()) { env->ExceptionClear(); dt0 = -1; }
        out("KVREAD dt0 (before write) getDeviceType = %d (0x%x)", dt0, (unsigned)dt0);
    } else {
        out("KVREAD getDeviceType not resolvable -- skipping dt0");
    }

    // -----------------------------------------------------------------------
    // STEP 5: THE SINGLE WRITE, via the app's own setter.
    // -----------------------------------------------------------------------
    // Guards, in order:
    //   * the singleton and reader must already have worked (pad != -2)
    //   * the resolve of getDeviceType must have worked (dt0 measured)
    //   * the write is single, and a throw is caught and reported, after which
    //     steps 6-7 are SKIPPED rather than run on a partially-applied state.
    // This is the app writing its own MMKV, so CRC is correct by construction --
    // the one mutation with no corruption risk. The reverse call is H(key,FALSE).
    int kv1 = -99, dt1 = -99;
    bool wrote = false;
    if (pad == -2 || dt0 == -1 || appCls == nullptr) {
        out("KVREAD WRITE SKIPPED: preconditions failed (pad=%d dt0=%d) -- "
            "no state changed", pad, dt0);
    } else {
        jmethodID H = env->GetMethodID(gqpCls, "H",
                "(Ljava/lang/String;Ljava/lang/Object;)V");
        if (H == nullptr) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            out("KVREAD WRITE SKIPPED: writer H(String,Object)V not found");
        } else {
            jstring k = env->NewStringUTF(kPadKey);
            jclass bc = env->FindClass("java/lang/Boolean");
            jmethodID vo = bc ? env->GetStaticMethodID(bc, "valueOf", "(Z)Ljava/lang/Boolean;") : nullptr;
            jobject boxed = vo ? env->CallStaticObjectMethod(bc, vo, JNI_TRUE) : nullptr;
            if (env->ExceptionCheck()) env->ExceptionClear();
            if (boxed == nullptr) {
                out("KVREAD WRITE SKIPPED: could not box Boolean.TRUE");
            } else {
                out("KVREAD WRITE: H(PAD-KEY, TRUE) ...");
                env->CallVoidMethod(gqp, H, k, boxed);
                if (env->ExceptionCheck()) {
                    env->ExceptionClear();
                    out("KVREAD WRITE THREW -- no state changed by us; steps 6-7 SKIPPED");
                } else {
                    wrote = true;
                    out("KVREAD WRITE returned cleanly");
                }
            }
        }
    }

    // --- STEP 6: read back -- did our write take? --------------------------
    // Logged EXPLICITLY and separately from dt1. A silently-failed write followed
    // by dt1==131073 would otherwise look like "the KV is not the gate" when it
    // actually means "the write never landed". That ambiguity is the one way this
    // run could produce a wrong conclusion, so it is closed here.
    if (wrote) {
        kv1 = readKv(env, gqp, gqpCls, kPadKey, "PAD-KEY-AFTER(def=FALSE)", false);
        if (kv1 == 1) {
            out("KVREAD WRITE VERIFIED: the app's own reader now returns TRUE "
                "=> our write LANDED");
        } else {
            out("KVREAD *** WRITE DID NOT LAND (post-write read = %d) ***", kv1);
            out("KVREAD   => treat dt1 below as UNINFORMATIVE about the KV gate; "
                "a failed write means the KV mechanism was NOT tested");
        }
    } else {
        out("KVREAD no write performed -> kv1/dt1 not measured (no mutation attempted)");
    }

    // --- STEP 7: THE MONEY SHOT --------------------------------------------
    if (wrote && gdt != nullptr) {
        dt1 = (int)env->CallStaticIntMethod(appCls, gdt);
        if (env->ExceptionCheck()) { env->ExceptionClear(); dt1 = -1; }
        out("KVREAD dt1 (AFTER write) getDeviceType = %d (0x%x)", dt1, (unsigned)dt1);
        if (dt1 == 131076) {
            out("KVREAD *** GOAL: 131076 = PAD. g.H(key,TRUE) is a COMPLETE native fix ***");
        } else if (dt1 == 131073) {
            out("KVREAD dt1 still 131073 -> the KV is NOT the gate (stop path)");
        } else {
            out("KVREAD dt1 = %d -> unexpected; interpret with care", dt1);
        }
    }

    out("KVREAD SUMMARY kv0=%d ctrl=%d dt0=%d wrote=%d kv1=%d dt1=%d",
        pad, ctrl, dt0, wrote ? 1 : 0, kv1, dt1);

    // --- interleaved getter reads, ~10 pairs --------------------------------
    if (gdt != nullptr) {
        out("---- 10 interleaved getter pairs ----");
        for (int i = 0; i < 10; ++i) {
            jint dt = env->CallStaticIntMethod(appCls, gdt);
            if (env->ExceptionCheck()) env->ExceptionClear();
            jboolean p = JNI_FALSE;
            if (ip != nullptr) {
                p = env->CallStaticBooleanMethod(appCls, ip);
                if (env->ExceptionCheck()) env->ExceptionClear();
            }
            out("KVREAD pair[%02d] getDeviceType=%d (0x%x) isAndroidPad=%s",
                i, (int)dt, (unsigned)dt, p ? "TRUE" : "false");
            usleep(20 * 1000);
        }
    }

    out("KVREAD done");
    vm->DetachCurrentThread();
    return nullptr;
}

} // namespace

class KvReadProbe : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api* api, JNIEnv* env) override { api_ = api; env_ = env; }

    void preAppSpecialize(zygisk::AppSpecializeArgs* args) override {
        if (args == nullptr) return;
        char pkg[256] = {0};
        if (!readJString(env_, args->nice_name, pkg, sizeof(pkg))) return;
        if (std::strcmp(pkg, kPkgWeWork) != 0) return;   // WeCom only
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
        if (pthread_create(&th, &at, worker, vm) != 0) out("KVREAD pthread_create failed");
        pthread_attr_destroy(&at);
    }

private:
    zygisk::Api* api_ = nullptr;
    JNIEnv* env_ = nullptr;
};

REGISTER_ZYGISK_MODULE(KvReadProbe)
