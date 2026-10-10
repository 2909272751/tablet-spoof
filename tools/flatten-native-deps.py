"""Build identical upstream declarations without Clang's crashing C++ PCM path.

Upstream sources are preserved. Generated headers replace only module/import/export
syntax; implementation bodies stay unchanged. Output is a single LSPlant TU.
"""
import pathlib
import re
root=pathlib.Path(__file__).resolve().parent.parent / 'native'
src=root/'third_party/lsplant'
out=root/'flattened'
out.mkdir(exist_ok=True)
exports={}
for p in list(src.rglob('*.cxx'))+list(src.rglob('*.ixx')):
    s=p.read_text()
    m=re.search(r'^export module ([\w:]+);',s,re.M)
    if m: exports[m[1]]=p
def convert(p,name):
    text=p.read_text()
    # Only handle.cxx has an export declaration block. Remove its wrapping braces.
    while 'export {' in text:
        pos=text.index('export {'); start=pos+len('export {'); depth=1; end=start
        while depth:
            if text[end]=='{': depth+=1
            elif text[end]=='}': depth-=1
            end+=1
        text=text[:pos]+text[start:end-1]+text[end:]
    text=re.sub(r'^(?:export )?module[^;]*;\s*', '', text, flags=re.M)
    def imported(m):
        dep=m[1]; dep=(name.split(':')[0]+dep) if dep.startswith(':') else dep
        return '#include "mod-'+dep.replace(':','-')+'.hpp"'
    text=re.sub(r'^(?:export )?import ([\w:]+);',imported,text,flags=re.M)
    text=re.sub(r'\bexport ', '', text)
    return text
for name,p in exports.items():
    (out/('mod-'+name.replace(':','-')+'.hpp')).write_text('#pragma once\n'+convert(p,name), newline='\n')
(out/'lsplant.cpp').write_text(convert(src/'lsplant.cc','lsplant'), newline='\n')
phone='/data/local/tmp/ts-native-src'
include=['third_party/lsplant','third_party/lsplant/include','third_party/lsplant/include/utils','flattened',
         'third_party/lsplant/external/dex_builder/include','third_party/lsplant/external/dex_builder/external/parallel_hashmap']
flags='-std=c++23 -O2 -fPIC -fvisibility=hidden -DNDEBUG -Wno-deprecated-declarations -Wno-gnu-string-literal-operator-template'
flags+=''.join(' -I'+phone+'/'+p for p in include)
db=src/'external/dex_builder'
sources=[out/'lsplant.cpp',db/'dex_builder.cc',db/'dex_helper.cc']+list((db/'slicer').glob('*.cc'))+[db/'slicer/sha1.cpp']
lines=['#!/system/bin/sh','set -eu','TC=/data/data/com.termux/files/usr','export PATH="$TC/bin:$PATH"',
       'export LD_LIBRARY_PATH="$TC/lib"','cd '+phone,'mkdir -p obj-flat','CXX="$TC/bin/clang++"']
objects=[]
for i,p in enumerate(sources):
    obj='obj-flat/source-'+str(i)+'.o';objects.append(obj)
    lines+=['echo "BUILD '+p.name+'"','"$CXX" '+flags+' -c '+phone+'/'+p.relative_to(root).as_posix()+' -o '+obj]
lines+=['"$TC/bin/llvm-ar" rcs obj-flat/liblsplant.a '+' '.join(objects),'echo LSPLANT_BUILD_OK']
(root/'build-flat.sh').write_text('\n'.join(lines)+'\n',newline='\n')
print('Generated',len(exports),'headers')
