// ============================================================================
// tablet-spoof / resolve_hook.cpp
// ============================================================================
// The DEFERRED resolution + hook installation, wired to the RECIPE THAT IS
// PROVEN ON DEVICE.
//
// ---------------------------------------------------------------------------
// WHY DEFERRED (the finding that unblocked this)
// ---------------------------------------------------------------------------
// `postAppSpecialize` is too early: the app's own dex is not loaded yet, so
// FindClass on the app's classes FAILS there. Measured, from the app's own log:
//
//   com.tencent.wework : FindClass(foundation.logic.Application)  -> FAIL in post
//                        ...but after the Application appears (~2900ms):
//                        loadClass(foundation.logic.Application)   -> OK
//                        method FOUND ArtMethod=0x7b401963b0
//   com.tencent.mm     : loadClass(com.tencent.mm.ui.gk)           -> OK
//                        method FOUND ArtMethod=0x7b40195380
//
// So the working recipe is:
//     1. wait until ActivityThread.currentApplication() != null
//     2. take the app's ClassLoader from that Context
//     3. loadClass(<target>) -> getDeclaredMethod -> ArtMethod
//     4. native-ify it (art_hook.hpp) so it returns a constant
//
// Every step above is confirmed on-device except step 4, which is what this file
// adds.
//
// ---------------------------------------------------------------------------
// THREADING -- the one thing that must be right
// ---------------------------------------------------------------------------
// Resolution happens on a background thread, so that thread MUST have a valid
// JNIEnv. A thread created from native code is not attached by default; it must
// call JavaVM::AttachCurrentThread, and BEFORE any JNI call. If attach fails, the
// thread has no usable env and every JNI call is undefined -- which matches the
// earlier symptom of a resolver thread that started and then produced no output
// at all.
//
// So: attach first, and record the result. If attach fails, report it loudly
// rather than proceeding into undefined behaviour.
// ============================================================================
#pragma once

#include <jni.h>

#include <android/log.h>
#include <pthread.h>
#include <unistd.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>

#include "art_hook.hpp"

