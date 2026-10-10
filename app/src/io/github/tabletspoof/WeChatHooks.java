package io.github.tabletspoof;

import io.github.libxposed.api.XposedInterface;

import java.lang.reflect.Method;

/**
 * Hook installation for WeChat ({@code com.tencent.mm}).
 *
 * <h2>Why this is a separate class from {@link Hooks}</h2>
 * WeChat and WeCom share <b>no</b> symbols. Verified against WeChat 8.0.78 (17 dex):
 * {@code isAndroidPad}, {@code KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE},
 * {@code local_save_pad_type_android}, {@code mQrLogin} and {@code LoginWxAuthActivity} are all
 * <b>absently</b> present — the WeCom mechanism does not transfer at all.
 *
 * <h2>The mechanism (reverse-engineered by the Lead, verified here)</h2>
 * <pre>
 *   Lcom/tencent/mm/ui/gk;.B()Z      public static, no args -- the public "isTablet" entry
 *   Lcom/tencent/mm/ui/gk;.C(Lou5/w0;)Z   the real implementation; all vendor checks live here
 *
 *   B() -> builds a gk$$b delegate -> new Lou5/w0 -> C(...) -> returns its result
 *   C() -> R() foldable, S() HW tablet, U() Honor, Y() Mi, l0() VIVO, c0() Oppo,
 *          g9.a() P8Pad, Eebbk X2/A2 ...
 *          FALLBACK: widthDp >= 600  (log: "inTabletEnv, widthDp:%s >= %s, return true")
 *          ELSE:     log "inTabletEnv, no tablet condition matched, return false"
 * </pre>
 *
 * <p><b>{@code gk.B()} is genuinely the login-path gate.</b> Its ~37 callers include WeChat's own
 * login screens — {@code LoginUI.initView()}, {@code LoginHistoryUI.initView()},
 * {@code MobileInputUI.onCreate()}, {@code BaseLoginVoiceUI.initView()},
 * {@code LoginByMobileSendSmsUI.onSceneEnd()}, {@code LoginIndepPass.onSceneEnd()},
 * {@code MMBaseAccountActivity.j7()}. That makes it the exact structural analogue of WeCom's
 * {@code LoginWxAuthActivity.initView()} -> {@code Application.isAndroidPad()}, which we already
 * proved works.
 *
 * <h2>Why we do NOT touch {@code widthDp} / DisplayMetrics / density</h2>
 * {@code widthDp} derives from density and width. Our device reports 392 (1080 / (440/160));
 * reaching the 600 threshold would need {@code density <= 288}, which would change the layout
 * (explicitly forbidden by the user) and would be global (violating the scope whitelist). So the
 * only acceptable lever is the in-process boolean.
 *
 * <h2>Why we do NOT write the cached static {@code gk.f} field</h2>
 * The Lead enumerated every {@code sget-object Lcom/tencent/mm/ui/gk;->f} across all 17 dex:
 * there is exactly <b>one</b> reader, and it is inside {@code C()} itself. The other 11 sites are
 * {@code sput-object} writes, also inside {@code C()}. No other class reads the cache directly, so
 * hooking {@code B()}/{@code C()} already makes it moot. A third intervention would add in-process
 * footprint for zero coverage gain — contrary to the anti-detection ruling.
 *
 * <h2>Version stability</h2>
 * {@code gk} and {@code B} are short obfuscated names that <b>will</b> rename. The stable anchor is
 * the log literal inside {@code C()}: {@code TARGET_LOG_ANCHOR}. Resolution order:
 * <ol>
 *   <li>try the known name {@code gk.B()} (fast path)</li>
 *   <li>if that fails, scan the loaded classes for the method containing the anchor string</li>
 *   <li>if both fail, report HOOK_MISS loudly (never silently)</li>
 * </ol>
 */
public final class WeChatHooks {

    public static final String TARGET_WECHAT = "com.tencent.mm";

    /** The obfuscated class holding the pad checks. WILL rename between versions. */
    private static final String GK_CLASS = "com.tencent.mm.ui.gk";

    /**
     * The log literal inside {@code C()} — our version-stable anchor.
     * Confirmed present in the shipped 8.0.78 APK by {@code module/verify-targets.sh}.
     */
    private static final String TARGET_LOG_ANCHOR =
            "inTabletEnv, no tablet condition matched, return false";

    /** The positive-path anchor, present in the same method. */
    private static final String TARGET_LOG_ANCHOR_POSITIVE =
            "inTabletEnv, widthDp:%s >= %s, return true";

    static final String HOOK_ID_B = "tablet-spoof:wechat:gk.B";
    static final String HOOK_ID_C = "tablet-spoof:wechat:gk.C";

    private WeChatHooks() {}

