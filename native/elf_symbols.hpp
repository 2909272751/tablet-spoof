#pragma once
#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstring>
#include <string_view>

// Resolve both .dynsym and .symtab. dlsym alone cannot find private ART symbols.
class ArtSymbols {
    uintptr_t base_ = 0;
    char path_[512]{};
    const unsigned char *data_ = nullptr;
    size_t size_ = 0;
    bool range(size_t off, size_t n) const { return off <= size_ && n <= size_ - off; }
public:
    bool open() {
        dl_iterate_phdr([](dl_phdr_info *info, size_t, void *opaque) {
            auto self = static_cast<ArtSymbols *>(opaque);
            const char *name = info->dlpi_name;
            size_t n = strlen(name);
            if (n < 10 || strcmp(name + n - 10, "/libart.so") != 0) return 0;
            if (n >= sizeof(self->path_)) return 0;
            self->base_ = info->dlpi_addr;
            memcpy(self->path_, name, n + 1);
            return 1;
        }, this);
        if (!base_) return false;
        int fd = ::open(path_, O_RDONLY | O_CLOEXEC);
        struct stat st{};
        if (fd < 0 || fstat(fd, &st) || st.st_size < (off_t)sizeof(Elf64_Ehdr)) {
            if (fd >= 0) close(fd); return false;
        }
        size_ = st.st_size;
        void *mapped = mmap(nullptr, size_, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (mapped == MAP_FAILED) return false;
        data_ = static_cast<const unsigned char *>(mapped);
        const auto *header = reinterpret_cast<const Elf64_Ehdr *>(data_);
        return memcmp(header->e_ident, ELFMAG, SELFMAG) == 0 && header->e_ident[EI_CLASS] == ELFCLASS64
            && header->e_shentsize == sizeof(Elf64_Shdr)
            && range(header->e_shoff, size_t(header->e_shnum) * sizeof(Elf64_Shdr));
    }
    void *resolve(std::string_view requested, bool prefix = false) const {
        if (!data_) return nullptr;
        const auto *header = reinterpret_cast<const Elf64_Ehdr *>(data_);
        const auto *sections = reinterpret_cast<const Elf64_Shdr *>(data_ + header->e_shoff);
        for (int i = 0; i < header->e_shnum; ++i) {
            const auto &s = sections[i];
            if ((s.sh_type != SHT_SYMTAB && s.sh_type != SHT_DYNSYM)
                    || s.sh_entsize != sizeof(Elf64_Sym) || s.sh_link >= header->e_shnum
                    || !range(s.sh_offset, s.sh_size)) continue;
            const auto &strings = sections[s.sh_link];
            if (!range(strings.sh_offset, strings.sh_size)) continue;
            const auto *syms = reinterpret_cast<const Elf64_Sym *>(data_ + s.sh_offset);
            for (size_t j = 0; j < s.sh_size / sizeof(Elf64_Sym); ++j) {
                const auto &sym = syms[j];
                if (!sym.st_value || sym.st_shndx == SHN_UNDEF || sym.st_name >= strings.sh_size) continue;
                const char *name = reinterpret_cast<const char *>(data_ + strings.sh_offset + sym.st_name);
                size_t limit = strings.sh_size - sym.st_name;
                size_t len = strnlen(name, limit);
                if (len == limit) continue;
                std::string_view value(name, len);
                if ((prefix && value.starts_with(requested)) || (!prefix && value == requested))
                    return reinterpret_cast<void *>(base_ + sym.st_value);
            }
        }
        return nullptr;
    }
    ~ArtSymbols() { if (data_) munmap(const_cast<unsigned char *>(data_), size_); }
};
