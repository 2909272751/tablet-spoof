package io.github.tabletspoof;

import io.github.libxposed.api.XposedInterface;

import java.lang.reflect.Executable;
import java.lang.reflect.Method;

/**
 * Hook installation for the confirmed WeCom mechanism.
 *
 * <h2>Scope of this class</h2>
 * Everything here acts on <b>com.tencent.wework only</b>. WeChat ({@code com.tencent.mm}) keys on
 * a completely different detection path ({@code ro.product.model.is.tablet} /
 * {@code ro.build.characteristics} / its own {@code isPad}-style helpers), so none of this
 * transfers. {@link #install} refuses any package other than WeCom even though the caller has
 * already passed the whitelist.
 *
 * <h2>The confirmed mechanism (verified in bytecode, twice, independently)</h2>
 * <pre>
 * LoginWxAuthActivity.initView():
 *   insn 145      v0 = Application.isAndroidPad()Z
 *   insn 163-168  mQrLogin.setVisibility(      v0 ? VISIBLE : GONE )
 *   insn 156-162  mPhoneLoginTv.setVisibility( v0 ? GONE    : VISIBLE )
 *   insn 169-174  mPhoneLoginBtn.setVisibility(v0 ? VISIBLE : GONE )
 *
 * Application.isAndroidPad():
 *   sget mApplicationApi; if (mApplicationApi == null) return FALSE;
 *   return mApplicationApi.isAndroidPad();
 *     -> WeworkServiceImpl.isAndroidPad() -> Leux.d().f()
 * </pre>
 *
 * <p><b>{@code getDeviceType()} is NOT consulted for UI visibility.</b> That is why setting the
 * KV and the MMKV pad-type cache did not surface the QR entry: the only value that drives
 * {@code initView()} is {@code Application.isAndroidPad()} --and it is observed returning
 * {@code false} there despite the cache ending at 2 (an init-order / singleton-readiness effect).
 *
 * <h2>Anti-detection discipline</h2>
 * <ul>
 *   <li>No logging of target state by default. {@link Config#DEBUG} is false in release; even the
 *       hook-installed line is gated, and the hook body itself never logs.</li>
 *   <li>No file access. Nothing here reads or writes the target's storage, so MMKV's CRC is never
 *       at risk (hand-authored MMKV blobs are forbidden).</li>
 *   <li>Three narrow hooks, not a reflection sweep.</li>
 *   <li>{@code ExceptionMode.PASSTHROUGH} is deliberately NOT used: a throwing hook must not
 *       propagate into the host and crash login. Failures fall back to the original behaviour.</li>
 * </ul>
 */
public final class Hooks {

    /** Only this package is hooked by this class. WeChat needs separate recon. */
    public static final String TARGET_WEWORK = "com.tencent.wework";

    /**
     * WeCom's own {@code Application} class.
     *
     * <p><b>Do not "simplify" this to {@code android.app.Application}.</b> They are different
     * classes: this one lives in WeCom's dex (verified in classes7.dex), while
     * {@code android.app.Application} is a framework class with no {@code isAndroidPad()} at all.
     */
    private static final String WEWORK_APPLICATION = "com.tencent.wework.foundation.logic.Application";

    /**
     * The implementation class behind the pad/device-type helpers.
     * Package is {@code foundation.impl} (NOT {@code foundation}) --verified in classes7/8/11.dex.
     */
    private static final String WEWORK_SERVICE_IMPL = "com.tencent.wework.foundation.impl.WeworkServiceImpl";

    /** Hook ids, shared between installation and status reporting so they cannot drift. */
    static final String APPLICATION_HOOK_ID = "tablet-spoof:wework:Application.isAndroidPad";
    static final String SERVICE_HOOK_ID = "tablet-spoof:wework:WeworkServiceImpl.isAndroidPad";

