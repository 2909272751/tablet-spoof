package io.github.tabletspoof;

import java.util.Arrays;
import java.util.List;

/**
 * Configuration and the strict scope whitelist.
 *
 * <p>This class is the single source of truth for WHICH packages may be touched. The
 * whitelist is enforced in three independent places, so any one of them failing still
 * leaves the module inert for everything else:
 *
 * <ol>
 *   <li>{@code META-INF/xposed/scope.list} - only these two packages are ever loaded into.</li>
 *   <li>{@link #handles(String)} - exact {@code equals} match, re-checked in the entry point.</li>
 *   <li>the daemon-side scope guard in the Magisk/APatch module - refuses any other package.</li>
 * </ol>
 *
 * <p>Note the deliberate use of {@code equals} rather than {@code startsWith} or
 * {@code contains}: a prefix test would wrongly match {@code com.tencent.mm.plugin} and a
 * substring test would match anything containing the literal, both of which would leak the
 * spoof into applications we must never touch.
 */
public final class Config {

    /** Debug logging is OFF by default - WeCom scans for our kind of footprint. */
    public static final boolean DEBUG = false;

    public static final String TAG = "tablet-spoof";

    /** The ONLY two packages this module may affect. Never add to this without a scope review. */
    public static final List<String> SCOPE = Arrays.asList(
            "com.tencent.mm",
            "com.tencent.wework");

    /** Canonical package ids, referenced by the per-app hook routers. */
    public static final String PKG_WECHAT = "com.tencent.mm";
    public static final String PKG_WEWORK = "com.tencent.wework";

    /** The KV switch that must be true for the QR-login code path. */
    public static final String KV_PAD_LOGIN_QR = "KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE";

    /**
     * The app's cached pad verdict key. Observed in
     * {@code files/mmkv/com.tencent.pb.common}. Confirmed by the Lead to currently hold
     * 2 (TABLET) while the UI still shows phone mode - so a THIRD condition exists
     * downstream of {@code isAndroidPad()}. Do not assume this key alone is sufficient.
     */
    public static final String KV_SAVE_PAD_TYPE = "local_save_pad_type_android";

    /** The minimum physical diagonal, in inches, that {@code isAndroidPad()} requires. */
    public static final double PAD_MIN_INCHES = 8.0;

    /** Where WeCom keeps the model string (confirmed 4 bytes, currently "MI 9"). */
    public static final String BUILD_MODEL_FILE = "files/file_config_build_model";

    /** MMKV store carrying both KV values. */
    public static final String MMKV_PB_COMMON = "files/mmkv/com.tencent.pb.common";

    /**
     * Exact-match whitelist test.
     *
     * @param packageName candidate package, may be null
     * @return true only if it is exactly one of {@link #SCOPE}
     */
    public static boolean handles(String packageName) {
        if (packageName == null) return false;
        for (String allowed : SCOPE) {
            if (allowed.equals(packageName)) return true;
        }
        return false;
    }

    private Config() {}
}
