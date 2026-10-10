package io.github.tabletspoof;

/**
 * Minimal logging. No-ops unless {@link Config#DEBUG} is on.
 *
 * <p>Rationale: WeCom performs anti-tamper checks including {@code onAppCheck} and scans
 * for the {@code xposed} string. A module that chatters into logcat from inside the target
 * process is both a performance cost and a detection signal. Everything here is therefore
 * silent by default, and nothing writes to the target app's own storage.
 */
public final class H {

    /** Set to a non-null XposedInterface-backed writer to enable diagnostics. */
    private static volatile Sink sink;

    public interface Sink {
        void log(String message);
    }

    public static void attach(Sink newSink) {
        sink = newSink;
    }

    public static void info(String message) {
        if (!Config.DEBUG) return;
        Sink current = sink;
        if (current != null) {
            current.log(message);
        }
    }

    private H() {}
}
