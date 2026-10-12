package io.github.tabletspoof.nativebridge;

import java.io.*;
import java.util.*;
import java.util.zip.*;

/** Reads installed APK DEX code, not app data. Formats/widths follow AOSP DEX. */
public final class DexResolver {
    public interface Reporter { void event(String text); }
    public static final class Target {
        public String owner, name, returns;
        public String[] parameters;
        public boolean isStatic;
        public Integer forcedInt;
        public Target(String owner, String name, String returns, String[] parameters, boolean isStatic) {
            this.owner=owner; this.name=name; this.returns=returns;
            this.parameters=parameters; this.isStatic=isStatic;
        }
        public String key() { return owner+"->"+name+Arrays.toString(parameters)+returns; }
        @Override public String toString() { return key(); }
    }
    public static final class Plan {
        public String rule;
        public final List<Target> targets=new ArrayList<>();
        public final List<Target> callers=new ArrayList<>();
    }
    private static final int MAX_DEX=64*1024*1024, MAX_TOTAL=256*1024*1024;
    private static void check(boolean value,String reason) throws IOException {
        if (!value) throw new IOException(reason);
    }
    public static Plan resolve(String[] apks, boolean wechat, Reporter reporter) throws IOException {
        Plan plan=new Plan();
        plan.rule=wechat?"DEX_TABLET_LOG_PAIR_AND_STATIC_WRAPPER":"DEX_LOGIN_PAD_CALL";
        long start=System.nanoTime(); int total=0,files=0;
        // This previous owner is only a one-pass caller-index hint, NEVER target evidence.
        // Renamed owners use the full second pass after semantic target validation.
        String hint=wechat?"Lcom/tencent/mm/ui/gk;":null;
        Map<String,List<Target>> hintedCalls=new HashMap<>();
        for (String apk : apks) {
            try (ZipFile zip=new ZipFile(apk)) {
                Enumeration<? extends ZipEntry> entries=zip.entries();
                while(entries.hasMoreElements()) {
                    ZipEntry e=entries.nextElement();
                    if (!e.getName().matches("classes(?:[2-9][0-9]*|1[0-9]+)?\\.dex")) continue;
                    check(++files<=64,"DEX_FILE_LIMIT");
                    check(e.getSize()>0 && e.getSize()<=MAX_DEX,"DEX_SIZE_LIMIT "+e.getName());
                    check((total+=e.getSize())<=MAX_TOTAL,"DEX_TOTAL_LIMIT");
                    check((System.nanoTime()-start)/1000000<8000,"DEX_TIME_LIMIT");
                    byte[] bytes=new byte[(int)e.getSize()];
                    try(InputStream in=zip.getInputStream(e)) {
                        int p=0,n; while(p<bytes.length && (n=in.read(bytes,p,bytes.length-p))>0) p+=n;
                        check(p==bytes.length,"DEX_TRUNCATED "+e.getName());
                    }
                    // A byte search is only a prefilter. Only const-string instructions
                    // in the same real method establish the two semantic anchors.
                    String needle=wechat?"inTabletEnv":"isAndroidPad";
                    boolean anchored=contains(bytes,needle),hinted=hint!=null&&contains(bytes,hint);
                    if(!anchored&&!hinted)continue;
                    Dex dex=new Dex(bytes);
                    if(hinted)dex.hintedCalls(hint,hintedCalls);
                    if(!anchored)continue;
                    List<Target> candidates=wechat?dex.tabletImplementations():dex.weworkLoginTargets();
                    for(Target candidate : candidates) {
                        reporter.event(e.getName()+" candidate="+candidate.key());
                        if(!has(plan.targets,candidate)) plan.targets.add(candidate);
                    }
                    if(wechat && !candidates.isEmpty()) {
                        for(Target impl:candidates) {
                            List<Target> wrappers=dex.wrappers(impl);
                            check(wrappers.size()==1,"WRAPPER_AMBIGUOUS count="+wrappers.size()+" "+impl.key());
                            for(Target wrapper:wrappers) if(!has(plan.targets,wrapper)) plan.targets.add(wrapper);
                        }
                    }
                }
            }
        }
        reporter.event("DISCOVERY targets="+plan.targets.size()+" dex_files="+files+" scanned_bytes="+total);
        int expected=wechat?2:1;
        check(plan.targets.size()==expected,"TARGET_MISSING_OR_AMBIGUOUS count="+plan.targets.size());
        boolean hintComplete=hint!=null;
        for(Target target:plan.targets)if(!target.owner.equals(hint))hintComplete=false;
        if(hintComplete) {
            for(Target target:plan.targets) {
                List<Target> found=hintedCalls.get(target.key());
                if(found!=null)for(Target caller:found)if(!has(plan.targets,caller)&&!has(plan.callers,caller))plan.callers.add(caller);
            }
            check(plan.callers.size()<=512,"CALLER_LIMIT");
            reporter.event("CALLERS_ONE_PASS validated_owner="+hint+" callers="+plan.callers.size());
        }
        // A second pass finds direct callers across DEX boundaries. Deoptimizing
        // these exact methods defeats AOT inlining even if login classes rename.
        if(!hintComplete)for(String apk:apks) {
            try(ZipFile zip=new ZipFile(apk)) {
                Enumeration<? extends ZipEntry> entries=zip.entries();
                while(entries.hasMoreElements()) {
                    ZipEntry e=entries.nextElement();
                    if(!e.getName().matches("classes(?:[2-9][0-9]*|1[0-9]+)?\\.dex"))continue;
                    check((System.nanoTime()-start)/1000000<8000,"DEX_TIME_LIMIT_CALLERS");
                    byte[] bytes=new byte[(int)e.getSize()];
                    try(DataInputStream in=new DataInputStream(zip.getInputStream(e))) { in.readFully(bytes); }
                    boolean relevant=false;
                    for(Target t:plan.targets) if(contains(bytes,t.owner)) relevant=true;
                    if(!relevant)continue;
                    for(Target t:new Dex(bytes).callers(plan.targets)) {
                        if(!has(plan.callers,t)) plan.callers.add(t);
                        check(plan.callers.size()<=512,"CALLER_LIMIT");
                    }
                }
            }
        }
        reporter.event("dex_files="+files+" scanned_bytes="+total+" elapsed_ms="+(System.nanoTime()-start)/1000000+
                " targets="+plan.targets.size()+" callers="+plan.callers.size());
        return plan;
    }
    /** The protocol enum is accepted only with its real getter's KV, enum and pad-call anchors. */
    public static Plan weworkProtocol(String[] apks,Reporter reporter) throws IOException {
        Plan plan=new Plan();plan.rule="DEX_PAD_PROTOCOL_ENUM";long start=System.nanoTime();int bytesRead=0,files=0;
        for(String apk:apks)try(ZipFile zip=new ZipFile(apk)) {
            Enumeration<? extends ZipEntry> entries=zip.entries();
            while(entries.hasMoreElements()) {
                ZipEntry entry=entries.nextElement();if(!entry.getName().matches("classes(?:[2-9][0-9]*|1[0-9]+)?\\.dex"))continue;
                check(++files<=64,"DEX_FILE_LIMIT");check(entry.getSize()>0&&entry.getSize()<=MAX_DEX,"DEX_SIZE_LIMIT");
                check((bytesRead+=entry.getSize())<=MAX_TOTAL,"DEX_TOTAL_LIMIT");
                check((System.nanoTime()-start)/1000000<8000,"DEX_TIME_LIMIT_PROTOCOL");
                byte[] bytes=new byte[(int)entry.getSize()];
                try(DataInputStream in=new DataInputStream(zip.getInputStream(entry))){in.readFully(bytes);}
                if(!contains(bytes,"KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE"))continue;
                for(Target target:new Dex(bytes).weworkProtocolTargets()) {
                    if(!has(plan.targets,target))plan.targets.add(target);
                    reporter.event(entry.getName()+" protocol="+target.key()+" forced_int="+target.forcedInt);
                }
            }
        }
        int integers=0;for(Target t:plan.targets)if(t.forcedInt!=null)integers++;
        reporter.event("PROTOCOL_DISCOVERY enum_targets="+integers+" targets="+plan.targets.size()+" elapsed_ms="+(System.nanoTime()-start)/1000000);
        check(integers==1&&plan.targets.size()==2,"PROTOCOL_MISSING_OR_AMBIGUOUS count="+integers);
        return plan;
    }
    private static boolean has(List<Target> list,Target t) {
        for(Target x:list)if(x.key().equals(t.key()))return true;return false;
    }
    private static boolean contains(byte[] bytes,String value) {
        byte[] pattern=value.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        outer:for(int i=0;i<=bytes.length-pattern.length;i++) {
            if(bytes[i]!=pattern[0])continue;
            for(int j=1;j<pattern.length;j++)if(bytes[i+j]!=pattern[j])continue outer;
            return true;
        }
        return false;
    }
    private static final class Encoded {
        int id,access,code; Target target;
    }
    private static final class Dex {
        final byte[] b;
        final int strings,stringsOff,types,typesOff,protos,protosOff,methods,methodsOff,classes,classesOff;
        final String[] stringCache,typeCache;
        Dex(byte[] bytes) throws IOException {
            b=bytes;check(b.length>=112,"DEX_HEADER_TRUNCATED");
            String magic=new String(b,0,8,java.nio.charset.StandardCharsets.US_ASCII);
            check(magic.matches("dex\\n0(?:35|37|38|39|40)\\x00"),"DEX_FORMAT_UNSUPPORTED");
            check(i(32)==b.length && i(36)==112 && i(40)==0x12345678,"DEX_HEADER_INVALID");
            strings=i(56);stringsOff=i(60);types=i(64);typesOff=i(68);
            protos=i(72);protosOff=i(76);methods=i(88);methodsOff=i(92);classes=i(96);classesOff=i(100);
            table(strings,stringsOff,4);table(types,typesOff,4);table(protos,protosOff,12);
            table(methods,methodsOff,8);table(classes,classesOff,32);
            check(strings<=1000000 && types<=65536 && methods<=65536,"DEX_INDEX_LIMIT");
            stringCache=new String[strings];typeCache=new String[types];
        }
        void range(long p,long n) throws IOException { check(p>=0 && n>=0 && p+n<=b.length,"DEX_BOUNDS"); }
        void table(int count,int off,int width) throws IOException {range(off,(long)count*width);}
        int u(int p) throws IOException {range(p,2);return (b[p]&255)|((b[p+1]&255)<<8);}
        int i(int p) throws IOException {range(p,4);int n=(b[p]&255)|((b[p+1]&255)<<8)|((b[p+2]&255)<<16)|((b[p+3]&255)<<24);check(n>=0,"DEX_UINT_TOO_LARGE");return n;}
        int leb(int[] p) throws IOException {
            int value=0; for(int s=0;s<35;s+=7) {range(p[0],1);int n=b[p[0]++]&255;
                check(s<28 || (n&240)==0,"DEX_ULEB_OVERFLOW");value|=(n&127)<<s;if((n&128)==0)return value;}
            throw new IOException("DEX_ULEB_INVALID");
        }
        String s(int id) throws IOException {
            check(id>=0 && id<strings,"DEX_STRING_INDEX");if(stringCache[id]!=null)return stringCache[id];
            int[] p={i(stringsOff+id*4)};leb(p);int start=p[0];
            while(p[0]<b.length && b[p[0]]!=0 && p[0]-start<=65536)p[0]++;
            check(p[0]<b.length && p[0]-start<=65536,"DEX_STRING_UNTERMINATED");
            return stringCache[id]=new String(b,start,p[0]-start,java.nio.charset.StandardCharsets.UTF_8);
        }
        String type(int id) throws IOException {
            check(id>=0 && id<types,"DEX_TYPE_INDEX");
            return typeCache[id]!=null?typeCache[id]:(typeCache[id]=s(i(typesOff+id*4)));
        }
        Target method(int id,boolean isStatic) throws IOException {
            check(id>=0 && id<methods,"DEX_METHOD_INDEX");int off=methodsOff+id*8,proto=u(off+2);
            check(proto<protos,"DEX_PROTO_INDEX");int po=protosOff+proto*12,params=i(po+8);
            int parameterCount=params==0?0:i(params);check(parameterCount<=255,"DEX_PARAMETER_LIMIT");
            String[] args=new String[parameterCount];
            for(int j=0;j<args.length;j++)args[j]=type(u(params+4+j*2));
            return new Target(type(u(off)),s(i(off+4)),type(i(po+4)),args,isStatic);
        }
        List<Encoded> definitions(String prefix) throws IOException { return definitions(prefix,true); }
        List<Encoded> definitions(String prefix,boolean resolveTargets) throws IOException {
            List<Encoded> result=new ArrayList<>();
            for(int k=0;k<classes;k++) {
                int off=classesOff+k*32;if(!type(i(off)).startsWith(prefix))continue;
                int data=i(off+24);if(data==0)continue;int[] p={data};
                int sf=leb(p),inf=leb(p),direct=leb(p),virtual=leb(p);
                check((long)sf+inf+direct+virtual<200000,"DEX_CLASS_DATA_LIMIT");
                for(int f=0;f<sf+inf;f++){leb(p);leb(p);}
                for(int count:new int[]{direct,virtual}) {
                    int id=0;for(int j=0;j<count;j++) {
                        id+=leb(p);Encoded e=new Encoded();e.id=id;e.access=leb(p);e.code=leb(p);
                        if(e.code!=0){if(resolveTargets)e.target=method(id,(e.access&8)!=0);result.add(e);}
                    }
                }
            }
            return result;
        }
        static final int[] WIDTHS=new int[256];
        static {
            Arrays.fill(WIDTHS,-1);
            set(0x00,0x12,1);WIDTHS[2]=WIDTHS[5]=WIDTHS[8]=2;WIDTHS[3]=WIDTHS[6]=WIDTHS[9]=3;
            set(0x13,0x19,2);WIDTHS[0x14]=WIDTHS[0x17]=3;WIDTHS[0x18]=5;
            set(0x1a,0x1c,2);WIDTHS[0x1b]=3;set(0x1d,0x1e,1);set(0x1f,0x20,2);
            WIDTHS[0x21]=1;set(0x22,0x23,2);set(0x24,0x26,3);set(0x27,0x28,1);
            WIDTHS[0x29]=2;set(0x2a,0x2c,3);set(0x2d,0x3d,2);set(0x44,0x6d,2);
            set(0x6e,0x72,3);set(0x74,0x78,3);set(0x7b,0x8f,1);set(0x90,0xaf,2);
            set(0xb0,0xcf,1);set(0xd0,0xe2,2);set(0xfa,0xfb,4);set(0xfc,0xfd,3);set(0xfe,0xff,2);
        }
        static void set(int first,int last,int width){for(int n=first;n<=last;n++)WIDTHS[n]=width;}
        interface Insn {void visit(int op,int index) throws IOException;}
        void instructions(Encoded method,Insn visitor) throws IOException {
            int count=i(method.code+12),start=method.code+16;range(start,(long)count*2);
            for(int pc=0;pc<count;) {
                int p=start+pc*2,unit=u(p),op=unit&255,width=WIDTHS[op];
                if(op==0 && unit!=0) {
                    if(unit==0x100)width=4+u(p+2)*2;
                    else if(unit==0x200)width=2+u(p+2)*4;
                    else if(unit==0x300){long n=4+((long)u(p+2)*i(p+4)+1)/2;check(n<=Integer.MAX_VALUE,"DEX_PAYLOAD_LIMIT");width=(int)n;}
                    else throw new IOException("DEX_PAYLOAD_INVALID");
                }
                check(width>0 && (long)pc+width<=count,"DEX_OPCODE_INVALID op="+op);
                if(op==0x12)visitor.visit(op,(short)unit>>12);
                else if(op==0x13)visitor.visit(op,(short)u(p+2));
                else if(op==0x14)visitor.visit(op,(b[p+2]&255)|((b[p+3]&255)<<8)|((b[p+4]&255)<<16)|((b[p+5]&255)<<24));
                else if(op==0x15)visitor.visit(op,u(p+2)<<16);
                else if(op==0x1a)visitor.visit(op,u(p+2));
                else if(op==0x1b)visitor.visit(op,i(p+2));
                else if((op>=0x6e && op<=0x72)||(op>=0x74 && op<=0x78))visitor.visit(op,u(p+2));
                pc+=width;
            }
        }
        List<Target> tabletImplementations() throws IOException {
            final Set<Integer> positive=new HashSet<>(),negative=new HashSet<>();
            for(int id=0;id<strings;id++) {
                String value=s(id);
                if(value.contains("inTabletEnv") && value.contains("return true"))positive.add(id);
                if(value.contains("inTabletEnv") && value.contains("return false"))negative.add(id);
            }
            List<Target> found=new ArrayList<>();if(positive.isEmpty()||negative.isEmpty())return found;
            for(Encoded e:definitions("Lcom/tencent/mm/")) {
                if(!e.target.isStatic || !"Z".equals(e.target.returns) || e.target.parameters.length>4)continue;
                final boolean[] flags={false,false};
                instructions(e,(op,id)->{if(op==0x1a||op==0x1b){flags[0]|=positive.contains(id);flags[1]|=negative.contains(id);}});
                if(flags[0]&&flags[1])found.add(e.target);
            }
            return found;
        }
        List<Target> wrappers(Target impl) throws IOException {
            List<Target> result=new ArrayList<>();
            for(Encoded e:definitions(impl.owner.substring(0,impl.owner.length()-1))) {
                if(!e.target.owner.equals(impl.owner)||!e.target.isStatic||!"Z".equals(e.target.returns)||e.target.parameters.length!=0)continue;
                final boolean[] calls={false};
                instructions(e,(op,id)->{if((op==0x71||op==0x77)&&method(id,true).key().equals(impl.key()))calls[0]=true;});
                if(calls[0])result.add(e.target);
            }
            return result;
        }
        List<Target> weworkLoginTargets() throws IOException {
            List<Target> result=new ArrayList<>();
            for(Encoded e:definitions("Lcom/tencent/wework/")) {
                if(!e.target.owner.endsWith("/LoginWxAuthActivity;"))continue;
                final boolean[] visibility={false};final List<Target> candidates=new ArrayList<>();
                instructions(e,(op,id)->{
                    if(op<0x6e||op>0x78)return;
                    Target t=method(id,op==0x71||op==0x77);
                    if(t.name.equals("setVisibility") && t.owner.startsWith("Landroid/"))visibility[0]=true;
                    if(t.isStatic && t.parameters.length==0 && t.returns.equals("Z") && t.name.equals("isAndroidPad")
                            && t.owner.startsWith("Lcom/tencent/wework/"))candidates.add(t);
                });
                if(visibility[0])for(Target t:candidates)if(!has(result,t))result.add(t);
            }
            return result;
        }
        List<Target> weworkProtocolTargets() throws IOException {
            List<Target> result=new ArrayList<>();
            for(Encoded e:definitions("Lcom/tencent/wework/")) {
                if(!e.target.name.equals("getDeviceType")||!e.target.returns.equals("I")||e.target.parameters.length!=0)continue;
                final boolean[] flags={false,false,false};final List<Target> pads=new ArrayList<>();
                instructions(e,(op,value)->{
                    if(op==0x1a||op==0x1b)flags[0]|=s(value).equals("KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE");
                    if(op>=0x12&&op<=0x15){flags[1]|=value==131076;flags[2]|=value==131073;}
                    if((op>=0x6e&&op<=0x72)||(op>=0x74&&op<=0x78)) {
                        Target t=method(value,op==0x71||op==0x77);
                        if(t.name.equals("isAndroidPad")&&t.returns.equals("Z")&&t.parameters.length==0
                                &&t.owner.equals(e.target.owner)&&!has(pads,t))pads.add(t);
                    }
                });
                if(flags[0]&&flags[1]&&flags[2]&&pads.size()==1) {
                    e.target.forcedInt=131076;result.add(e.target);result.add(pads.get(0));
                }
            }
            return result;
        }
        void hintedCalls(String owner,Map<String,List<Target>> relations) throws IOException {
            final Map<Integer,Target> ids=new HashMap<>();
            for(int id=0;id<methods;id++)if(owner.equals(type(u(methodsOff+id*8)))) {
                Target t=method(id,true);if(t.returns.equals("Z")&&t.parameters.length<=4)ids.put(id,t);
            }
            if(ids.isEmpty())return;
            for(Encoded e:definitions("Lcom/tencent/mm/",false)) {
                final Set<Integer> found=new HashSet<>();
                instructions(e,(op,id)->{if((op==0x71||op==0x77)&&ids.containsKey(id))found.add(id);});
                if(found.isEmpty())continue;Target caller=method(e.id,(e.access&8)!=0);
                for(Integer id:found) {
                    List<Target> list=relations.get(ids.get(id).key());
                    if(list==null){list=new ArrayList<>();relations.put(ids.get(id).key(),list);}
                    if(!has(list,caller))list.add(caller);
                    check(list.size()<=512,"CALLER_LIMIT_HINT");
                }
            }
        }
        List<Target> callers(List<Target> targets) throws IOException {
            final Set<Integer> ids=new HashSet<>();
            for(int id=0;id<methods;id++) {
                String owner=type(u(methodsOff+id*8));boolean relevant=false;
                for(Target target:targets)if(target.owner.equals(owner))relevant=true;
                if(relevant && has(targets,method(id,true)))ids.add(id);
            }
            List<Target> result=new ArrayList<>();if(ids.isEmpty())return result;
            String prefix=targets.get(0).owner.startsWith("Lcom/tencent/mm/")?"Lcom/tencent/mm/":"Lcom/tencent/wework/";
            for(Encoded e:definitions(prefix,false)) {
                final boolean[] found={false};
                instructions(e,(op,id)->{if((op>=0x6e&&op<=0x72)||(op>=0x74&&op<=0x78))found[0]|=ids.contains(id);});
                if(found[0]){Target caller=method(e.id,(e.access&8)!=0);if(!has(targets,caller))result.add(caller);}
            }
            return result;
        }
    }
}
