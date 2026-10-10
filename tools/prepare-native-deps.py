"""Pin and stage upstream sources, generate a direct Clang module build."""
import pathlib
import re
import shutil
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
research = pathlib.Path('C:/Users/Lenovo/AppData/Local/Temp/tablet-spoof-research-20261010')
dest = root / 'native' / 'third_party'
dest.mkdir(parents=True, exist_ok=True)
upstream = research / 'LSPlant'
shutil.copytree(upstream / 'lsplant/src/main/jni', dest / 'lsplant',
                ignore=shutil.ignore_patterns('.git', '.gitmodules'), dirs_exist_ok=True)
shutil.copy2(upstream / 'LICENSE', dest / 'LICENSE-LSPlant')
with zipfile.ZipFile(research / 'dobby.aar') as z:
    for n in z.namelist():
        if n.endswith('android.arm64-v8a/libdobby.a') or n.endswith('/dobby.h'):
            (dest / pathlib.PurePosixPath(n).name).write_bytes(z.read(n))

src = dest / 'lsplant'
exports = {}
for p in list(src.rglob('*.cxx')) + list(src.rglob('*.ixx')):
    s = p.read_text()
    m = re.search(r'^export module ([\w:]+);', s, re.M)
    if m:
        name = m[1]
        imports = re.findall(r'^(?:export )?import ([\w:]+);', s, re.M)
        deps = [(name.split(':')[0] + d if d.startswith(':') else d) for d in imports]
        exports[name] = (p, deps)
order = []
def visit(n):
    if n in order:
        return
    for d in exports[n][1]:
        visit(d)
    order.append(n)
for n in exports:
    visit(n)

phone_root = '/data/local/tmp/ts-native-src'
flags = '-std=c++23 -O2 -fPIC -fvisibility=hidden -DNDEBUG -DLOG_TAG=\\\"tablet-spoof-native\\\"'
includes = [src, src/'include', src/'include/utils', src/'external/dex_builder/include',
            src/'external/dex_builder/external/parallel_hashmap', dest]
def remote(p):
    return phone_root + '/' + p.relative_to(root / 'native').as_posix()
flags += ''.join(' -I'+remote(p) for p in includes)
lines = ['#!/system/bin/sh', 'set -eu', 'TC=/data/data/com.termux/files/usr',
         'export PATH="$TC/bin:$PATH"', 'export LD_LIBRARY_PATH="$TC/lib"',
         'cd '+phone_root, 'mkdir -p obj', 'CXX="$TC/bin/clang++"']
module_flags = []
objects = []
for i,n in enumerate(order):
    p=exports[n][0]
    pcm='obj/'+n.replace(':','-')+'.pcm'
    obj='obj/module-'+str(i)+'.o'
    lines += ['echo "MODULE '+n+'"',
              '"$CXX" '+flags+' '+' '.join(module_flags)+' -x c++-module --precompile '+remote(p)+' -o '+pcm]
    module_flags.append('-fmodule-file='+n+'='+pcm)
    lines += ['"$CXX" '+flags+' '+' '.join(module_flags)+' -c '+pcm+' -o '+obj]
    objects.append(obj)
db=src/'external/dex_builder'
sources=[src/'lsplant.cc', db/'dex_builder.cc', db/'dex_helper.cc'] + list((db/'slicer').glob('*.cc')) + [db/'slicer/sha1.cpp']
for i,p in enumerate(sources):
    obj='obj/source-'+str(i)+'.o'
    lines += ['echo "SOURCE '+p.name+'"',
              '"$CXX" '+flags+' '+' '.join(module_flags)+' -c '+remote(p)+' -o '+obj]
    objects.append(obj)
lines += ['"$TC/bin/llvm-ar" rcs obj/liblsplant.a '+' '.join(objects), 'echo LSPLANT_BUILD_OK']
(root/'native/build-deps.sh').write_text('\n'.join(lines)+'\n', newline='\n')
(dest/'UPSTREAM.txt').write_text('LSPlant d8b5d1dbb664abc606644036822e4bb64547edf6\nDexBuilder ac7fb2230954ee311808bad469b0db501f31bfb8\nparallel-hashmap 0cd57d29a959256ed66b2afdd1009928fc625d09\nDobby io.github.vvb2060.ndk:dobby:1.2\n', newline='\n')
print('Staged', len(order), 'modules and', len(sources), 'sources')
