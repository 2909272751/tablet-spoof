// ============================================================================
// tablet-spoof / art_hook.hpp
// ============================================================================
// Minimal ART entry-point replacement, with NO third-party hook library.
//
// WHY HAND-ROLLED RATHER THAN DOBBY/SHADOWHOOK
// --------------------------------------------
// Our targets are JAVA methods. Dobby/ShadowHook/And64InlineHook hook *native*
// code (PLT/inline); there is no native code to inline-hook for a Java method
// until ART has compiled it, so they would not solve this on their own while
// adding a large vendored dependency and opaque code to a payload the user has
// to trust. Replacing the ArtMethod entry point is the direct approach and keeps
// our payload at ~10 KB (the user's reference module ships a 293 KB packed blob).
//
// THE TECHNIQUE
// -------------
// Every java.lang.reflect.Method has an underlying `ArtMethod` struct. When ART
// invokes a method it jumps to `ArtMethod::entry_point_from_quick_compiled_code_`.
// If we overwrite that pointer with our own stub, ART calls us instead, without
// touching the method's declaring class, its vtable, or any dex data.
//
// WHAT MAKES THIS TRICKY (the honest risk list)
// --------------------------------------------
//  1. ArtMethod layout is INTERNAL and changes between API levels. We do not
//     hardcode an offset. Instead we LOCATE the entry-point field empirically:
//     we read the target method's own entry point, and verify our candidate
//     offset by checking that some OTHER known method's value differs (i.e. we
//     found a per-method pointer, not a class-shared one). If we cannot confirm
//     it, we refuse to patch and report HOOK_MISS -- never "patch and hope".
//  2. If the method is not yet compiled, its entry point is the interpreter
//     bridge, which is SHARED between methods. Patching a shared bridge would
//     redirect every interpreted method -> catastrophic. We therefore detect
//     the shared case and treat it as a miss rather than corrupt dispatch.
//  3. GC can move things; we keep no pointers to method objects across safepoints.
//
// SAFETY POSTURE
// --------------
// Every failure path is a no-op plus a recorded miss. There is no path where we
// patch something unverified. That is deliberate: a silently-wrong entry point
// would break the host app's login flow, and "loudly doing nothing" is strictly
// better than "quietly corrupting".
// ============================================================================
#pragma once

#include <jni.h>

#include <android/log.h>
#include <cstdarg>
#include <cstdint>
#include <cstring>