    /**
     * SABOTAGE SWITCH - test-only, must ship as {@code false}.
     *
     * <p>When true, both target class names are deliberately corrupted so resolution fails and the
     * loud-degradation path (step (c)) must fire. This exists because
     * <b>a fallback that has never been observed firing is indistinguishable from no fallback</b>:
     * without a way to force the miss, "we wrote a status file" would be an untested claim.
     *
     * <p>Enabled only via {@code app/build.ps1 -Sabotage}, which patches the STAGED copy. The
     * source tree keeps {@code false}, so a sabotaged build cannot ship by accident.
     */
    static final boolean SABOTAGE_FORCE_MISS = false;

    /**
     * {@code getDeviceType()} return value for ANDROID_PAD, which selects QR login.
     * Phone is {@code 131073} (0x20001); box is {@code 327681} (0x50001).
     */
    private static final int DEVICE_TYPE_ANDROID_PAD = 131076; // 0x20004

    private Hooks() {}

    /**
     * Installs the confirmed hook set for WeCom, using a RESOLUTION LADDER so that an app update
     * degrades <b>loudly</b> instead of silently.
     *
     * <h2>Why a ladder</h2>
     * The dangerous failure mode is a silent miss: the hook resolves the wrong class or a renamed
     * method, installs nothing, and the feature quietly stops working. We hit exactly that during
     * development by hooking {@code android.app.Application.isAndroidPad()} --a framework class
     * with no such method --which would have made a correct hypothesis look disproven.
     *
     * <p>Steps, in order:
     * <ol>
     *   <li><b>(a) primary</b> --{@code foundation.logic.Application.isAndroidPad()}. The name is
     *       NOT obfuscated, so this is the stable anchor and needs no runtime discovery.</li>
     *   <li><b>(b) fallback</b> --{@code foundation.impl.WeworkServiceImpl.isAndroidPad()}. Kept
     *       anyway for consistency; if (a) ever moves, this alone may still take the pad branch.</li>
     *   <li><b>(c) loud failure</b> --if nothing installed, write
     *       {@code /data/adb/tablet-spoof/hook-status} so the Magisk module's read-only
     *       {@code report} action surfaces the miss. Logging stays off
     *       ({@link Config#DEBUG}=false) so we add no logcat footprint inside the app.</li>
     * </ol>
     *
     * <p>Resolution happens once, here, at {@code onPackageReady}. No polling, no per-frame work.
     *
     * <p>Idempotence and the main-process gate are enforced by the caller
     * ({@link TabletSpoofHook}); this method re-checks the package as a third guard because a
     * scope mistake here would leak a spoof into an unrelated application.
     *
     * @param module the module instance, used for the hook builder
     * @param loader the target package's class loader
     * @param target the package we were loaded for
     * @return number of hooks successfully installed (0 when unsupported/absent)
     */
    static int install(XposedInterface module, ClassLoader loader, String target) {
        if (module == null || loader == null) return 0;
        if (!TARGET_WEWORK.equals(target)) {
            // WeChat and anything else: no hooks from this class.
            Status.skipped(target, "not the WeCom target class; WeChat uses a separate hook set");
            return 0;
        }

        int installed = 0;
        StringBuilder detail = new StringBuilder();

        // (0) capture a Context so the status channel has somewhere writable to go.
        // This is NOT a behavioural hook -- it does not change any return value -- it only
        // records the Context so Status can write inside the app's own sandbox.
        //
        // Why we need it: /data/adb is 700 root:root, so an app uid can never write the
        // module's state dir. The status file therefore goes to the app's own files dir and
        // the root-side module reads it back. Without a Context we have no such dir.
        //
        // Deliberately NOT using PackageReadyParam.getApplication(): it does not exist on this
        // device and throws NoSuchMethodError. Application.attach(Context) is the known-good
        // route here.
        captureContext(module, loader);

        // (a) primary: the load-bearing hook. initView() branches on this.
        int primary = hookWeworkApplicationIsAndroidPad(module, loader);
        installed += primary;
        if (primary > 0) detail.append(APPLICATION_HOOK_ID).append(' ');

        // (b) fallback / consistency.
        int secondary = hookWeworkServiceImplIsAndroidPad(module, loader);
        installed += secondary;
        if (secondary > 0) detail.append(SERVICE_HOOK_ID).append(' ');

        // (c) loud degradation.
        if (installed == 0) {
            Status.miss(target,
                    "no hook target resolved (Application.isAndroidPad and "
                            + "WeworkServiceImpl.isAndroidPad both missed)");
        } else if (primary == 0) {
            // Partial: the secondary worked, so the spoof MIGHT still function, but the primary
            // is gone and that is a strong signal the app was updated.
            Status.miss(target,
                    "PRIMARY hook missed (Application.isAndroidPad); only the fallback installed. "
                            + "Likely an app update moved the class.");
        } else {
            Status.ok(target, "ok", installed, detail.toString().trim());
        }

        H.info("event=hooks_installed count=" + installed);
        return installed;
    }

