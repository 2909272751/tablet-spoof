package io.github.tabletspoof.nativebridge;
public final class ResolverHarness {
    public static void main(String[] args) throws Exception {
        long start=System.nanoTime();
        DexResolver.Plan p=(args[0].equals("protocol")?DexResolver.weworkProtocol(new String[]{args[1]},System.out::println):DexResolver.resolve(new String[]{args[1]},args[0].equals("wechat"),System.out::println));
        System.out.println("PLAN "+p.rule);
        for(DexResolver.Target t:p.targets)System.out.println("TARGET "+t.key());
        System.out.println("CALLERS "+p.callers.size()+" TIME_MS "+(System.nanoTime()-start)/1000000);
    }
}
