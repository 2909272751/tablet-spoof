"""Real-device, LSPosed-off, OFF/ON UI tests. Never clear app data."""
import json
import pathlib
import subprocess
import shutil
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

root=pathlib.Path(__file__).resolve().parent.parent
dest=root/'docs/evidence/native'
dest.mkdir(parents=True,exist_ok=True)
def adb(*args,check=True):
    result=subprocess.run(['adb',*args],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=check)
    return result.stdout.decode('utf-8','replace')
def su(command,check=True): return adb('shell','su','-c',command,check=check)
def launch(pkg,activity):
    su('am force-stop '+pkg)
    su('am start -W -n '+pkg+'/'+activity)
    # Cold-start Splash can consume another intent until startup has settled.
    # Match only the current focused window, never an old window in dumpsys.
    for attempt in range(24):
        focus='\n'.join(line for line in adb('shell','dumpsys','window').splitlines()
                        if 'mCurrentFocus=' in line)
        if pkg+'/'+pkg+activity in focus or pkg+'/'+activity in focus:
            time.sleep(.7)
            return
        time.sleep(1)
        if attempt % 3 == 2:
            su('am start -W -n '+pkg+'/'+activity)
    raise AssertionError('Target did not reach expected login activity: '+pkg)
def capture(name):
    adb('shell','uiautomator','dump','/data/local/tmp/ts-native-ui.xml')
    # Windows ADB can silently corrupt Unicode destination paths.
    with tempfile.TemporaryDirectory(prefix='ts-ui-') as stage:
        local=pathlib.Path(stage)/'ui.xml'
        adb('pull','/data/local/tmp/ts-native-ui.xml',str(local))
        shutil.copy2(local,dest/(name+'.xml'))
    with (dest/(name+'.png')).open('wb') as f:
        subprocess.run(['adb','exec-out','screencap','-p'],stdout=f,check=True)
    return ET.parse(dest/(name+'.xml'))

assert not su('pidof lspd',check=False).strip(), 'LSPosed must be stopped'
assert 'LSPOSED_DISABLED' in su('test -f /data/adb/modules/zygisk_lsposed/disable && echo LSPOSED_DISABLED')
assert 'Enforcing' in adb('shell','getenforce')
adb('shell','input','keyevent','KEYCODE_WAKEUP')
adb('shell','input','keyevent','82')
results=[]
try:
    for enabled in (False,True,False,True):
        su(('rm -f' if enabled else 'touch')+' /data/adb/modules/tablet-spoof-pure/off')
        for pkg,activity in [('com.tencent.wework','.login.controller.LoginWxAuthActivity'),
                             ('com.tencent.mm','.plugin.account.ui.LoginUI')]:
            launch(pkg,activity)
            name=f"round-{len(results)+1}-{'on' if enabled else 'off'}-{pkg.split('.')[-1]}"
            tree=capture(name)
            packages={n.get('package') for n in tree.iter('node')}
            assert pkg in packages, ('Wrong captured application',pkg,packages)
            labels=[n.get('text','') for n in tree.iter('node')]
            visible=any('平板和手机同时登录' in text for text in labels)
            assert visible==enabled, (pkg,enabled,visible)
            result={'package':pkg,'enabled':enabled,'pad_entry':visible,'evidence':name}
            if enabled:
                status=su('cat /data/user/0/'+pkg+'/files/tablet-spoof-native-status.txt')
                values=dict(line.split('=',1) for line in status.splitlines() if '=' in line)
                assert int(values['hits'])>0, status
                assert values['detail'].startswith('READY'), status
                if 'pid' in values:
                    assert values['pid'] in su('pidof '+pkg).split(), 'stale status'
                result['hook_status']=values
            results.append(result)
            print(json.dumps(result,ensure_ascii=False),flush=True)
finally:
    su('rm -f /data/adb/modules/tablet-spoof-pure/off')
    (dest/'behavior-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('BEHAVIOR_PASS',len(results))
