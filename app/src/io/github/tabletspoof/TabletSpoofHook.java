package io.github.tabletspoof;

import io.github.libxposed.api.XposedInterface;
import io.github.libxposed.api.XposedModule;
import io.github.libxposed.api.XposedModuleInterface;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Entry point for the tablet-spoof LSPosed companion.
 *
 * <h2>Status: gates verified, hook set implemented but NOT armed</h2>
 *
 * {@link #INSTALL_HOOKS} is {@code false}. The gates below are live and the confirmed hook set
 * exists in {@link Hooks}; flipping that one flag arms it. It stays false until the Lead's
 * on-device probe confirms that forcing {@code isAndroidPad()} surfaces the QR entry.
 *
 * <h2>The mechanism (resolved - there is no "third condition")</h2>
 * The earlier "third condition downstream of {@code isAndroidPad()}" framing was wrong.
 * Verified in bytecode: {@code LoginWxAuthActivity.initView()} branches <b>solely</b> on
 * {@code Application.isAndroidPad()} to set {@code mQrLogin} / {@code mPhoneLoginTv} /
 * {@code mPhoneLoginBtn} visibility, and {@code getDeviceType()} is <b>not</b> consulted for UI
 * at all. {@code Application.isAndroidPad()} is observed returning {@code false} in that call path
 * despite the MMKV cache ending at 2, which is why the KV + cache approach did not work.
 * The fix is therefore to force that one boolean true.
 *
 * <h2>Gates (all must pass before anything is installed)</h2>
 * <ol>
 *   <li><b>package</b> - exact whitelist match via {@link Config#handles(String)}.
 *       {@code scope.list} already limits loading, but we re-check: never trust one gate.</li>
 *   <li><b>process</b> - main process only. WeCom runs many subprocesses (mini-program,
 *       XWeb, push); none of them render the login UI, so none should carry our code.</li>
 *   <li><b>once</b> - atomic, so re-entrant callbacks cannot double-install.</li>
 * </ol>
 *
 * <h2>Anti-detection posture</h2>
 * WeCom's dex contains {@code onAppCheck} / {@code onRootCheck} / {@code checkRoot} and the
 * strings {@code xposed} / {@code isDebuggerConnected} / {@code isRooted}. Accordingly this
 * module:
 * <ul>
 *   <li><b>logs nothing by default</b> - {@link Config#DEBUG} is false in release, so neither
 *       target state nor hook results are written to logcat from inside the app;</li>
 *   <li>never reads or writes the target's files, so MMKV's CRC is never at risk;</li>
 *   <li>installs three narrow hooks rather than a reflection sweep;</li>
 *   <li>does not use {@code ExceptionMode.PASSTHROUGH} - a throwing hook must never propagate
 *       into the host and break login.</li>
 * </ul>
 *
 * <h2>WeChat needs separate recon</h2>
 * {@code com.tencent.mm} (now installed, 8.0.78) uses a different detection path
 * ({@code ro.product.model.is.tablet} / {@code ro.build.characteristics} / its own
 * {@code isPad}-style helpers). <b>None of the WeCom hooks transfer.</b> WeCom is priority 1;
 * WeChat is untouched by {@link Hooks#install}.
 */
public final class TabletSpoofHook extends XposedModule {

    /**
     * Master switch for the hook set.
     *
     * <p><b>PROVEN CONFIGURATION — do not change without re-testing.</b> The hook set was
     * confirmed on-device end-to-end: with it active, WeCom's login page shows the
     * 「平板和手机同时登录」 entry, and tapping it (then accepting the privacy dialog) navigates to
     * {@code com.tencent.wework/.login.controller.LoginQrCodeForAndroidPad} and renders a live QR
     * code. Reproduced on two consecutive cold starts.
     *
     * <p>Kept as a constant rather than deleted so the inert variant can still be built
     * ({@code build.ps1 -Inert}) for A/B comparison or if a future WeCom update misbehaves.
     */
    static final boolean INSTALL_HOOKS = true;

    private final AtomicBoolean installed = new AtomicBoolean(false);

    private volatile String processName = "unknown";
    private volatile String targetPackage = "unknown";

    @Override
    public void onModuleLoaded(XposedModuleInterface.ModuleLoadedParam param) {
        processName = param.getProcessName();
        H.attach(new H.Sink() {
            @Override public void log(String message) {
                // NOTE: must be qualified as TabletSpoofHook.this.log(...). Inside this
                // anonymous class an unqualified log(...) binds to Sink.log(String),
                // which is the wrong arity and fails to compile.
                // libxposed API 102 signature: log(int priority, String tag, String msg)
                TabletSpoofHook.this.log(android.util.Log.INFO, Config.TAG, message);
            }
        });
        H.info("event=module_loaded process=" + processName
                + " api=" + getApiVersion()
                + " framework=" + getFrameworkName() + " " + getFrameworkVersion());
    }

    @Override
    public void onPackageReady(XposedModuleInterface.PackageReadyParam param) {
        // ---- Gate 1: exact package whitelist -------------------------------------
        // scope.list should already prevent other packages reaching us. This is the
        // second, independent check, because a scope mistake here would leak a spoof
        // into unrelated applications.
        final String target = param.getPackageName();
        if (!Config.handles(target)) {
            H.info("event=skip_not_whitelisted target=" + target);
            return;
        }
        targetPackage = target;

        // ---- Gate 2: main process only -------------------------------------------
        // In WeCom the main process name equals the package name. Subprocesses are
        // named "<pkg>:something"; skip them.
        if (processName != null && !target.equals(processName)) {
            H.info("event=skip_subprocess process=" + processName + " target=" + target);
            return;
        }

        // ---- Gate 3: install once -------------------------------------------------
        if (!installed.compareAndSet(false, true)) {
            H.info("event=skip_already_installed target=" + target);
            return;
        }

        try {
            onTargetReady(param);
        } catch (Throwable error) {
            // Never let a failure here crash the host app: that would be both a
            // functional regression and a loud detection signal.
            H.info("event=install_failed target=" + target + " error=" + error);
        }
    }

    /**
     * Per-target install point: route to the correct hook set for the package we were loaded for.
     *
     * <p>The two supported apps share <b>no</b> symbols, so each has its own hook class and neither
     * can reach the other:
     * <ul>
     *   <li>{@code com.tencent.wework} -> {@link Hooks} (verified working end-to-end)</li>
     *   <li>{@code com.tencent.mm}     -> {@link WeChatHooks}</li>
     * </ul>
     */
    private void onTargetReady(XposedModuleInterface.PackageReadyParam param) {
        H.info("event=ready target=" + param.getPackageName()
                + " process=" + processName);

        // Re-assert the whitelist immediately before installing. Three independent gates
        // (scope.list, the caller's check, and this one) means a single mistake cannot leak
        // the spoof into an unrelated application.
        final String target = param.getPackageName();
        if (!Config.handles(target)) {
            H.info("event=install_skipped_not_whitelisted target=" + target);
            return;
        }

        if (!INSTALL_HOOKS) {
            // Gates verified, nothing installed. Used for A/B runs and for a safe build.
            H.info("event=install_hooks_disabled target=" + target);
            return;
        }

        final ClassLoader loader = param.getClassLoader();
        int count;
        if (Config.PKG_WECHAT.equals(target)) {
            count = WeChatHooks.install(this, loader, target);
        } else if (Config.PKG_WEWORK.equals(target)) {
            count = Hooks.install(this, loader, target);
        } else {
            // Unreachable given Config.handles(), but kept explicit: the failure mode we must
            // never have is a hook landing in an unintended app.
            H.info("event=no_hookset_for target=" + target);
            return;
        }
        H.info("event=hooks_total target=" + target + " count=" + count);
    }

    /** Diagnostics for the settings UI / logs; never called from a hot path. */
    public String describeState() {
        return "target=" + targetPackage
                + " process=" + processName
                + " installed=" + installed.get();
    }
}
