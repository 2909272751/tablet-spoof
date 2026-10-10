// ============================================================================
// tablet-spoof / art_hook.cpp
// ============================================================================
// "Native-ify" a Java method so it returns a constant, WITHOUT any third-party
// hook library.
//
// WHY NATIVE-IFY RATHER THAN PATCHING AN ENTRY POINT
// -------------------------------------------------
// The obvious approach -- overwrite ArtMethod::entry_point_from_quick_compiled_code_
// -- has a fatal case: until ART JIT-compiles a method its entry point is a
// SHARED interpreter bridge (GetQuickToInterpreterBridge). Writing that slot on
// one method either has no effect (the bridge is consulted first) or, far worse,
// redirects dispatch for every interpreted method in the process.
//
// Making the method look `native` avoids the question entirely:
//   * ART sees kAccNative and dispatches to the JNI function pointer we install
//   * our function ignores its arguments and returns JNI_TRUE
//
// Layout is discovered EMPIRICALLY, never assumed. If we cannot validate what we
// are about to write, we refuse and report a miss -- because a wrong write here
// corrupts the host app rather than merely failing to spoof it.
//
// AArch64 ArtMethod layout notes (API 30+, 64-bit):
//   uint32_t declaring_class_;        // GcRoot<mirror::Class>
//   uint32_t access_flags_;
//   uint32_t dex_method_index_;
//   uint16_t method_index_;
//   uint16_t hotness_count_;
//   // ptr_sized_fields_:
//   struct PtrSizedFields {
//     void* data_;                    // native: JNI fn ptr; java: dex cache data
//     void* entry_point_from_quick_compiled_code_;
//   } ptr_sized_fields_;
//
// Rather than hardcode, we probe: a Java method's data_ points into the dex
// cache region while a native method's data_ is a code pointer. We locate the
// access_flags word by checking the kAccNative bit is currently CLEAR on our
// target (it must be, or we would not be hooking a Java method), then find the
// ptr_sized_fields that follow the aligned header.
// ============================================================================

#include "art_hook.hpp"

#include <android/log.h>
#include <cstdarg>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <sys/mman.h>
#include <unistd.h>

namespace art_hook {

namespace {

// ---------------------------------------------------------------------------
// Access-flag bits we manipulate (stable across ART versions).
// ---------------------------------------------------------------------------
constexpr uint32_t kAccNative    = 0x0100;
// If set, the interpreter may take a fast path that skips the "native" check;
// clearing it keeps our native-ified method on the normal dispatch route.
constexpr uint32_t kAccFastInterpreterToInterpreterInvoke = 0x00400000;

// ---------------------------------------------------------------------------
// Empirical ArtMethod layout discovery
// ---------------------------------------------------------------------------

// Candidate offsets probed in order. These cover the known 64-bit layouts
// (API 26..36). We do NOT blindly trust the first one: we validate by checking
// that the word at `accessFlagsOffset` has kAccNative CLEAR (our target is a
// Java method by construction) and that the entry-point slot holds a plausible
// code pointer.
struct Layout {
    int accessFlagsOffset = -1;
    int dataOffset = -1;
    int entryPointOffset = -1;
    bool valid = false;
    const char* why = "not probed";
};

// Read a uint32 from an ArtMethod at a byte offset.
inline uint32_t readU32(void* am, int off) {
    return *reinterpret_cast<uint32_t*>(reinterpret_cast<uint8_t*>(am) + off);
}
inline void writeU32(void* am, int off, uint32_t v) {
    *reinterpret_cast<uint32_t*>(reinterpret_cast<uint8_t*>(am) + off) = v;
}
inline void* readPtr(void* am, int off) {
    return *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(am) + off);
}
inline void writePtr(void* am, int off, void* v) {
    *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(am) + off) = v;
}

// Is this address plausibly executable code?
inline bool looksLikeCode(void* p) {
    uintptr_t v = reinterpret_cast<uintptr_t>(p);
    return v > 0x1000 && v < 0x0000'7fff'ffff'ffffULL;
}

// Discover the layout of `am` (a Java method). `amNative` is a KNOWN-native
// method used as a differential control for the data_ field: a Java method's
// data_ and a native method's data_ are semantically different, but more
// reliably, a native method has kAccNative SET while a Java one has it CLEAR.
// We exploit exactly that to locate the access-flags word.
Layout discover(void* am, void* amNativeControl) {
    Layout L;
    if (!looksLikeArtMethod(am)) { L.why = "implausible ArtMethod"; return L; }

    // --- locate accessFlags: the word with kAccNative CLEAR on the Java method
    //     and SET on the native control. That is a strong two-sided signal.
    if (amNativeControl != nullptr && looksLikeArtMethod(amNativeControl)) {
        for (int off = 0; off <= 16; off += 4) {
            uint32_t javaFlags = readU32(am, off);
            uint32_t nativeFlags = readU32(amNativeControl, off);
            bool javaClear = (javaFlags & kAccNative) == 0;
            bool nativeSet = (nativeFlags & kAccNative) != 0;
            if (javaClear && nativeSet) {
                L.accessFlagsOffset = off;
                break;
            }
        }
    }
    if (L.accessFlagsOffset < 0) {
        // Without a native control we cannot two-sided-validate. We could still
        // guess (flags are the first word after declaring_class on all versions),
        // but a wrong guess corrupts the method, so refuse.
        L.why = "could not locate access_flags (no native control method)";
        return L;
    }

    // --- ptr_sized_fields_ immediately follow the 4-byte header fields, aligned
    //     to pointer size. Header is access_flags(4) + dex_method_index(4) +
    //     method_index(2) + hotness_count(2) = 12 bytes after declaring_class.
    //     declaring_class is 4 bytes (GcRoot). So the struct-so-far ends at
    //     accessFlagsOffset + 4 + 4 + 2 + 2 = accessFlagsOffset + 12, rounded up
    //     to 8.
    int afterHeader = L.accessFlagsOffset + 12;
    int ptrFields = (afterHeader + 7) & ~7;   // align to 8

    L.dataOffset = ptrFields;
    L.entryPointOffset = ptrFields + 8;

    // Validate: the entry point of a Java method must be a plausible code pointer
    // OR null (methods can have null entry points before resolution).
    void* ep = readPtr(am, L.entryPointOffset);
    if (ep != nullptr && !looksLikeCode(ep)) {
        L.why = "entry_point slot does not look like code; layout mismatch";
        return L;
    }

    L.valid = true;
    L.why = "ok";
    return L;
}