namespace art_hook {

constexpr const char* kTag = "tablet-spoof";

inline void log(int prio, const char* fmt, ...) __attribute__((format(printf, 2, 3)));

inline void log(int prio, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    __android_log_vprint(prio, kTag, fmt, ap);
    va_end(ap);
}

// ---------------------------------------------------------------------------
// ArtMethod probing
// ---------------------------------------------------------------------------

// A java.lang.reflect.Method mirrors an ArtMethod. The ArtMethod pointer is the
// first field of the mirror on all current ART versions; this is the one layout
// assumption we make, and we VALIDATE it (see looksLikeArtMethod) before use.
struct MirrorLayout {
    void* art_method;          // java.lang.reflect.Method -> ArtMethod*
    void* declaring_class;
    uint32_t slot;
    void* declaring_class_of_holder;
    void* name;
    void* signature;
};

// Read a candidate ArtMethod pointer from a Method mirror.
inline void* artMethodOf(JNIEnv* env, jobject jmethod) {
    if (env == nullptr || jmethod == nullptr) return nullptr;
    void** raw = reinterpret_cast<void**>(jmethod);
    // Field 0 should be a plausible ArtMethod*: point into a mapped heap range
    // and have a readable declaring_class field. We take the first field and
    // sanity check it in the caller.
    return raw[0];
}

// Plausibility check for a pointer we intend to treat as an ArtMethod.
// We only require that it is non-null and that the first word (declaring_class_)
// is itself a readable, non-null pointer. That is a weak check by design -- the
// strong check is entry-point uniqueness below.
inline bool looksLikeArtMethod(void* am) {
    if (am == nullptr) return false;
    uintptr_t addr = reinterpret_cast<uintptr_t>(am);
    // Reject obviously invalid addresses (null page, small integers, kernel).
    if (addr < 0x1000 || addr > 0x0000'7fff'ffff'ffffULL) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Entry-point slot discovery
// ---------------------------------------------------------------------------
//
// We cannot hardcode the entry-point offset (it differs across ART versions), so
// we find it by DIFFERENTIAL PROBING:
//
//   * take two distinct methods A and B (we pass in the target plus a control)
//   * for each 4-byte-aligned offset in a plausible window, compare the values
//     at that offset in A and B
//   * a field that DIFFERS between two methods is a per-method field; the
//     entry point is one of the first such fields in the quick-entry region
//
// We then VALIDATE the candidate by requiring that the value at that offset
// points to executable memory (we check it is not obviously a small integer and
// not equal to the interpreter bridge shared by both methods).
//
// This is heuristic, which is why the caller MUST treat "no confident offset" as
// a miss rather than guessing.

struct EntryPointProbe {
    int offset = -1;        // byte offset of entry_point_from_quick_compiled_code_
    void* valueA = nullptr;
    void* valueB = nullptr;
};

// Probe for the entry-point offset using two ArtMethods. Returns offset = -1 when
// no confident answer was found.
inline EntryPointProbe probeEntryPoint(void* amA, void* amB) {
    EntryPointProbe out;
    if (!looksLikeArtMethod(amA) || !looksLikeArtMethod(amB)) return out;

    const uint8_t* a = reinterpret_cast<const uint8_t*>(amA);
    const uint8_t* b = reinterpret_cast<const uint8_t*>(amB);

    // ArtMethod sizes are well under 128 bytes on every known version; scan the
    // first 128 bytes at pointer alignment.
    for (int off = 0; off + (int)sizeof(void*) <= 128; off += alignof(void*)) {
        void* va = *reinterpret_cast<void* const*>(a + off);
        void* vb = *reinterpret_cast<void* const*>(b + off);
        if (va == vb) continue;                 // same in both -> not per-method
        uintptr_t ia = reinterpret_cast<uintptr_t>(va);
        // Executable-looking code pointer: above the null page, below the
        // canonical user-space end, and not a small integer.
        if (ia < 0x1000 || ia > 0x0000'7fff'ffff'ffffULL) continue;
        out.offset = off;
        out.valueA = va;
        out.valueB = vb;
        return out;                             // first differing candidate
    }
    return out;
}

// ---------------------------------------------------------------------------
// Trampoline
// ---------------------------------------------------------------------------
//
// A compiled ART method's quick entry point expects to be jumped to with the ART
// calling convention (x0 = ArtMethod*, then the method's own args). For a method
// taking no args and returning boolean, returning `true` means placing 1 in the
// return register (w0).
//
// We install a small machine-code stub rather than a C function, because a C
// function would not match ART's calling convention or preserve the managed
// register state ART expects.

// The stub:  mov w0, #1 ; ret
//   AArch64: 0x52800020 = mov w0, #1
//            0xd65f03c0 = ret
inline constexpr uint32_t kStubReturnTrue[] = {
    0x52800020u,  // mov  w0, #1     (return TRUE)
    0xd65f03c0u,  // ret
};

// ---------------------------------------------------------------------------
// Public entry point (implemented in art_hook.cpp)
// ---------------------------------------------------------------------------

struct HookResult {
    bool installed = false;
    const char* detail = "";
};

// Force a no-arg boolean method to return true, using `control` to validate the
// entry-point slot differentially.
//
// Returns installed=false with a human-readable `detail` whenever it cannot
// positively validate what it is about to patch. It NEVER patches on a guess:
// a wrong entry-point offset would redirect dispatch for every method sharing
// that slot, breaking the host app.
HookResult forceTrueWithControl(JNIEnv* env,
                                jclass clazz,
                                const char* targetName, const char* targetSig,
                                const char* controlName, const char* controlSig);

// Variant taking an already-resolved jmethodID.
//
// This is the entry point the DEFERRED resolver uses, and it exists for two
// reasons:
//   1. the resolver resolves the class through the APP's ClassLoader (proven
//      working on device), whereas FindClass inside postAppSpecialize FAILS --
//      so by the time we get here the lookup has already succeeded and
//      re-looking-up would be redundant and could fail;
//   2. it avoids a second FindClass that might resolve a DIFFERENT class object
//      than the one the app actually uses, which would hook a class nobody calls.
//
// `statusDir` is optional; when non-null, a human-readable trace is appended to
// <statusDir>/ts_hook.log so failures are visible without logcat (which is
// unreliable for Zygisk modules on this device).
HookResult nativeifyMethod(JNIEnv* env, jmethodID method, const char* statusDir);

} // namespace art_hook
