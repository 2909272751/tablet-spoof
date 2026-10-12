package io.github.tabletspoof.nativebridge;

import android.app.Instrumentation;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.os.SystemClock;
import java.io.*;
import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.*;

/** Version numbers are diagnostic metadata, never an allowlist. */
public final class Bridge {
    private static final String MODULE_VERSION="3.1.0";
    private static native Method hook(Method target,Object owner,Method callback);
    private static native boolean unhook(Method target);
    private static native boolean deoptimize(Method target);
    private static String pkg,version="unknown",versionCode="unknown",detail="BOOTSTRAP",rule="none";
    private static File statusFile,logFile,cacheFile;
    private static boolean done;
    private static ClassLoader activeLoader;
    private static int installed,deoptimized;
    private static long started;
    private static final AtomicInteger hits=new AtomicInteger();
    private static final List<TrueHook> hooks=new ArrayList<>();

    public static void bootstrap(String packageName,String dir) throws Exception {
        pkg=packageName;started=SystemClock.elapsedRealtime();
        File files=new File(dir,"files"),folder=new File(files,"tablet-spoof");folder.mkdirs();
        statusFile=new File(files,"tablet-spoof-native-status.txt");
        logFile=new File(folder,"diagnostic.log");cacheFile=new File(folder,"resolver-cache.json");
        event("BOOTSTRAP module="+MODULE_VERSION+" package="+pkg+" pid="+android.os.Process.myPid()+
                " sdk="+Build.VERSION.SDK_INT+" android="+Build.VERSION.RELEASE);
        writeStatus();
        // Apps can replace their ClassLoader in attachBaseContext (including DelegateLast/Tinker).
        // Wait until attachment finishes, but hook before app initialization reports device type.
        Method method=Instrumentation.class.getDeclaredMethod("callApplicationOnCreate",android.app.Application.class);
        LifecycleHook owner=new LifecycleHook();
        owner.backup=hook(method,owner,LifecycleHook.class.getDeclaredMethod("callback",Object[].class));
        if(owner.backup==null){detail="FAILED_BOOTSTRAP";event(detail);writeStatus();throw new IllegalStateException(detail);}
        event("BOOTSTRAP_HOOK deopt="+deoptimize(method));
    }
    private static String loaderId(ClassLoader loader) {
        return loader==null?"bootstrap":loader.getClass().getName()+"@"+Integer.toHexString(System.identityHashCode(loader));
    }
    private static void loaderState(Context app,String stage) {
        try {
            ClassLoader loader=app.getClassLoader();event("LIFECYCLE "+stage+" loader="+loaderId(loader));
            for(TrueHook h:hooks) {
                Class<?> actual=Class.forName(h.target.getDeclaringClass().getName(),false,loader);
                event("TARGET_LOADER method="+h.target.getName()+" installed="+loaderId(h.target.getDeclaringClass().getClassLoader())+
                        " actual="+loaderId(actual.getClassLoader())+" same_class="+(actual==h.target.getDeclaringClass()));
            }
        }catch(Throwable e){error("LOADER_DIAGNOSTIC",e);}
    }
    public static final class LifecycleHook {
        private Method backup;
        public Object callback(Object[] args) throws Throwable {
            Context app=(Context)args[1];ClassLoader before=app.getClassLoader();loaderState(app,"BEFORE_ONCREATE");
            try{install(before,app);}
            catch(Throwable e){detail="FAILED_INSTALL";error(detail,e);rollback();writeStatus();}
            try{return backup.invoke(args[0],args[1]);}
            catch(InvocationTargetException e){throw e.getCause();}
            finally {
                if(app.getClassLoader()!=before) {
                    try{install(app.getClassLoader(),app);}
                    catch(Throwable e){detail="FAILED_LOADER_REBIND";error(detail,e);rollback();writeStatus();}
                }
                loaderState(app,"AFTER_ONCREATE");
            }
        }
    }
    public static final class TrueHook {
        private Method target,backup;
        private volatile boolean enabled;
        private Integer forcedInt;
        private final AtomicInteger calls=new AtomicInteger();
        public Object callback(Object[] args) throws Throwable {
            if(!enabled) {
                try{return backup.invoke(Modifier.isStatic(target.getModifiers())?null:args[0],
                        Modifier.isStatic(target.getModifiers())?args:Arrays.copyOfRange(args,1,args.length));}
                catch(InvocationTargetException e){throw e.getCause();}
            }
            int count=calls.incrementAndGet(),total=hits.incrementAndGet();
            if(count==1||count==10||count==100)event("HOOK_HIT method="+target.toGenericString()+" count="+count);
            if(total<=3||total==10||total==100)writeStatus();
            return forcedInt==null?Boolean.TRUE:forcedInt;
        }
    }
    private static synchronized void install(ClassLoader loader,Context context) throws Exception {
        if(done&&loader==activeLoader)return;detail="RESOLVING";
        event("INSTALL_LOADER "+loaderId(loader));
        PackageInfo info=context.getPackageManager().getPackageInfo(pkg,0);
        version=String.valueOf(info.versionName);
        versionCode=String.valueOf(Build.VERSION.SDK_INT>=28?info.getLongVersionCode():info.versionCode);
        event("APPLICATION version="+version+" code="+versionCode);writeStatus();
        boolean wechat="com.tencent.mm".equals(pkg);
        if(!wechat&&!"com.tencent.wework".equals(pkg))throw new SecurityException("Package outside scope");
        List<String> paths=new ArrayList<>();paths.add(info.applicationInfo.sourceDir);
        if(info.applicationInfo.splitSourceDirs!=null)Collections.addAll(paths,info.applicationInfo.splitSourceDirs);
        String fingerprint=fingerprint(paths,info.lastUpdateTime);
        DexResolver.Plan plan=readCache(fingerprint);List<Method> targets=null;
        if(plan!=null) {
            try{targets=validate(loader,plan);event("CACHE_HIT rule="+plan.rule);}
            catch(Throwable e){error("CACHE_INVALID",e);plan=null;cacheFile.delete();}
        }
        if(plan==null) {
            if(!wechat)plan=namedWeWork(loader);
            if(plan==null)plan=DexResolver.resolve(paths.toArray(new String[0]),wechat,Bridge::event);
            if(!wechat) {
                DexResolver.Plan protocol=DexResolver.weworkProtocol(paths.toArray(new String[0]),Bridge::event);
                for(DexResolver.Target target:protocol.targets) {
                    boolean duplicate=false;for(DexResolver.Target t:plan.targets)if(t.key().equals(target.key()))duplicate=true;
                    if(!duplicate)plan.targets.add(target);
                }
                try {
                    Method getter=Class.forName("com.tencent.wework.foundation.logic.Application",false,loader).getDeclaredMethod("getDeviceType");
                    if(getter.getReturnType()!=int.class||!Modifier.isStatic(getter.getModifiers()))throw new NoSuchMethodException("Protocol getter signature changed");
                    DexResolver.Target target=new DexResolver.Target("Lcom/tencent/wework/foundation/logic/Application;","getDeviceType","I",new String[0],true);
                    target.forcedInt=131076;plan.targets.add(target);
                }catch(Throwable e){error("PROTOCOL_WRAPPER_UNAVAILABLE",e);}
                plan.rule+="+"+protocol.rule;
            }
            rule=plan.rule;targets=validate(loader,plan);saveCache(fingerprint,plan);
            event("RESOLVED rule="+rule+" targets="+targets.size()+" callers="+plan.callers.size());
        }
        if(done) {
            boolean sameTargets=true;
            for(Method m:targets){boolean found=false;for(TrueHook h:hooks)if(h.target.equals(m))found=true;sameTargets&=found;}
            if(sameTargets){activeLoader=loader;detail="READY";event("LOADER_REUSED_TARGETS");writeStatus();return;}
            event("LOADER_REBIND from="+loaderId(activeLoader)+" to="+loaderId(loader));
            rollback();
            for(Observer observer:observers)try{unhook(observer.target);}catch(Throwable e){error("OBSERVER_ROLLBACK",e);}
            observers.clear();deoptimized=0;
        }
        activeLoader=loader;
        rule=plan.rule;detail="INSTALLING";writeStatus();
        // Validate the entire plan before mutation; callbacks preserve originals
        // until all targets are installed. A partial installation rolls back.
        for(int targetIndex=0;targetIndex<targets.size();targetIndex++) {
            Method target=targets.get(targetIndex);
            TrueHook owner=new TrueHook();owner.target=target;owner.forcedInt=plan.targets.get(targetIndex).forcedInt;
            owner.backup=hook(target,owner,TrueHook.class.getDeclaredMethod("callback",Object[].class));
            if(owner.backup==null)throw new IllegalStateException("HOOK_RETURNED_NULL "+target.toGenericString());
            hooks.add(owner);installed++;event("HOOK_INSTALLED "+target.toGenericString());
            if(!deoptimize(target))event("TARGET_DEOPT_FAILED "+target.toGenericString());
        }
        int initializers=0;
        for(DexResolver.Target caller:plan.callers) {
            if(caller.name.startsWith("<")){initializers++;continue;}
            try{deopt(resolve(loader,caller));}catch(Throwable e){error("CALLER_DEOPT "+caller.key(),e);}
        }
        if(initializers>0)event("CALLER_INITIALIZERS_SKIPPED count="+initializers);
        String[] callers=wechat?new String[]{"com.tencent.mm.plugin.account.ui.LoginUI",
                "com.tencent.mm.plugin.account.ui.LoginHistoryUI","com.tencent.mm.plugin.account.ui.MobileInputUI",
                "com.tencent.mm.plugin.login_exdevice.ui.LoginAsExDeviceUI"}:
                new String[]{"com.tencent.wework.login.controller.LoginWxAuthActivity",
                    "com.tencent.wework.login.controller.LoginQrCodeForAndroidPad"};
        for(String caller:callers) {
            try{for(Method m:Class.forName(caller,false,loader).getDeclaredMethods())deopt(m);}
            catch(Throwable e){error("LOGIN_CLASS "+caller,e);}
        }
        if(deoptimized==0)event("WARNING_NO_CALLERS_DEOPTIMIZED");
        for(TrueHook owner:hooks)owner.enabled=true;
        if(!wechat)installWeWorkDiagnostics(loader);
        done=true;detail="READY";event("READY hooks="+installed+" deoptimized="+deoptimized+
                " elapsed_ms="+(SystemClock.elapsedRealtime()-started));writeStatus();
    }
    // Observers never change callbacks, error codes, tokens or server login results.
    private static final List<Observer> observers=new ArrayList<>();
    private static int pollCount,lastPollCode=Integer.MIN_VALUE,lastPollStatus=Integer.MIN_VALUE;
    private static long lastProgress;
    private static Method parsePoll;
    private static Field pollStatus;
    private static void installWeWorkDiagnostics(ClassLoader loader) {
        try {
            Class<?> service=Class.forName("com.tencent.wework.foundation.logic.GrandProfileService",false,loader);
            Class<?> qrData=Class.forName("com.tencent.wework.foundation.model.pb.WwQrcodeLogin$CheckQrcodeData",false,loader);
            parsePoll=qrData.getDeclaredMethod("parseFrom",byte[].class);pollStatus=qrData.getField("status");
            if(pollStatus.getType()!=int.class)throw new NoSuchFieldException("Poll status type changed");
            Class<?> common=Class.forName("com.tencent.wework.foundation.callback.ICommonCallback",false,loader);
            Class<?> pb=Class.forName("com.tencent.wework.foundation.callback.ICommonPbDataCallback",false,loader);
            observe(service.getDeclaredMethod("getLoginQrCodeForPad",int.class,long.class,long.class,common),"QR_REQUEST",3);
            observe(service.getDeclaredMethod("CheckQrCodeLoginForPad",pb),"QR_POLL",0);
            Class<?> activity=Class.forName("com.tencent.wework.login.controller.LoginQrCodeForAndroidPad",false,loader);
            // Signature-based discovery tolerates obfuscated callback method names.
            for(Method m:activity.getDeclaredMethods()) {
                Class<?>[] p=m.getParameterTypes();
                if(!Modifier.isStatic(m.getModifiers())&&m.getReturnType()==void.class&&p.length==3
                        &&p[0]==int.class&&p[1]==String.class&&p[2]==qrData)observe(m,"QR_UI_STATUS",-1);
                if(Modifier.isStatic(m.getModifiers())&&m.getReturnType()==void.class&&p.length==5&&p[0]==activity
                        &&p[1]==int.class&&p[2]==int.class&&p[3]==int.class&&p[4]==String.class)observe(m,"ENTERPRISE_LOGIN_RESULT",-1);
            }
            event("FLOW_DIAGNOSTICS_READY observers="+observers.size());
        }catch(Throwable e){error("FLOW_DIAGNOSTICS_UNAVAILABLE",e);}
    }
    private static void observe(Method m,String stage,int callbackIndex) throws Exception {
        Observer owner=new Observer();owner.stage=stage;owner.callbackIndex=callbackIndex;owner.target=m;
        m.setAccessible(true);owner.backup=hook(m,owner,Observer.class.getDeclaredMethod("callback",Object[].class));
        if(owner.backup==null)throw new IllegalStateException("OBSERVER_HOOK_FAILED "+m.toGenericString());
        observers.add(owner);deopt(m);event("FLOW_OBSERVER "+stage+" "+m.toGenericString());
    }
    private static synchronized void poll(int code,Object data) {
        int status=-1;
        try {if(data!=null){Object parsed=data instanceof byte[]?parsePoll.invoke(null,data):data;status=pollStatus.getInt(parsed);}}
        catch(Throwable ignored){event("FLOW_PARSE_UNAVAILABLE");}
        pollCount++;boolean changed=code!=lastPollCode||status!=lastPollStatus;
        if(changed){lastPollCode=code;lastPollStatus=status;lastProgress=SystemClock.elapsedRealtime();}
        if(changed||pollCount<=3||pollCount==10||pollCount==100)
            event("FLOW QR_POLL code="+code+" status="+status+" polls="+pollCount);
        if(!changed&&SystemClock.elapsedRealtime()-lastProgress>30000) {
            event("FLOW WAIT_TIMEOUT code="+code+" status="+status+" wait_ms="+(SystemClock.elapsedRealtime()-lastProgress));
            lastProgress=SystemClock.elapsedRealtime();
        }
    }
    public static final class Observer {
        private Method target,backup;private String stage;private int callbackIndex;
        public Object callback(Object[] args) throws Throwable {
            try {
                int offset=Modifier.isStatic(target.getModifiers())?0:1;
                if(callbackIndex>=0&&callbackIndex+offset<args.length) {
                    if(stage.equals("QR_REQUEST")) {
                        synchronized(Bridge.class){pollCount=0;lastPollCode=Integer.MIN_VALUE;lastPollStatus=Integer.MIN_VALUE;lastProgress=SystemClock.elapsedRealtime();}
                        event("FLOW QR_REQUEST");
                    }
                    final Object original=args[callbackIndex+offset];
                    final String callbackStage=stage;
                    Class<?> iface=target.getParameterTypes()[callbackIndex];
                    if(original!=null&&iface.isInterface())args[callbackIndex+offset]=Proxy.newProxyInstance(iface.getClassLoader(),new Class<?>[]{iface},(proxy,method,values)->{
                        try {
                            if(values!=null&&values.length>0&&values[0] instanceof Integer) {
                                int code=(Integer)values[0];
                                if(callbackStage.equals("QR_POLL"))poll(code,values.length>2?values[2]:null);
                                else event("FLOW QR_RESPONSE code="+code);
                            }
                        }catch(Throwable ignored){event("FLOW_OBSERVER_ERROR");}
                        try{return method.invoke(original,values);}catch(InvocationTargetException e){throw e.getCause();}
                    });
                } else if(stage.equals("ENTERPRISE_LOGIN_RESULT")) {
                    event("FLOW ENTERPRISE_LOGIN_RESULT code="+args[offset+1]);
                } else if(stage.equals("QR_UI_STATUS")) {
                    poll((Integer)args[offset],args[offset+2]);
                }
            }catch(Throwable ignored){event("FLOW_OBSERVER_ERROR");}
            try {return backup.invoke(Modifier.isStatic(target.getModifiers())?null:args[0],
                    Modifier.isStatic(target.getModifiers())?args:Arrays.copyOfRange(args,1,args.length));}
            catch(InvocationTargetException e){throw e.getCause();}
        }
    }
    private static DexResolver.Plan namedWeWork(ClassLoader loader) {
        String[] names={"com.tencent.wework.foundation.logic.Application","com.tencent.wework.foundation.impl.WeworkServiceImpl"};
        for(int index=0;index<names.length;index++) {
            try {
                Method m=Class.forName(names[index],false,loader).getDeclaredMethod("isAndroidPad");
                if(m.getReturnType()!=boolean.class||Modifier.isStatic(m.getModifiers())!=(index==0))
                    throw new NoSuchMethodException("Invalid named pad signature");
                DexResolver.Plan p=new DexResolver.Plan();p.rule="NAMED_PAD_BOOLEAN_"+(index==0?"PRIMARY":"FALLBACK");
                p.targets.add(new DexResolver.Target("L"+names[index].replace('.','/')+";","isAndroidPad","Z",new String[0],index==0));
                return p;
            }catch(Throwable e){error("NAMED_LOOKUP "+names[index],e);}
        }
        return null;
    }
    private static List<Method> validate(ClassLoader loader,DexResolver.Plan plan) throws Exception {
        boolean wechat="com.tencent.mm".equals(pkg);
        if(wechat?plan.targets.size()!=2:(plan.targets.size()<2||plan.targets.size()>4))throw new IllegalStateException("INVALID_PLAN_COUNT");
        List<Method> targets=new ArrayList<>();
        for(DexResolver.Target target:plan.targets) {
            String prefix="com.tencent.mm".equals(pkg)?"Lcom/tencent/mm/":"Lcom/tencent/wework/";
            boolean integer=target.forcedInt!=null;
            if(!target.owner.startsWith(prefix)||!target.returns.equals(integer?"I":"Z")
                    ||(integer&&(wechat||target.forcedInt!=131076||target.parameters.length!=0)))throw new SecurityException("Target outside semantic scope");
            Method m=resolve(loader,target);if(m.getReturnType()!=(integer?int.class:boolean.class))throw new NoSuchMethodException("Target return changed");
            targets.add(m);
        }
        return targets;
    }
    private static Method resolve(ClassLoader loader,DexResolver.Target t) throws Exception {
        Class<?>[] args=new Class<?>[t.parameters.length];for(int i=0;i<args.length;i++)args[i]=type(loader,t.parameters[i]);
        Method m=type(loader,t.owner).getDeclaredMethod(t.name,args);
        if(Modifier.isStatic(m.getModifiers())!=t.isStatic)throw new NoSuchMethodException("Static signature changed "+t.key());
        m.setAccessible(true);return m;
    }
    private static Class<?> type(ClassLoader loader,String descriptor) throws ClassNotFoundException {
        switch(descriptor) {
            case "Z":return boolean.class;case "B":return byte.class;case "C":return char.class;
            case "S":return short.class;case "I":return int.class;case "J":return long.class;
            case "F":return float.class;case "D":return double.class;case "V":return void.class;
            default:String name=descriptor.startsWith("L")?descriptor.substring(1,descriptor.length()-1):descriptor;
                return Class.forName(name.replace('/','.'),false,loader);
        }
    }
    private static void deopt(Method m) {
        int mod=m.getModifiers();if(Modifier.isAbstract(mod)||Modifier.isNative(mod))return;
        if(deoptimize(m))deoptimized++;else event("CALLER_DEOPT_FAILED "+m.toGenericString());
    }
    private static void rollback() {
        for(TrueHook h:hooks) {
            h.enabled=false;
            try{event("ROLLBACK "+h.target.toGenericString()+" restored="+unhook(h.target));}
            catch(Throwable e){error("ROLLBACK_FAILED",e);}
        }
        hooks.clear();installed=0;done=false;hits.set(0);
    }
    private static String fingerprint(List<String> paths,long update) {
        StringBuilder key=new StringBuilder("resolver-3|").append(versionCode).append('|').append(update);
        for(String path:paths){File f=new File(path);key.append('|').append(path).append('|').append(f.length()).append('|').append(f.lastModified());}
        return key.toString();
    }
    private static JSONArray encode(List<DexResolver.Target> targets) throws JSONException {
        JSONArray result=new JSONArray();for(DexResolver.Target t:targets) {
            JSONObject o=new JSONObject();o.put("owner",t.owner);o.put("name",t.name);o.put("returns",t.returns);
            if(t.forcedInt!=null)o.put("forcedInt",t.forcedInt);
            o.put("parameters",new JSONArray(Arrays.asList(t.parameters)));o.put("static",t.isStatic);result.put(o);
        }return result;
    }
    private static void decode(JSONArray array,List<DexResolver.Target> targets) throws JSONException {
        if(array.length()>512)throw new JSONException("CACHE_LIMIT");
        for(int i=0;i<array.length();i++) {
            JSONObject o=array.getJSONObject(i);JSONArray a=o.getJSONArray("parameters");
            if(a.length()>255)throw new JSONException("CACHE_PARAMETERS");String[] args=new String[a.length()];
            for(int j=0;j<args.length;j++)args[j]=a.getString(j);
            DexResolver.Target t=new DexResolver.Target(o.getString("owner"),o.getString("name"),o.getString("returns"),args,o.getBoolean("static"));
            if(o.has("forcedInt"))t.forcedInt=o.getInt("forcedInt");targets.add(t);
        }
    }
    private static DexResolver.Plan readCache(String fingerprint) {
        if(!cacheFile.isFile())return null;
        try {
            if(cacheFile.length()>128*1024)throw new IOException("CACHE_SIZE");
            byte[] bytes=new byte[(int)cacheFile.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(cacheFile))){in.readFully(bytes);}
            JSONObject o=new JSONObject(new String(bytes,StandardCharsets.UTF_8));
            if(!fingerprint.equals(o.getString("fingerprint"))){event("CACHE_APK_CHANGED");return null;}
            DexResolver.Plan plan=new DexResolver.Plan();plan.rule=o.getString("rule");
            decode(o.getJSONArray("targets"),plan.targets);decode(o.getJSONArray("callers"),plan.callers);return plan;
        }catch(Throwable e){error("CACHE_READ",e);return null;}
    }
    private static void saveCache(String fingerprint,DexResolver.Plan plan) {
        try {
            JSONObject o=new JSONObject();o.put("fingerprint",fingerprint);o.put("rule",plan.rule);
            o.put("targets",encode(plan.targets));o.put("callers",encode(plan.callers));atomic(cacheFile,o.toString());
        }catch(Throwable e){error("CACHE_WRITE",e);}
    }
    private static synchronized void event(String text) {
        if(logFile==null)return;
        try {
            if(logFile.length()>256*1024){File previous=new File(logFile.getParentFile(),"diagnostic.previous.log");previous.delete();logFile.renameTo(previous);}
            String line=System.currentTimeMillis()+" pid="+android.os.Process.myPid()+" "+text.replace('\n',' ').replace('\r',' ')+"\n";
            try(FileOutputStream out=new FileOutputStream(logFile,true)){out.write(line.getBytes(StandardCharsets.UTF_8));}
        }catch(Throwable ignored){}
    }
    private static void error(String stage,Throwable error) {
        for(int depth=0;error!=null&&depth<4;depth++,error=error.getCause()) {
            String message=String.valueOf(error.getMessage());if(message.length()>512)message=message.substring(0,512);
            event(stage+" error="+error.getClass().getName()+" message="+message);
            StackTraceElement[] stack=error.getStackTrace();for(int i=0;i<Math.min(12,stack.length);i++)event("at "+stack[i]);
        }
    }
    private static void atomic(File file,String text) throws IOException {
        File temporary=new File(file.getParentFile(),file.getName()+".tmp");
        try(FileOutputStream out=new FileOutputStream(temporary)){out.write(text.getBytes(StandardCharsets.UTF_8));}
        if(!temporary.renameTo(file))throw new IOException("DIAGNOSTIC_RENAME_FAILED");
    }
    private static synchronized void writeStatus() {
        if(statusFile==null)return;StringBuilder text=new StringBuilder();
        text.append("package=").append(pkg).append("\npid=").append(android.os.Process.myPid())
            .append("\nmodule_version=").append(MODULE_VERSION).append("\napp_version=").append(version)
            .append("\napp_version_code=").append(versionCode).append("\nsdk=").append(Build.VERSION.SDK_INT)
            .append("\nengine=zygisk-lsplant\nrule=").append(rule).append("\nhooks=").append(installed)
            .append("\nhits=").append(hits.get()).append("\ndeoptimized=").append(deoptimized)
            .append("\nelapsed_ms=").append(SystemClock.elapsedRealtime()-started).append("\ndetail=").append(detail).append('\n');
        for(TrueHook h:hooks)text.append("method=").append(h.target.toGenericString()).append(" loader=").append(loaderId(h.target.getDeclaringClass().getClassLoader())).append(" calls=").append(h.calls.get()).append('\n');
        try{atomic(statusFile,text.toString());}catch(Throwable ignored){}
    }
}