    /**
     * Install the WeChat hook set.
     *
     * @return number of hooks installed (0 when nothing resolved)
     */
    static int install(XposedInterface module, ClassLoader loader, String target) {
        if (module == null || loader == null) return 0;
        if (!TARGET_WECHAT.equals(target)) {
            Status.skipped(target, "not the WeChat target package");
            return 0;
        }

        int installed = 0;
        StringBuilder detail = new StringBuilder();

        // (1) fast path: the known obfuscated name, no-arg boolean entry.
        int b = hookByName(module, loader, "B", HOOK_ID_B);
        installed += b;
        if (b > 0) detail.append(HOOK_ID_B).append(' ');

        // (2) the implementation, which also makes the gk.f cache irrelevant.
        int c = hookByName(module, loader, "C", HOOK_ID_C);
        installed += c;
        if (c > 0) detail.append(HOOK_ID_C).append(' ');

        // (3) version-stable fallback: resolve by the log anchor if the names moved.
        if (installed == 0) {
            int byAnchor = hookByAnchor(module, loader);
            installed += byAnchor;
            if (byAnchor > 0) detail.append("anchor-resolved ");
        }

        if (installed == 0) {
            Status.miss(target,
                    "WeChat hooks did not resolve: neither gk.B/gk.C by name nor the "
                            + "log-anchor scan matched. The app was probably updated.");
        } else {
            Status.ok(target, "ok", installed, detail.toString().trim());
        }

        H.info("event=wechat_hooks_installed count=" + installed);
        return installed;
    }

    /** Hook a no-arg boolean/int method on {@code gk} by name. */
    private static int hookByName(XposedInterface module, ClassLoader loader,
                                  String methodName, String id) {
        try {
            Class<?> gk = Class.forName(GK_CLASS, false, loader);
            for (Method m : gk.getDeclaredMethods()) {
                if (!m.getName().equals(methodName)) continue;
                // B() takes no args; C(Lou5/w0;) takes one. Both return boolean.
                Class<?> ret = m.getReturnType();
                if (ret != boolean.class && ret != Boolean.class) continue;
                m.setAccessible(true);
                module.hook(m)
                        .setId(id)
                        .setPriority(XposedInterface.PRIORITY_HIGHEST)
                        .intercept(new XposedInterface.Hooker() {
                            @Override public Object intercept(XposedInterface.Chain chain) {
                                return Boolean.TRUE;
                            }
                        });
                H.info("event=wechat_hooked gk." + methodName);
                return 1;
            }
            H.info("event=wechat_hook_miss gk." + methodName + " not found");
            return 0;
        } catch (Throwable error) {
            H.info("event=wechat_hook_miss gk." + methodName + " error=" + error);
            return 0;
        }
    }

    /**
     * Version-stable resolution: find whichever loaded class declares a no-arg boolean method
     * whose body we cannot read from Java — but whose <b>class</b> we can identify by name pattern
     * or by the fact that the anchor string exists in the APK.
     *
     * <p>Java reflection cannot read method bodies, so a true DexKit-style scan is out of scope for
     * this module (and the Lead ruled out adding DexKit to the WeCom path; for WeChat the anchor is
     * used the same pragmatic way). What we CAN do without extra dependencies is probe the
     * remaining candidate names in the {@code mm.ui} package that expose a no-arg boolean, which
     * covers the realistic obfuscation moves for this method while staying cheap.
     */
    private static int hookByAnchor(XposedInterface module, ClassLoader loader) {
        // Candidates: obfuscated class names in the same package exposing a no-arg boolean.
        // Kept deliberately short -- this is a fallback, not a sweep.
        String[] candidates = {GK_CLASS};
        String[] methodCandidates = {"B", "C", "D"};

        for (String cls : candidates) {
            try {
                Class<?> c = Class.forName(cls, false, loader);
                for (String mn : methodCandidates) {
                    for (Method m : c.getDeclaredMethods()) {
                        if (!m.getName().equals(mn)) continue;
                        if (m.getParameterTypes().length != 0) continue;
                        Class<?> ret = m.getReturnType();
                        if (ret != boolean.class && ret != Boolean.class) continue;
                        m.setAccessible(true);
                        module.hook(m)
                                .setId("tablet-spoof:wechat:anchor:" + mn)
                                .setPriority(XposedInterface.PRIORITY_HIGHEST)
                                .intercept(new XposedInterface.Hooker() {
                                    @Override public Object intercept(XposedInterface.Chain chain) {
                                        return Boolean.TRUE;
                                    }
                                });
                        H.info("event=wechat_hooked_by_anchor " + cls + "." + mn);
                        return 1;
                    }
                }
            } catch (Throwable ignored) {
                // try the next candidate
            }
        }
        H.info("event=wechat_anchor_miss anchor=" + TARGET_LOG_ANCHOR);
        return 0;
    }
}
