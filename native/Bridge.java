package io.github.tabletspoof.nativebridge;

import android.app.Instrumentation;
import android.content.Context;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;

/** Loaded directly from the Zygisk module's DEX. No APK or LSPosed service. */
public final class Bridge {
    private static native Method hook(Method target, Object owner, Method callback);
    private static native boolean deoptimize(Method target);
    private static String pkg;
    private static String dataDir;
    private static int installed;
    private static final AtomicInteger hits = new AtomicInteger();
    private static String detail = "bootstrap";
    private static File statusFile;
    private static boolean done;

    public static void bootstrap(String packageName, String dir) throws Exception {
        pkg = packageName;
        dataDir = dir;
        Method method = Instrumentation.class.getDeclaredMethod("newApplication",
                ClassLoader.class, String.class, Context.class);
        ApplicationHook owner = new ApplicationHook();
        owner.backup = hook(method, owner,
                ApplicationHook.class.getDeclaredMethod("callback", Object[].class));
        if (owner.backup == null) throw new IllegalStateException("newApplication hook failed");
        deoptimize(method);
    }

    public static final class ApplicationHook {
        private Method backup;
        public Object callback(Object[] args) throws Throwable {
            ClassLoader loader = (ClassLoader) args[1];
            Context context = (Context) args[3];
            try { install(loader, context); }
            catch (Throwable e) { detail = "FAIL " + e.getClass().getName(); writeStatus(); }
            // The original Application is constructed normally; login data is untouched.
            try {
                return backup.invoke(args[0], Arrays.copyOfRange(args, 1, args.length));
            } catch (java.lang.reflect.InvocationTargetException e) { throw e.getCause(); }
        }
    }

    public static final class TrueHook {
        public Object callback(Object[] args) {
            int count = hits.incrementAndGet();
            if (count <= 3 || count == 10 || count == 100) writeStatus();
            return Boolean.TRUE;
        }
    }

    private static void replace(ClassLoader loader, String name, String method, int parameters) throws Exception {
        Class<?> type = Class.forName(name, false, loader);
        Method selected = null;
        for (Method m : type.getDeclaredMethods()) {
            if (m.getName().equals(method) && m.getReturnType() == boolean.class
                    && m.getParameterTypes().length == parameters && Modifier.isStatic(m.getModifiers())) {
                if (selected != null) throw new IllegalStateException("ambiguous " + name + "." + method);
                selected = m;
            }
        }
        if (selected == null) throw new NoSuchMethodException(name + "." + method);
        selected.setAccessible(true);
        TrueHook owner = new TrueHook();
        Method backup = hook(selected, owner, TrueHook.class.getDeclaredMethod("callback", Object[].class));
        if (backup == null) throw new IllegalStateException("hook failed " + name + "." + method);
        installed++;
        detail += " " + name + "." + method;
    }

    private static synchronized void install(ClassLoader loader, Context context) throws Exception {
        if (done) return;
        done = true;
        statusFile = new File(context.getFilesDir(), "tablet-spoof-native-status.txt");
        detail = "INSTALLING";
        writeStatus();
        String version = context.getPackageManager().getPackageInfo(pkg, 0).versionName;
        String supported = "com.tencent.mm".equals(pkg) ? "8.0.78" : "5.0.3";
        if (!supported.equals(version)) {
            detail = "UNSUPPORTED_VERSION " + version + " expected=" + supported;
            writeStatus();
            return;
        }
        if ("com.tencent.mm".equals(pkg)) {
            // These signatures are verified for 8.0.78 only. Never guess another boolean.
            replace(loader, "com.tencent.mm.ui.gk", "B", 0);
            replace(loader, "com.tencent.mm.ui.gk", "C", 1);
        } else if ("com.tencent.wework".equals(pkg)) {
            replace(loader, "com.tencent.wework.foundation.logic.Application", "isAndroidPad", 0);
        } else { throw new SecurityException("package not allowed"); }
        // AOT-compiled login callers may have inlined the original tiny predicate.
        String[] callers = "com.tencent.mm".equals(pkg)
                ? new String[]{"com.tencent.mm.plugin.account.ui.LoginUI",
                    "com.tencent.mm.plugin.account.ui.LoginHistoryUI",
                    "com.tencent.mm.plugin.account.ui.MobileInputUI"}
                : new String[]{"com.tencent.wework.login.controller.LoginWxAuthActivity"};
        for (String caller : callers) {
            try {
                for (Method m : Class.forName(caller, false, loader).getDeclaredMethods()) {
                    if (!Modifier.isAbstract(m.getModifiers()) && !Modifier.isNative(m.getModifiers()))
                        deoptimize(m);
                }
            } catch (Throwable ignored) { /* unavailable callers do not justify guessing */ }
        }
        detail = detail.replace("INSTALLING", "READY");
        writeStatus();
    }

    private static synchronized void writeStatus() {
        if (statusFile == null) return;
        String text = "package=" + pkg + "\npid=" + android.os.Process.myPid() + "\nengine=zygisk-lsplant\nhooks=" + installed
                + "\nhits=" + hits.get() + "\ndetail=" + detail + "\n";
        try (FileOutputStream out = new FileOutputStream(statusFile)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
        } catch (Throwable ignored) { /* diagnostics cannot break the host app */ }
    }
}
