#!/system/bin/sh
# THE DECISIVE CHECK: do any zygote-domain AVC denials name our artifacts?
#
# If yes -> the mechanism is confirmed (zygote-side SELinux).
# If no  -> the mechanism is NOT SELinux, and we stop and document it as unknown.
#
# Previous run showed 82x "search ... shell_data_file" which looked unrelated,
# but that was a lossy sed summary that collapsed the field. This run prints the
# RAW lines and greps them properly, because a summary that drops the field it
# needs is exactly how a check reports the wrong thing.
log() { echo "[zygote] $*"; }

log "=== 1. count and full text of ALL zygote denials ==="
dmesg 2>/dev/null | grep 'avc:.*denied' | grep -c 'scontext=u:r:zygote:s0' | sed 's/^/  total: /'
echo ""
log "  --- raw lines (all of them) ---"
dmesg 2>/dev/null | grep 'avc:.*denied' | grep 'scontext=u:r:zygote:s0' | sed 's/^/  /'
echo ""

log "=== 2. do any name our artifacts? (case-insensitive, all denial lines) ==="
for needle in tablet-spoof arm64-v8a adb_data_file zygisk lspd zygiskd execmem execmod \
              'com.tencent.wework' 'com.tencent.mm' 401_modules; do
  N=$(dmesg 2>/dev/null | grep 'avc:.*denied' | grep -ci "$needle")
  printf '  %-22s %s\n' "$needle" "${N:-0}"
done
echo ""

log "=== 3. what TCLASSES and PERMS appear in zygote denials? ==="
log "  tclass distribution:"
dmesg 2>/dev/null | grep 'avc:.*denied' | grep 'scontext=u:r:zygote:s0' | \
  sed 's/.*tclass=\([a-z_]*\).*/\1/' | sort | uniq -c | sort -rn | sed 's/^/    /'
log "  permission distribution:"
dmesg 2>/dev/null | grep 'avc:.*denied' | grep 'scontext=u:r:zygote:s0' | \
  sed 's/.*denied  *{ \([^}]*\) }.*/\1/' | sort | uniq -c | sort -rn | sed 's/^/    /'
log "  target contexts:"
dmesg 2>/dev/null | grep 'avc:.*denied' | grep 'scontext=u:r:zygote:s0' | \
  sed 's/.*tcontext=\([^ ]*\).*/\1/' | sort | uniq -c | sort -rn | sed 's/^/    /'
echo ""

log "=== 4. also look at the FULL log for anything about our module or loading ==="
dmesg 2>/dev/null | grep -iE 'tablet-spoof|zygisk.*(deny|denied|fail|error)' | head -15 | sed 's/^/  /'
echo ""

log "=== 5. check the audit/user_init logs APatch keeps (may have more detail) ==="
ls -la /data/adb/ap/log/user_init_log/ 2>/dev/null | sed 's/^/  /'
for f in /data/adb/ap/log/user_init_log/*; do
  [ -f "$f" ] || continue
  echo "  --- $f"
  grep -iE 'avc|denied|zygisk|tablet' "$f" 2>/dev/null | tail -15 | sed 's/^/      /'
done
echo ""

log "=== 6. is SELinux enforcing right now? ==="
getenforce 2>/dev/null | sed 's/^/  /'
