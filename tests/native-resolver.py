"""Semantic discovery, ambiguity, malformed DEX and opcode boundaries on JVM."""
import pathlib,struct,subprocess,tempfile,zipfile
root=pathlib.Path(__file__).resolve().parent.parent
def leb(n):
    out=bytearray()
    while n>=128: out.append((n&127)|128);n>>=7
    out.append(n);return out
def fixture(mode):
    owners=['Lcom/tencent/mm/ui/gk;' if mode.startswith('hint_') else 'Lcom/tencent/mm/ui/renamed_pad;']
    if mode=='ambiguous':owners.append('Lcom/tencent/mm/ui/another_pad;')
    strings=owners+['Lcom/tencent/mm/plugin/account/ui/LoginUI;','Z','I','V',
        'inTabletEnv, widthDp:%s >= %s, return true',
        'inTabletEnv, no tablet condition matched, return false','new_predicate','new_wrapper','login']
    types=owners+['Lcom/tencent/mm/plugin/account/ui/LoginUI;','Z','I','V']
    b=bytearray(2048)
    def i(off,*values):struct.pack_into('<'+'I'*len(values),b,off,*values)
    def h(off,*values):struct.pack_into('<'+'H'*len(values),b,off,*values)
    b[:8]=b'dex\n035\0';i(36,112);i(40,0x12345678)
    for idx,s in enumerate(strings):
        i(112+idx*4,len(b));b.extend(leb(len(s))+s.encode()+b'\0')
    for idx,s in enumerate(types):i(400+idx*4,strings.index(s))
    # type_list.size is the number of elements, not a byte count.
    i(700,2);h(704,types.index('I'),types.index('I'))
    for idx,params in enumerate([700,0,0]):i(500+idx*12,strings.index('Z'),types.index('I') if mode=='wrong_return' and idx==0 else types.index('V' if idx==2 else 'Z'),params)
    mid=0
    for ci,owner in enumerate(owners):
        for name,proto in [('new_predicate',0),('new_wrapper',1)]:
            h(800+mid*8,ci,proto);i(804+mid*8,strings.index(name));mid+=1
    h(800+mid*8,len(owners),2);i(804+mid*8,strings.index('login'))
    for ci,owner in enumerate(owners):
        dataoff=1200+ci*50;code=1500+ci*100;wrapper=code+50
        data=leb(0)+leb(0)+leb(2)+leb(0)+leb(ci*2)+leb(9)+leb(code)+leb(1)+leb(9)+leb(wrapper)
        b[dataoff:dataoff+len(data)]=data;i(1000+ci*32,ci,1,0xffffffff,0,0,0,dataoff,0)
        if mode in ('pool_only','hint_pool_only'):
            units=[0x0300,2,4,0,0x001a,strings.index(strings[-5]),0x001a,strings.index(strings[-4]),0x0012,0x000f]
        else:
            units=[0x001a,strings.index('inTabletEnv, widthDp:%s >= %s, return true'),0x011b,
                   strings.index('inTabletEnv, no tablet condition matched, return false'),0,0x0012,0x000f]
        if mode=='bad_opcode':units[-2]=0x003e
        h(code,4,2,0,0);i(code+8,0,len(units));h(code+16,*units)
        units=[0x0071,ci*2,0,0x000a,0x000f]
        h(wrapper,2,0,0,0);i(wrapper+8,0,len(units));h(wrapper+16,*units)
    dataoff=1350;code=1900;data=leb(0)+leb(0)+leb(0)+leb(1)+leb(mid)+leb(1)+leb(code)
    b[dataoff:dataoff+len(data)]=data;i(1000+len(owners)*32,len(owners),1,0xffffffff,0,0,0,dataoff,0)
    h(code,2,1,0,0);i(code+8,0,4);h(code+16,0x0071,1,0,0x000e)
    i(56,len(strings),112,len(types),400,3,500,0,0,mid+1,800,len(owners)+1,1000)
    i(32,len(b))
    if mode=='truncated':b=b[:-10]
    return b
