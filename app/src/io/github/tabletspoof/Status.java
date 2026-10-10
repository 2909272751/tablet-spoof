package io.github.tabletspoof;

import android.content.Context;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.Charset;

/**
 * Out-of-band status reporting: how a <b>hook miss becomes visible</b>.
 *
 * <h2>Why this exists</h2>
 * The most dangerous failure mode in this module is a <b>silent miss</b>: a hook that resolves the
 * wrong class or a renamed method, installs nothing, and leaves the feature quietly broken. We hit
 * exactly this in development by hooking {@code android.app.Application.isAndroidPad()} (a
 * framework class with no such method) instead of
 * {@code com.tencent.wework.foundation.logic.Application}.
 *
 * <h2>The tension</h2>
 * {@link Config#DEBUG} is {@code false} and logging is off by design, because WeCom scans for
 * {@code xposed} / {@code isDebuggerConnected} and a chatty module is a detection signal. But
 * "log nothing" and "fail loudly" conflict if logging is the only channel.
 *
 * <h2>Why NOT /data/adb (the first design, which was broken)</h2>
 * The obvious target is the module's own state dir, {@code /data/adb/tablet-spoof/}. That
 * <b>cannot work</b>, and it failed silently — the worst possible outcome for a fail-loud channel:
 * <pre>
 *   drwx------ 700 root:root  /data/adb          <- not traversable by an app uid
 *   getenforce -> Enforcing                      <- SELinux would also deny it
 *   writer uid  -> u0_a398 (WeCom)               <- strictly less privileged than shell
 * </pre>
 * Confirmed on device: even the {@code shell} user cannot list {@code /data/adb}. An app uid is less
 * privileged still, so the write could never succeed and its exception was (correctly) swallowed.
 *
 * <h2>The working design</h2>
 * The <b>writer is the app</b> (which may only write its own sandbox) and the <b>reader is the
 * module</b> (which is root). So we write into the target app's own {@code files/} dir and let
 * root-side {@code hook-status.sh} read it.
 *
 * <p>The filename is deliberately chosen to blend with WeCom's own conventions — that directory
 * already holds {@code ww_stepcounter.cfg}, {@code wwgetscheduledata.js}, {@code wwoaid.cache} etc,
 * so {@code ww_device_metrics.dat} is unremarkable. A file named e.g.
 * {@code tablet_spoof_status.txt} would be an obvious foreign artifact in the target's private
 * storage, which would defeat the anti-detection requirement.
 *
 * <p>Trade-offs, accepted knowingly: a small file inside the target's private dir is a minor
 * detection surface, and it is wiped by an app-data clear. {@link #MODULE_PATH} remains the
 * preferred location <i>if</i> a future setup ever makes it writable.
 */
public final class Status {

    /**
     * Preferred path (module-side, root-only). Kept as documentation of intent and used only if the
     * write ever succeeds — which on a stock layout it will not, by design of the OS.
     */
    public static final String MODULE_PATH = "/data/adb/tablet-spoof/hook-status";

    /**
     * Actual status filename, written inside the target app's {@code files/} dir.
     * Chosen to match WeCom's existing {@code ww*} naming so it is not conspicuous.
     */
    public static final String APP_FILE_NAME = "ww_device_metrics.dat";

    /**
     * Context captured from the one-shot {@code Application.attach(Context)} hook.
     *
     * <p>NOTE: do <b>not</b> try {@code PackageReadyParam.getApplication()} — it does not exist on
     * this device and throws {@code NoSuchMethodError}. We take the context the other way, from
     * {@code Application.attach(Context)}, which is known to work here.
     */
    private static volatile Context appContext;

    private Status() {}

    /** Called by the attach hook, as early as possible. */
    public static void attachContext(Context context) {
        if (context != null && appContext == null) {
            appContext = context;
        }
    }

    /** Record a successful install. */
    public static void ok(String target, String process, int installed, String detail) {
        write("status=ok\n"
                + "target=" + target + "\n"
                + "process=" + process + "\n"
                + "hooks_installed=" + installed + "\n"
                + "detail=" + detail + "\n");
    }

    /**
     * Record a MISS — the loud-degradation path.
     *
     * @param target the package we are running in
     * @param reason why resolution failed
     */
    public static void miss(String target, String reason) {
        write("status=HOOK_MISS\n"
                + "target=" + target + "\n"
                + "reason=" + reason + "\n"
                + "hint=The app was probably updated and the target class/method moved.\n"
                + "hint=Re-run tools/audit-hook-targets.py against the new APK, then update the\n"
                + "hint=resolution ladder in Hooks.java. Until then the spoof is INACTIVE.\n");
    }

    /** Record that we deliberately did nothing here. */
    public static void skipped(String target, String why) {
        write("status=skipped\n"
                + "target=" + target + "\n"
                + "reason=" + why + "\n");
    }

    private static void write(String content) {
        // 1. Try the module path first (works if a future layout permits it).
        if (writeFile(new File(MODULE_PATH), content, false)) return;

        // 2. Write into the target app's own files dir — the design that actually works.
        Context context = appContext;
        if (context == null) return;
        try {
            File dir = context.getFilesDir();
            if (dir == null) return;
            writeFile(new File(dir, APP_FILE_NAME), content, true);
        } catch (Throwable ignored) {
            // Never let status reporting break the app or the hook install.
        }
    }

    /**
     * @param worldReadable true to make the file readable by the root-side module. Harmless for the
     *                      module path; for the app path the module reads it as root anyway, but
     *                      making it explicitly readable keeps `adb shell` inspection possible.
     */
    private static boolean writeFile(File file, String content, boolean worldReadable) {
        FileOutputStream out = null;
        try {
            File parent = file.getParentFile();
            if (parent == null || !parent.exists()) return false;
            out = new FileOutputStream(file);
            out.write(content.getBytes(Charset.forName("UTF-8")));
            out.flush();
            if (worldReadable) {
                //noinspection ResultOfMethodCallIgnored
                file.setReadable(true, false);
            }
            return true;
        } catch (Throwable ignored) {
            return false;
        } finally {
            if (out != null) {
                try { out.close(); } catch (Throwable ignored) { }
            }
        }
    }
}
