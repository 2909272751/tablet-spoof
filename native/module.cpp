#include "zygisk.hpp"
#include "elf_symbols.hpp"
#include "third_party/lsplant/include/lsplant.hpp"
#include "third_party/dobby.h"
#include <android/log.h>
#include <cstdio>
#include <vector>

namespace {
void log(const char *message) { __android_log_print(ANDROID_LOG_INFO, "tablet-spoof-native", "%s", message); }
jobject doHook(JNIEnv *env, jclass, jobject target, jobject owner, jobject callback) {
    return lsplant::Hook(env, target, owner, callback);
}
jboolean deopt(JNIEnv *env, jclass, jobject target) { return lsplant::Deoptimize(env, target); }
jboolean undoHook(JNIEnv *env, jclass, jobject target) { return lsplant::UnHook(env, target); }
}

class TabletSpoofNative : public zygisk::ModuleBase {
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool target_ = false;
    bool selected_ = false;
    const char *preFailure_ = nullptr;
    char package_[64]{};
    char dataDir_[512]{};
    std::vector<unsigned char> dex_;
    void failure(const char *message) {
        log(message);
        char path[600];
        snprintf(path, sizeof(path), "%s/tablet-spoof-native-engine.txt", dataDir_);
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "pid=%d\nmodule_version=3.1.0\n%s\n", getpid(), message); fclose(f); }
    }
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override { api_ = api; env_ = env; }
    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        const char *name = env_->GetStringUTFChars(args->nice_name, nullptr);
        target_ = name && (!strcmp(name, "com.tencent.mm") || !strcmp(name, "com.tencent.wework"));
        selected_ = target_;
        if (target_) snprintf(package_, sizeof(package_), "%s", name);
        if (name) env_->ReleaseStringUTFChars(args->nice_name, name);
        if (!target_) { api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY); return; }
        const char *dir = env_->GetStringUTFChars(args->app_data_dir, nullptr);
        if (dir) { snprintf(dataDir_, sizeof(dataDir_), "%s", dir); env_->ReleaseStringUTFChars(args->app_data_dir, dir); }
        int module = api_->getModuleDir();
        if (module < 0) { preFailure_ = "MODULE_DIRECTORY_UNAVAILABLE"; target_ = false; return; }
        int disabled = openat(module, "off", O_RDONLY | O_CLOEXEC);
        if (disabled >= 0) { close(disabled); close(module); target_ = false; api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY); return; }
        int fd = openat(module, "bridge.dex", O_RDONLY | O_CLOEXEC);
        close(module);
        struct stat st{};
        if (fd < 0 || fstat(fd, &st) || st.st_size < 112 || st.st_size > 1024 * 1024) {
            preFailure_ = fd < 0 ? "BRIDGE_OPEN_FAILED" : "BRIDGE_SIZE_INVALID";
            if (fd >= 0) close(fd); target_ = false; return;
        }
        dex_.resize(st.st_size);
        size_t offset = 0;
        while (offset < dex_.size()) {
            ssize_t count = read(fd, dex_.data() + offset, dex_.size() - offset);
            if (count <= 0) break;
            offset += count;
        }
        close(fd);
        if (offset != dex_.size() || memcmp(dex_.data(), "dex\n", 4)) { preFailure_ = "BRIDGE_READ_INVALID"; target_ = false; }
    }
    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (!target_) { if (selected_ && preFailure_) failure(preFailure_); return; }
        failure("ENGINE_STARTED");
        ArtSymbols symbols;
        if (!symbols.open()) { failure("ART_SYMBOL_FILE_UNAVAILABLE"); return; }
        lsplant::InitInfo info{
            .inline_hooker = [](void *target, void *replacement) -> void * {
                void *backup = nullptr;
                return DobbyHook(target, replacement, &backup) == 0 ? backup : nullptr;
            },
            .inline_unhooker = [](void *target) { return DobbyDestroy(target) == 0; },
            .art_symbol_resolver = [&](std::string_view name) { return symbols.resolve(name); },
            .art_symbol_prefix_resolver = [&](std::string_view name) { return symbols.resolve(name, true); },
            .generated_class_name = "TabletSpoofHook_",
            .generated_source_name = "TabletSpoof",
        };
        if (!lsplant::Init(env_, info)) { failure("LSPLANT_INIT_FAILED"); return; }
        failure("LSPLANT_READY");
        jclass cl = env_->FindClass("java/lang/ClassLoader");
        jobject parent = env_->CallStaticObjectMethod(cl,
            env_->GetStaticMethodID(cl, "getSystemClassLoader", "()Ljava/lang/ClassLoader;"));
        jclass memoryLoader = env_->FindClass("dalvik/system/InMemoryDexClassLoader");
        jmethodID constructor = env_->GetMethodID(memoryLoader, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
        jobject buffer = env_->NewDirectByteBuffer(dex_.data(), dex_.size());
        jobject loader = env_->NewObject(memoryLoader, constructor, buffer, parent);
        jmethodID load = env_->GetMethodID(cl, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
        auto bridge = static_cast<jclass>(env_->CallObjectMethod(loader, load,
            env_->NewStringUTF("io.github.tabletspoof.nativebridge.Bridge")));
        if (env_->ExceptionCheck() || !bridge) { env_->ExceptionClear(); failure("BRIDGE_LOAD_FAILED"); return; }
        JNINativeMethod methods[] = {
            {const_cast<char *>("hook"), const_cast<char *>("(Ljava/lang/reflect/Method;Ljava/lang/Object;Ljava/lang/reflect/Method;)Ljava/lang/reflect/Method;"), reinterpret_cast<void *>(doHook)},
            {const_cast<char *>("deoptimize"), const_cast<char *>("(Ljava/lang/reflect/Method;)Z"), reinterpret_cast<void *>(deopt)},
            {const_cast<char *>("unhook"), const_cast<char *>("(Ljava/lang/reflect/Method;)Z"), reinterpret_cast<void *>(undoHook)},
        };
        if (env_->RegisterNatives(bridge, methods, 3) != 0) { env_->ExceptionClear(); failure("BRIDGE_REGISTER_FAILED"); return; }
        jmethodID bootstrap = env_->GetStaticMethodID(bridge, "bootstrap", "(Ljava/lang/String;Ljava/lang/String;)V");
        if (!bootstrap) { env_->ExceptionClear(); failure("BRIDGE_METHOD_MISSING"); return; }
        env_->CallStaticVoidMethod(bridge, bootstrap, env_->NewStringUTF(package_), env_->NewStringUTF(dataDir_));
        if (env_->ExceptionCheck()) { env_->ExceptionDescribe(); env_->ExceptionClear(); failure("BOOTSTRAP_FAILED"); return; }
        failure("BOOTSTRAP_INSTALLED");
    }
};
REGISTER_ZYGISK_MODULE(TabletSpoofNative)
