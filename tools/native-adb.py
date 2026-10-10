"""Checked ADB actions: never reboot after a failed build/copy/deploy."""
import argparse
import pathlib
import subprocess
import shutil
import tempfile

root=pathlib.Path(__file__).resolve().parent.parent
def adb(*args):
    subprocess.run(['adb',*args],check=True)
parser=argparse.ArgumentParser()
parser.add_argument('action',choices=['build','build-deploy','capture'])
parser.add_argument('--reboot',action='store_true')
parser.add_argument('--name',default='native')
args=parser.parse_args()
if args.action in ('build','build-deploy'):
    for name in ['module.cpp','loader.cpp','elf_symbols.hpp','zygisk.hpp','build-engine.sh','module.prop','deploy-test.sh']:
        adb('push',str(root/'native'/name),'/data/local/tmp/ts-native-src/'+name)
    # Shell UID cannot write inside the root-created output directory.
    adb('push',str(root/'native/output/bridge.dex'),'/data/local/tmp/ts-native-bridge.dex')
    adb('shell','su','-c','cp /data/local/tmp/ts-native-bridge.dex /data/local/tmp/ts-native-src/output/bridge.dex')
    adb('shell','su','-c','sh /data/local/tmp/ts-native-src/build-engine.sh > /data/local/tmp/ts-native-engine-build.log 2>&1')
    adb('shell','su','-c','tail -n 20 /data/local/tmp/ts-native-engine-build.log')
    if args.action == 'build-deploy':
        adb('shell','su','-c','sh /data/local/tmp/ts-native-src/deploy-test.sh')
    else:
        # This Windows ADB build corrupts non-ASCII directory destinations.
        # Pull to an ASCII staging directory, then copy with Python Unicode paths.
        with tempfile.TemporaryDirectory(prefix='ts-native-export-') as stage:
            for relative in ['zygisk/arm64-v8a.so','lib/libtablet-spoof-engine.so','lib/libc++_shared.so']:
                local=pathlib.Path(stage)/pathlib.PurePosixPath(relative).name
                adb('pull','/data/local/tmp/ts-native-src/output/'+relative,str(local))
                final=root/'native/output'/relative
                final.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(local,final)
    if args.reboot:
        adb('reboot')
else:
    folder=root/'docs/evidence/native'
    folder.mkdir(parents=True,exist_ok=True)
    adb('shell','uiautomator','dump','/data/local/tmp/ts-native-ui.xml')
    with tempfile.TemporaryDirectory(prefix='ts-ui-') as stage:
        local=pathlib.Path(stage)/'ui.xml'
        adb('pull','/data/local/tmp/ts-native-ui.xml',str(local))
        shutil.copy2(local,folder/(args.name+'.xml'))
    with (folder/(args.name+'.png')).open('wb') as output:
        subprocess.run(['adb','exec-out','screencap','-p'],stdout=output,check=True)