// ---------------------------------------------------------------------------
// The JNI stub that replaces the method body.
// ---------------------------------------------------------------------------
//
// Signature must match the JNI convention for a STATIC boolean method with no
// args: jboolean (JNIEnv*, jclass). We accept extra args harmlessly.
//
// Note: if the target were an instance method the second parameter would be
// jobject rather than jclass, but both are pointer-sized and we ignore it, so
// the same stub is correct for either.
jboolean JNICALL stubReturnTrue(JNIEnv* /*env*/, jclass /*clazz*/, ...) {
    return JNI_TRUE;
}

} // namespace

HookResult forceTrueWithControl(JNIEnv* env,
                                jclass clazz,
                                const char* targetName, const char* targetSig,
                                const char* controlName, const char* controlSig) {
    HookResult out;
    if (env == nullptr || clazz == nullptr) { out.detail = "null env/class"; return out; }

    // 1. Get the reflected java.lang.reflect.Method, then its ArtMethod.
    //
    // NOTE: JNI's FromReflectedMethod takes a jobject (the reflected Method), NOT
    // a jmethodID. Two-arg ToReflectedMethod(class, methodID, isStatic) is the
    // standard way to obtain it. Earlier ART accepted the jmethodID directly;
    // current headers do not, so we go through the reflected object.
    bool isStatic = true;
    jmethodID mid = env->GetStaticMethodID(clazz, targetName, targetSig);
    if (mid == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        mid = env->GetMethodID(clazz, targetName, targetSig);
        isStatic = false;
        if (mid == nullptr) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            out.detail = "method not found (app updated?)";
            return out;
        }
    }

    jobject reflected = env->ToReflectedMethod(clazz, mid, isStatic ? JNI_TRUE : JNI_FALSE);
    if (reflected == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        out.detail = "ToReflectedMethod returned null";
        return out;
    }
    void* artMethod = env->FromReflectedMethod(reflected);
    if (!looksLikeArtMethod(artMethod)) {
        out.detail = "FromReflectedMethod gave an implausible ArtMethod";
        return out;
    }

    // 2. Find a KNOWN-native method to use as the two-sided control that lets us
    //    locate access_flags unambiguously. Object.hashCode() is native on ART.
    void* nativeControl = nullptr;
    {
        jclass objectClass = env->FindClass("java/lang/Object");
        if (objectClass != nullptr) {
            jmethodID hash = env->GetMethodID(objectClass, "hashCode", "()I");
            if (hash != nullptr) {
                jobject reflHash = env->ToReflectedMethod(objectClass, hash, JNI_FALSE);
                if (reflHash != nullptr) {
                    nativeControl = env->FromReflectedMethod(reflHash);
                    env->DeleteLocalRef(reflHash);
                } else if (env->ExceptionCheck()) {
                    env->ExceptionClear();
                }
            } else if (env->ExceptionCheck()) {
                env->ExceptionClear();
            }
        } else if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
    }

    // 3. Discover the layout. REFUSE on failure: a wrong write here corrupts the
    //    host app, so "do nothing loudly" strictly beats "patch and hope".
    Layout L = discover(artMethod, nativeControl);
    if (!L.valid) {
        out.detail = L.why;
        log(ANDROID_LOG_ERROR, "art_hook: refusing to patch %s%s : %s",
            targetName, targetSig, L.why);
        return out;
    }

    // 4. Native-ify: set kAccNative, clear the fast-interpreter path, and point
    //    data_ at our JNI function.
    uint32_t flags = readU32(artMethod, L.accessFlagsOffset);
    if ((flags & kAccNative) != 0) {
        out.detail = "method is already native; refusing to change it";
        return out;
    }
    void* prevData = readPtr(artMethod, L.dataOffset);
    void* prevEntry = readPtr(artMethod, L.entryPointOffset);

    writePtr(artMethod, L.dataOffset, reinterpret_cast<void*>(&stubReturnTrue));
    writeU32(artMethod, L.accessFlagsOffset,
             (flags | kAccNative) & ~kAccFastInterpreterToInterpreterInvoke);

    log(ANDROID_LOG_INFO,
        "art_hook: %s%s NATIVE-IFIED  flagsOff=%d dataOff=%d epOff=%d "
        "(flags %08x->%08x, prevData=%p prevEntry=%p stub=%p)",
        targetName, targetSig, L.accessFlagsOffset, L.dataOffset, L.entryPointOffset,
        flags, readU32(artMethod, L.accessFlagsOffset), prevData, prevEntry,
        reinterpret_cast<void*>(&stubReturnTrue));

    out.installed = true;
    out.detail = "native-ified";
    return out;
}

} // namespace art_hook