    /**
     * {@code getDeviceType()} is deliberately NOT hooked.
     *
     * <p>hook-analyst proved from the bytecode that the login UI never reads it:
     * {@code LoginWxAuthActivity.initView()} branches solely on
     * {@code Application.isAndroidPad()} (insn 145), and {@code getDeviceType()} is not on that
     * path. Hooking it therefore bought nothing while adding a third piece of in-process
     * surface --and in-process surface is exactly what WeCom's anti-tamper checks
     * ({@code onAppCheck} / {@code onRootCheck} / {@code xposed} string scans) look for.
     *
     * <p>Removed under the principle: the smallest hook set that is proven sufficient. The
     * regression was re-tested after removal (QR login still works). If a future WeCom build
     * ever shows a device-type mismatch between UI and server state, re-adding it is one call to
     * {@link #hookInApp} --but it must be re-justified with evidence, not reinstated by habit.
     *
     * <p>For reference, the removed call was:
     * <pre>
     * hookInApp(module, loader, WEWORK_SERVICE_IMPL, "getDeviceType",
     *           "tablet-spoof:wework:WeworkServiceImpl.getDeviceType");
     * </pre>
     * The signature audit ({@code tools/audit-hook-targets.py}) confirms that method still exists
     * with return type {@code I}, so it remains available if ever needed.
     */

    /**
     * <b>The hook that actually matters.</b> {@code initView()} in
     * {@code LoginWxAuthActivity} branches on {@code Application.isAndroidPad()} (insn 145) to
     * decide {@code mQrLogin} visibility (insn 163-168).
     *
     * <p><b>CRITICAL: {@code Application} here is NOT {@code android.app.Application}.</b>
     * The real target is {@code Lcom/tencent/wework/foundation/logic/Application;} --a WeCom
     * class in the app's own dex (verified present in classes7.dex and elsewhere). Hooking
     * {@code android.app.Application} would resolve a framework class that has no
     * {@code isAndroidPad()} at all, so the hook would silently miss and the QR entry would
     * never appear. Resolve it from the app's class loader.
     *
     * <p>NOTE: anonymous {@link XposedInterface.Hooker} rather than a lambda, deliberately. This
     * module is compiled with {@code -source 8 -target 8 -bootclasspath android.jar}, and
     * {@code android.jar} has no {@code java.lang.invoke.LambdaMetafactory}, so lambdas fail to
     * compile ("cannot find symbol: metafactory").
     */
    private static int hookWeworkApplicationIsAndroidPad(XposedInterface module, ClassLoader loader) {
        return hookInApp(module, loader,
                sabotage(WEWORK_APPLICATION), "isAndroidPad",
                APPLICATION_HOOK_ID);
    }

    /**
     * Corrupt a class name when {@link #SABOTAGE_FORCE_MISS} is on, so resolution is guaranteed to
     * fail. Used only by the sabotage build to prove the loud-degradation path works.
     */
    private static String sabotage(String className) {
        return SABOTAGE_FORCE_MISS ? (className + "$SabotagedDoesNotExist") : className;
    }

