#!/system/bin/sh
# STABILITY CHECK (read-only, no probe needed).
#
# Context: getDeviceType() has returned BOTH 131073 (earlier, single sample) and
# 131076 (later, after a KV write that DID NOT HAPPEN). A value that changes
# without the tested intervention is not evidence the intervention works -- it
# means the measurement itself is unreliable.
#
# Before any further KV experiment we must know: is getDeviceType() stable?
#
# We cannot call Java from a shell, so we inspect the PERSISTENT state the app
# writes to disk. If a previous probe run left the KV or the MMKV pad-type set,
# that alone can explain a later "PAD" reading -- and it would confound every
# subsequent test until cleared.
log() { echo "[stability] $*"; }

log "=== 1. current persisted state (what would confound a re-run) ==="
P=/data/data/com.tencent.wework
log "  file_config_build_model: [$([ -f "$P/files/file_config_build_model" ] && cat "$P/files/file_config_build_model")]"
log "  MMKV store:"
ls -la "$P/files/mmkv/com.tencent.pb.common" 2>/dev/null | sed 's/^/    /'
log "    md5: $(md5sum "$P/files/mmkv/com.tencent.pb.common" 2>/dev/null | awk '{print $1}')"
log "    (compare against the baseline we recorded: 1d9413f9173f29e2c6f408f7c5bbfc12)"
echo ""

log "=== 2. does the store now contain our KV key? (it always did) ==="
for k in KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE local_save_pad_type_android; do
  N=$(grep -c "$k" "$P/files/mmkv/com.tencent.pb.common" 2>/dev/null)
  log "  $k : occurrences=$N"
done
echo ""

log "=== 3. any probe logs still present that we forgot to clear? ==="
find "$P" -maxdepth 1 -name 'ts_*.log' -o -maxdepth 1 -name 'zyprobe.log' 2>/dev/null | sed 's/^/  /'
echo ""

log "=== 4. explain WHY the two readings differ -- check both call sites ==="
log "  IMPORTANT: my timeline called getDeviceType() on the class resolved as"
log "  '...foundation.logic.Application' via the APP ClassLoader."
log "  The earlier single sample did the same. So the same target returned"
log "  different values at different times -- UNLESS one of the two calls"
log "  actually threw and we mis-logged."
log ""
log "  Check our own log for signs: did the timeline run print a BEFORE value,"
log "  and did any call report throwing?"
if [ -f "$P/ts_native.log" ]; then
  grep -nE 'CALL|TIMELINE|PROBE-FINAL|KV' "$P/ts_native.log" | sed 's/^/    /'
fi
echo ""

log "=== 5. the confounder hypothesis: did an EARLIER build write state? ==="
log "  Builds deployed to this path today, in order:"
log "    10968 (ArtProbe) / 11184 (my probe) / 11376 / 12024 (D2) / 12736 (Defer)"
log "    14784 (D4) / 13976 / 14952 / 17048 (3 CALLs) / 20352 (timeline+KV)"
log "  The 17048 build CALLED isAndroidPad() and getDeviceType() but wrote NOTHING."
log "  The 20352 build ATTEMPTED a KV write but logged 'gqp not resolvable'."
log "  => on our own evidence, NO build wrote KV or MMKV state."
log ""
log "  So the 131073 -> 131076 difference is NOT explained by our writes."
log "  That leaves: the getter is value-unstable, OR it depends on call timing,"
log "  OR on internal app state that evolves during startup."
echo ""

log "=== 6. what we would need to settle it ==="
log "  A probe that calls getDeviceType() N times in a row with NOTHING in"
log "  between, logging each result. If they differ => the getter is unstable"
log "  and every single-sample conclusion (including both of ours) is void."
log "  That is cheap, read-only, and should come BEFORE any further KV test."
