"""Package checked native payload, licenses and a separate editable source ZIP."""
import hashlib
import pathlib
import struct
import zipfile

root=pathlib.Path(__file__).resolve().parent.parent
native=root/'native'
dist=root/'dist'
dist.mkdir(exist_ok=True)
manifest={}
for line in (native/'module.prop').read_text(encoding='utf-8').splitlines():
    if '=' in line:
        k,v=line.split('=',1);manifest[k]=v
version=manifest['version']
payload={name:(native/'output'/name).read_bytes() for name in [
    'zygisk/arm64-v8a.so','lib/libtablet-spoof-engine.so','lib/libc++_shared.so','bridge.dex']}
for name,data in payload.items():
    if name.endswith('.so'):
        assert data[:4]==b'\x7fELF' and data[4]==2 and struct.unpack_from('<H',data,18)[0]==183, name
    else:
        assert data[:4]==b'dex\n',name
for name in ['module.prop','action.sh','report.sh','customize.sh','uninstall.sh','README.md']:
    payload[name]=(native/name).read_text(encoding='utf-8-sig').replace('\r\n','\n').encode()
for p in (native/'META-INF').rglob('*'):
    if p.is_file(): payload[p.relative_to(native).as_posix()]=p.read_bytes().replace(b'\r\n',b'\n')
for p in (native/'third_party').glob('LICENSE-*'):
    payload['licenses/'+p.name]=p.read_bytes()
for name,p in [('LICENSE-DexBuilder',native/'third_party/lsplant/external/dex_builder/LICENSE'),
               ('LICENSE-parallel-hashmap',native/'third_party/lsplant/external/dex_builder/external/parallel_hashmap/LICENSE')]:
    payload['licenses/'+name]=p.read_bytes()
payload['NOTICE.txt']=(
    'Zygisk API / installer: https://github.com/topjohnwu/zygisk-module-sample ; https://github.com/topjohnwu/Magisk\n'
    'LSPlant: https://github.com/LSPosed/LSPlant\n'
    'DexBuilder: https://github.com/LSPosed/DexBuilder\n'
    'Dobby: https://github.com/jmpews/Dobby ; io.github.vvb2060.ndk:dobby:1.2\n'
    'C++ runtime: LLVM libc++ (Termux 21.1.8), Apache 2.0 with LLVM exception\n'
    'Editable source/relink inputs accompany this module in tablet-spoof-pure-source-v'+version+'.zip\n'
    'Original copyright and license terms are retained in third_party and individual sources.\n'
).encode()
payload['skip_mount']=b''
payload['SHA256SUMS']=(''.join(hashlib.sha256(data).hexdigest()+'  '+name+'\n'
                             for name,data in sorted(payload.items()))).encode()
target=dist/('tablet-spoof-pure-v'+version+'.zip')
with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for name,data in sorted(payload.items()):
        info=zipfile.ZipInfo(name)
        info.create_system=3
        info.external_attr=(0o100755 if name.endswith('.sh') or name.endswith('update-binary') else 0o100644)<<16
        info.compress_type=zipfile.ZIP_DEFLATED
        z.writestr(info,data)
with zipfile.ZipFile(target) as z:
    assert z.testzip() is None
    assert not any(n.endswith('.apk') for n in z.namelist())
    for name,data in payload.items(): assert z.read(name)==data,name
source=dist/('tablet-spoof-pure-source-v'+version+'.zip')
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in native.rglob('*'):
        if not p.is_file() or any(s in p.parts for s in ['generated','output','__pycache__']): continue
        z.write(p,p.relative_to(root).as_posix())
    for name in ['native-adb.py','flatten-native-deps.py','prepare-native-deps.py','package-native.py']:
        z.write(root/'tools'/name,'tools/'+name)
    z.write(root/'tests/native-behavior.py','tests/native-behavior.py')
    z.write(root/'tests/native-resolver.py','tests/native-resolver.py')
    z.write(root/'tests/native-cache-recovery.py','tests/native-cache-recovery.py')
    z.write(root/'tests/ResolverHarness.java','tests/ResolverHarness.java')
    for name in ['AGENTS.md','README.md']:
        z.write(root/name,name)
    for p in (root/'docs/evidence/native').glob('*.json'):
        z.write(p,p.relative_to(root).as_posix())
for p in [target,source]:
    digest=hashlib.sha256(p.read_bytes()).hexdigest()
    p.with_suffix(p.suffix+'.sha256').write_text(digest+'  '+p.name+'\n')
    print(p.name,p.stat().st_size,digest)