    /**
     * Capture a Context for {@link Status} by hooking {@code Application.attach(Context)}.
     *
     * <p>This hook changes no behaviour: it stores the Context and calls through. It is the only
     * way to obtain a writable directory, because {@code /data/adb} (the module's state dir) is
     * {@code 700 root:root} and an app uid can never write there — a fact we confirmed on device
     * after the first status design failed silently.
     *
     * <p>Failure here is non-fatal: without a Context we simply lose the status channel, not the
     * spoof. It is reported as a hook miss only if the real hooks also fail.
     */
    private static void captureContext(XposedInterface module, ClassLoader loader) {
        try {
            Class<?> app = Class.forName(sabotage(WEWORK_APPLICATION), false, loader);
            Method attach = null;
            for (Method m : app.getDeclaredMethods()) {
                if (!m.getName().equals("attach")) continue;
                Class<?>[] p = m.getParameterTypes();
                if (p.length == 1) { attach = m; break; }
            }
            if (attach == null) {
                H.info("event=context_hook_miss no attach(Context) on " + WEWORK_APPLICATION);
                return;
            }
            attach.setAccessible(true);
            module.hook(attach)
                    .setId("tablet-spoof:wework:Application.attach")
                    .setPriority(XposedInterface.PRIORITY_HIGHEST)
                    .intercept(new XposedInterface.Hooker() {
                        @Override public Object intercept(XposedInterface.Chain chain) throws Throwable {
                            // Record the Context, then behave exactly as the app expects.
                            try {
                                Object arg = chain.getArg(0);
                                if (arg instanceof android.content.Context) {
                                    Status.attachContext((android.content.Context) arg);
                                }
                            } catch (Throwable ignored) {
                                // never let status capture alter app behaviour
                            }
                            return chain.proceed();
                        }
                    });
            H.info("event=context_hook_installed");
        } catch (Throwable error) {
            H.info("event=context_hook_miss error=" + error);
        }
    }

    /**
     * The application-side implementation behind {@code Application.isAndroidPad()}. Hooking it
     * as well keeps the two consistent if the app calls it directly.
     */
    private static int hookWeworkServiceImplIsAndroidPad(XposedInterface module, ClassLoader loader) {
        return hookInApp(module, loader,
                sabotage(WEWORK_SERVICE_IMPL), "isAndroidPad",
                SERVICE_HOOK_ID);
    }

    /** Resolve {@code owner.method()} inside the target app and force it to a fixed value. */
    private static int hookInApp(XposedInterface module, ClassLoader loader,
                                 String ownerName, String methodName, String id) {
        try {
            Class<?> owner = Class.forName(ownerName, false, loader);
            for (Method candidate : owner.getDeclaredMethods()) {
                if (!candidate.getName().equals(methodName)) continue;
                if (candidate.getParameterTypes().length != 0) continue;
                final Class<?> returnType = candidate.getReturnType();
                if (returnType != boolean.class && returnType != Boolean.class
                        && returnType != int.class) continue;
                candidate.setAccessible(true);
                // getDeviceType() returns int -> force the ANDROID_PAD constant 131076
                // (0x20004), which is what selects QR login. isAndroidPad() returns boolean
                // -> force true. Both are plain value returns with no side effects, so
                // overriding them cannot corrupt app state.
                final Object forced = (returnType == int.class)
                        ? Integer.valueOf(DEVICE_TYPE_ANDROID_PAD)
                        : Boolean.TRUE;
                module.hook(candidate)
                        .setId(id)
                        .setPriority(XposedInterface.PRIORITY_HIGHEST)
                        .intercept(new XposedInterface.Hooker() {
                            @Override public Object intercept(XposedInterface.Chain chain) {
                                return forced;
                            }
                        });
                H.info("event=hooked " + ownerName + "." + methodName);
                return 1;
            }
            H.info("event=hook_miss " + ownerName + "." + methodName);
            return 0;
        } catch (Throwable error) {
            H.info("event=hook_miss " + ownerName + "." + methodName + " error=" + error);
            return 0;
        }
    }
}