namespace resolve_hook {

constexpr const char* kTag = "tablet-spoof";

inline void logf(int prio, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
inline void logf(int prio, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    __android_log_vprint(prio, kTag, fmt, ap);
    va_end(ap);
}

// A file-based status sink, because logcat is unreliable for Zygisk modules on
// this device (a known-good module emits nothing on some boots). Written to the
// app's OWN data dir, which is the only location an app uid can always write.
inline void statusTo(const char* dir, const char* fmt, ...)
    __attribute__((format(printf, 2, 3)));
inline void statusTo(const char* dir, const char* fmt, ...) {
    if (dir == nullptr || dir[0] == '\0') return;
    char path[320];
    snprintf(path, sizeof(path), "%s/ts_hook.log", dir);

    char msg[400];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    FILE* f = fopen(path, "a");
    if (f == nullptr) return;
    fprintf(f, "%s\n", msg);
    fflush(f);          // flush per line: a truncated file is itself evidence
    fclose(f);
}

// ---------------------------------------------------------------------------
// What we need to carry onto the resolver thread.
// ---------------------------------------------------------------------------
struct Job {
    JavaVM* vm = nullptr;      // needed for AttachCurrentThread
    char dataDir[256] = {0};   // where to write status (app's own dir)
    char klass[160] = {0};     // target class, dot form
    char method[64] = {0};     // target method
    bool isWeChat = false;     // which app we are in
};

inline void* resolverThread(void* arg) {
    Job* job = static_cast<Job*>(arg);
    if (job == nullptr) return nullptr;

    statusTo(job->dataDir, "THREAD started");

    // ---- 1. ATTACH FIRST. Do not touch JNI before this succeeds. -------------
    JNIEnv* env = nullptr;
    jint rc = JNI_ERR;
    if (job->vm != nullptr) {
        rc = job->vm->AttachCurrentThread(&env, nullptr);
    } else {
        statusTo(job->dataDir, "THREAD FAIL no JavaVM (cannot attach)");
        return nullptr;
    }
    statusTo(job->dataDir, "THREAD AttachCurrentThread rc=%d env=%p", (int)rc, (void*)env);
    if (rc != JNI_OK || env == nullptr) {
        // Loud, and stop. Continuing with a null env is undefined behaviour.
        statusTo(job->dataDir, "THREAD FAIL attach failed; aborting (no JNI possible)");
        return nullptr;
    }

    // ---- 2. Wait for the Application to exist (up to ~20s). ------------------
    jclass atClass = env->FindClass("android/app/ActivityThread");
    jmethodID currentApp = nullptr;
    if (atClass != nullptr) {
        currentApp = env->GetStaticMethodID(
                atClass, "currentApplication", "()Landroid/app/Application;");
    }
    if (env->ExceptionCheck()) env->ExceptionClear();

    jobject app = nullptr;
    if (currentApp != nullptr) {
        for (int i = 0; i < 100; ++i) {          // 100 x 200ms = 20s
            app = env->CallStaticObjectMethod(atClass, currentApp);
            if (env->ExceptionCheck()) env->ExceptionClear();
            if (app != nullptr) break;
            usleep(200 * 1000);
        }
    }
    if (app == nullptr) {
        statusTo(job->dataDir, "THREAD FAIL Application never appeared");
        job->vm->DetachCurrentThread();
        return nullptr;
    }
    statusTo(job->dataDir, "THREAD Application appeared");

    // ---- 3. Take the app's ClassLoader from the Context. --------------------
    jclass ctxClass = env->FindClass("android/content/Context");
    jmethodID getCl = ctxClass ? env->GetMethodID(
            ctxClass, "getClassLoader", "()Ljava/lang/ClassLoader;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    jobject loader = getCl ? env->CallObjectMethod(app, getCl) : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (loader == nullptr) {
        statusTo(job->dataDir, "THREAD FAIL no ClassLoader");
        job->vm->DetachCurrentThread();
        return nullptr;
    }
    statusTo(job->dataDir, "THREAD got app ClassLoader");

    // ---- 4. loadClass the target through THAT loader. ------------------------
    jclass clClass = env->FindClass("java/lang/ClassLoader");
    jmethodID loadClass = clClass ? env->GetMethodID(
            clClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : nullptr;
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (loadClass == nullptr) {
        statusTo(job->dataDir, "THREAD FAIL no loadClass method");
        job->vm->DetachCurrentThread();
        return nullptr;
    }

    jstring name = env->NewStringUTF(job->klass);
    jobject target = env->CallObjectMethod(loader, loadClass, name);
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (target == nullptr) {
        statusTo(job->dataDir, "THREAD loadClass(%s) = FAIL", job->klass);
        job->vm->DetachCurrentThread();
        return nullptr;
    }
    statusTo(job->dataDir, "THREAD loadClass(%s) = OK", job->klass);

    // ---- 5. MEASURE the method. No hook is installed by this build. ---------
    //
    // Three independent facts, recorded together so the compiled-vs-bridged
    // conclusion does not rest on a single heuristic:
    //   1. the ArtMethod pointer
    //   2. the raw quick-entry value
    //   3. its access_flags (word[1], low 16 bits on this build)
    // plus a comparison against ART's bridge symbol addresses.
    jclass targetClass = static_cast<jclass>(target);
    jmethodID mid = env->GetStaticMethodID(targetClass, job->method, "()Z");
    bool isStatic = true;
    if (mid == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        mid = env->GetMethodID(targetClass, job->method, "()Z");
        isStatic = false;
    }
    if (mid == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        statusTo(job->dataDir, "HOOK_MISS method not found: %s.%s()Z",
                 job->klass, job->method);
        job->vm->DetachCurrentThread();
        return nullptr;
    }
    statusTo(job->dataDir, "MEASURE method found (static=%d)", isStatic ? 1 : 0);

    // ArtMethod* via the reflected Method object.
    //
    // NOTE: JNI's FromReflectedMethod takes a jobject (the reflected Method), NOT
    // a jmethodID -- current headers reject the jmethodID form outright.
    jobject reflected = env->ToReflectedMethod(
            targetClass, mid, isStatic ? JNI_TRUE : JNI_FALSE);
    void* artMethod = nullptr;
    if (reflected != nullptr) {
        artMethod = env->FromReflectedMethod(reflected);
    } else if (env->ExceptionCheck()) {
        env->ExceptionClear();
    }
    if (artMethod == nullptr) {
        statusTo(job->dataDir, "HOOK_MISS could not obtain ArtMethod");
        job->vm->DetachCurrentThread();
        return nullptr;
    }
    statusTo(job->dataDir, "MEASURE ArtMethod=%p", artMethod);

    // Fact 2 + 3: the raw word[1] (which carries access_flags in its low 16 bits
    // on this build) and the quick-entry word at the offsets we can read without
    // assuming a layout -- we dump the first 8 words so the raw evidence is in
    // the log regardless of which offset turns out to be the entry point.
    {
        const uint32_t* w = static_cast<const uint32_t*>(artMethod);
        char line[400];
        int n = snprintf(line, sizeof(line), "MEASURE words[0..7] =");
        for (int i = 0; i < 8 && n > 0 && n < (int)sizeof(line) - 12; ++i) {
            n += snprintf(line + n, sizeof(line) - n, " %08x", w[i]);
        }
        statusTo(job->dataDir, "%s", line);

        uint32_t word1 = w[1];
        uint32_t flags = word1 & 0xFFFFu;
        statusTo(job->dataDir,
                 "MEASURE access_flags=0x%04x (public=%d static=%d native=%d abstract=%d)",
                 flags,
                 (flags & 0x1) ? 1 : 0,
                 (flags & 0x8) ? 1 : 0,
                 (flags & 0x100) ? 1 : 0,
                 (flags & 0x400) ? 1 : 0);

        // The two pointer-looking words, printed as pointers so an operator can
        // compare them against the bridge reference values in the DET line.
        statusTo(job->dataDir, "MEASURE word[4..7] as ptrs: %p %p %p %p",
                 (void*)(uintptr_t)w[4], (void*)(uintptr_t)w[5],
                 (void*)(uintptr_t)w[6], (void*)(uintptr_t)w[7]);
    }

    // Deliberately NO native-ify and NO patch here. Installing a hook requires
    // knowing which word is the quick entry point, and guessing it is the class
    // of error whose failure mode is silent corruption of the host app. This
    // build measures; a hook is a separate, separately-verified step.
    statusTo(job->dataDir, "DET done: measured only, no hook installed");

    job->vm->DetachCurrentThread();
    statusTo(job->dataDir, "THREAD done");
    return nullptr;
}

// ---------------------------------------------------------------------------
// Start the resolver. Called once, from postAppSpecialize.
// ---------------------------------------------------------------------------
inline void start(const char* dataDir, JNIEnv* env, bool wechat) {
    if (env == nullptr) return;

    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK || vm == nullptr) {
        statusTo(dataDir, "start FAIL GetJavaVM failed");
        return;
    }
    statusTo(dataDir, "start ok, spawning resolver (%s)", wechat ? "WECHAT" : "WEWORK");

    Job* job = new Job();          // deliberately leaked: the thread owns it
    job->vm = vm;
    if (dataDir) {
        std::strncpy(job->dataDir, dataDir, sizeof(job->dataDir) - 1);
    }
    job->isWeChat = wechat;
    if (wechat) {
        std::strncpy(job->klass, "com.tencent.mm.ui.gk", sizeof(job->klass) - 1);
        std::strncpy(job->method, "B", sizeof(job->method) - 1);
    } else {
        std::strncpy(job->klass,
                     "com.tencent.wework.foundation.logic.Application",
                     sizeof(job->klass) - 1);
        std::strncpy(job->method, "isAndroidPad", sizeof(job->method) - 1);
    }

    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    // Detached: we never join. A modest stack is plenty for JNI calls.
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    if (pthread_create(&th, &attr, resolverThread, job) != 0) {
        statusTo(dataDir, "start FAIL pthread_create");
        delete job;
    }
    pthread_attr_destroy(&attr);
}

} // namespace resolve_hook
