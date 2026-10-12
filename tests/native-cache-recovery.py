"""Malformed WeChat resolver cache recovers on the independent native path; no app data is cleared."""
import json,pathlib,subprocess,tempfile,time,xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parent.parent

def adb(*args,check=True):
    return subprocess.run(['adb',*args],capture_output=True,check=check).stdout.decode('utf-8','replace')
def su(cmd,check=True):return adb('shell','su','-c',cmd,check=check)
assert not su('pidof lspd',check=False).strip(),'LSPosed must be stopped'
cache='/data/user/0/com.tencent.mm/files/tablet-spoof/resolver-cache.json'
backup='/data/local/tmp/ts-wechat-cache-before-failure.json'
su('cp '+cache+' '+backup)
with tempfile.TemporaryDirectory(prefix='ts-cache-failure-') as d:
    p=pathlib.Path(d)/'invalid.json';p.write_bytes(b'{invalid cache test')
    adb('push',str(p),'/data/local/tmp/ts-invalid-cache.json')
su('cp /data/local/tmp/ts-invalid-cache.json '+cache)
try:
    su('am force-stop com.tencent.mm')
    su('am start -W -n com.tencent.mm/.plugin.account.ui.LoginUI')
    for attempt in range(16):
        time.sleep(1)
        status=su('cat /data/user/0/com.tencent.mm/files/tablet-spoof-native-status.txt')
        values=dict(x.split('=',1) for x in status.splitlines() if '=' in x)
        if values.get('detail')=='READY' and values.get('pid') in su('pidof com.tencent.mm').split():break
    else:raise AssertionError(status)
    logs=su('cat /data/user/0/com.tencent.mm/files/tablet-spoof/diagnostic.log')
    current='\n'.join(x for x in logs.splitlines() if 'pid='+values['pid']+' ' in x)
    assert 'CACHE_READ error=' in current,current
    assert 'CALLERS_ONE_PASS validated_owner=' in current,current
    assert current.count('same_class=true')>=2,current
    # A cold-start splash can consume the first routing intent.
    su('am start -W -n com.tencent.mm/.plugin.account.ui.LoginUI')
    adb('shell','uiautomator','dump','/data/local/tmp/ts-cache-ui.xml')
    nodes=list(ET.fromstring(adb('exec-out','cat','/data/local/tmp/ts-cache-ui.xml')).iter('node'))
    assert any(n.get('package')=='com.tencent.mm' for n in nodes)
    visible=any(n.get('text')=='平板和手机同时登录' for n in nodes)
    assert visible,'WeChat pad entry missing'
    print(status)
    selected=[x for x in current.splitlines() if any(tag in x for tag in ['DISCOVERY','ONE_PASS','READY','CACHE_READ','INITIALIZERS','TARGET_LOADER'])]
    (root/'docs/evidence/native/cache-recovery.json').write_text(json.dumps({'package':'com.tencent.mm',
        'module_version':'3.1.0','app_version':values['app_version'],'scenario':'malformed_cache','lsposed_running':False,
        'recovered':True,'pad_entry':visible,'status':values,'diagnostics':selected},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('CACHE_CORRUPTION_RECOVERY_PASS')
except:
    su('cp '+backup+' '+cache)
    raise