def protocol_fixture(mode):
    owners=['Lcom/tencent/wework/foundation/impl/RenamedService;']
    if mode=='protocol_ambiguous': owners.append('Lcom/tencent/wework/foundation/impl/OtherService;')
    strings=owners+['Z','I','getDeviceType','isAndroidPad','KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE']
    types=owners+['Z','I'];b=bytearray(1800)
    def i(off,*v):struct.pack_into('<'+'I'*len(v),b,off,*v)
    def h(off,*v):struct.pack_into('<'+'H'*len(v),b,off,*v)
    b[:8]=b'dex\n035\0';i(36,112);i(40,0x12345678)
    for index,value in enumerate(strings):
        i(112+index*4,len(b));b.extend(leb(len(value))+value.encode()+b'\0')
    for index,value in enumerate(types):i(300+index*4,strings.index(value))
    i(400,strings.index('I'),types.index('I'),0);i(412,strings.index('Z'),types.index('Z'),0)
    for ci,owner in enumerate(owners):
        h(500+ci*16,ci,0);i(504+ci*16,strings.index('getDeviceType'))
        h(508+ci*16,ci,1);i(512+ci*16,strings.index('isAndroidPad'))
        dataoff=700+ci*50;getter=1000+ci*200;pad=getter+100
        data=leb(0)+leb(0)+leb(0)+leb(2)+leb(ci*2)+leb(1)+leb(getter)+leb(1)+leb(1)+leb(pad)
        b[dataoff:dataoff+len(data)]=data;i(600+ci*32,ci,1,0xffffffff,0,0,0,dataoff,0)
        enum=131077 if mode=='protocol_changed_enum' else 131076
        units=[0x001a,strings.index('KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE'),0x006e,ci*2+1,0,
               0x0014,enum&65535,enum>>16,0x0014,131073&65535,131073>>16,0x000f]
        if mode=='protocol_pool_only':units[:2]=[0,0]
        h(getter,2,1,0,0);i(getter+8,0,len(units));h(getter+16,*units)
        h(pad,2,1,0,0);i(pad+8,0,2);h(pad+16,0x0012,0x000f)
    i(56,len(strings),112,len(types),300,2,400,0,0,len(owners)*2,500,len(owners),600);i(32,len(b))
    return b
with tempfile.TemporaryDirectory(prefix='ts-resolver-tests-') as d:
    stage=pathlib.Path(d);classes=stage/'classes'
    subprocess.run(['javac','-encoding','UTF-8','-d',str(classes),str(root/'native/DexResolver.java'),str(root/'tests/ResolverHarness.java')],check=True)
    cases={'renamed':None,'hint_valid':None,'hint_pool_only':'TARGET_MISSING_OR_AMBIGUOUS','pool_only':'TARGET_MISSING_OR_AMBIGUOUS','wrong_return':'TARGET_MISSING_OR_AMBIGUOUS',
        'ambiguous':'TARGET_MISSING_OR_AMBIGUOUS','truncated':'DEX_HEADER_INVALID','bad_opcode':'DEX_OPCODE_INVALID'}
    for mode,error in cases.items():
        apk=stage/(mode+'.apk')
        with zipfile.ZipFile(apk,'w') as z:z.writestr('classes.dex',fixture(mode))
        r=subprocess.run(['java','-cp',str(classes),'io.github.tabletspoof.nativebridge.ResolverHarness','wechat',str(apk)],capture_output=True)
        text=(r.stdout+r.stderr).decode('utf-8','replace')
        if error:assert r.returncode!=0 and error in text,(mode,text)
        else:
            assert r.returncode==0 and 'new_predicate[I, I]Z' in text and 'new_wrapper[]Z' in text and 'CALLERS 1' in text,text
            assert ('CALLERS_ONE_PASS' in text)==(mode=='hint_valid'),text
        print('PASS',mode,flush=True)
    protocol_cases={'protocol_valid':None,'protocol_changed_enum':'PROTOCOL_MISSING_OR_AMBIGUOUS',
                    'protocol_pool_only':'PROTOCOL_MISSING_OR_AMBIGUOUS','protocol_ambiguous':'PROTOCOL_MISSING_OR_AMBIGUOUS'}
    for mode,error in protocol_cases.items():
        apk=stage/(mode+'.apk')
        with zipfile.ZipFile(apk,'w') as z:z.writestr('classes.dex',protocol_fixture(mode))
        r=subprocess.run(['java','-cp',str(classes),'io.github.tabletspoof.nativebridge.ResolverHarness','protocol',str(apk)],capture_output=True)
        text=(r.stdout+r.stderr).decode('utf-8','replace')
        if error:assert r.returncode!=0 and error in text,(mode,text)
        else:assert r.returncode==0 and 'RenamedService;->getDeviceType[]I' in text and 'forced_int=131076' in text,text
        print('PASS',mode,flush=True)
print('RESOLVER_PASS',len(cases)+len(protocol_cases))
