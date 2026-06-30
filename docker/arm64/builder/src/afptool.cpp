// afptool -- native arm64 replacement for the x86-64 prebuilt the SDK runs under
// Rosetta in tools/linux/Linux_Pack_Firmware/mk-update_pack.sh, packing the
// partition images into a Rockchip RKAF archive (update_tmp.img) that rkImageMaker
// then wraps into update.img.
//
// The public afptool sources (neo-technologies / TeeFirefly rk2918_tools / radxa)
// are an older lineage whose RKAF differs from the shipped "Android Firmware
// Package Tool v2.2": it reads a text parameter file, not the SDK's binary
// env.img, and stores the 4th UPDATE_PART field as padded bytes, not a 2048-byte
// page count. This is a from-scratch v2.2-compatible packer, verified to produce a
// byte-identical RKAF to the x86 prebuilt.
//
// Only "-pack" is implemented (the only mode mk-update_pack.sh uses); the fork's
// afptool/img_unpack handles unpacking on the flashing host.
//
// Usage:  afptool -pack <src_dir> <out.img>
// Build:  g++ -O2 -std=gnu++11 -o afptool afptool.cpp

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

// --- RK CRC: 32-bit, MSB-first, table-driven, init 0 (same table as the SDK's
//     rkcrc / u-boot crc32_rk) --------------------------------------------------
// clang-format off
static const uint32_t RK_CRC_T[256] = {
	0x00000000, 0x04c10db7, 0x09821b6e, 0x0d4316d9, 0x130436dc, 0x17c53b6b, 0x1a862db2, 0x1e472005,
	0x26086db8, 0x22c9600f, 0x2f8a76d6, 0x2b4b7b61, 0x350c5b64, 0x31cd56d3, 0x3c8e400a, 0x384f4dbd,
	0x4c10db70, 0x48d1d6c7, 0x4592c01e, 0x4153cda9, 0x5f14edac, 0x5bd5e01b, 0x5696f6c2, 0x5257fb75,
	0x6a18b6c8, 0x6ed9bb7f, 0x639aada6, 0x675ba011, 0x791c8014, 0x7ddd8da3, 0x709e9b7a, 0x745f96cd,
	0x9821b6e0, 0x9ce0bb57, 0x91a3ad8e, 0x9562a039, 0x8b25803c, 0x8fe48d8b, 0x82a79b52, 0x866696e5,
	0xbe29db58, 0xbae8d6ef, 0xb7abc036, 0xb36acd81, 0xad2ded84, 0xa9ece033, 0xa4aff6ea, 0xa06efb5d,
	0xd4316d90, 0xd0f06027, 0xddb376fe, 0xd9727b49, 0xc7355b4c, 0xc3f456fb, 0xceb74022, 0xca764d95,
	0xf2390028, 0xf6f80d9f, 0xfbbb1b46, 0xff7a16f1, 0xe13d36f4, 0xe5fc3b43, 0xe8bf2d9a, 0xec7e202d,
	0x34826077, 0x30436dc0, 0x3d007b19, 0x39c176ae, 0x278656ab, 0x23475b1c, 0x2e044dc5, 0x2ac54072,
	0x128a0dcf, 0x164b0078, 0x1b0816a1, 0x1fc91b16, 0x018e3b13, 0x054f36a4, 0x080c207d, 0x0ccd2dca,
	0x7892bb07, 0x7c53b6b0, 0x7110a069, 0x75d1adde, 0x6b968ddb, 0x6f57806c, 0x621496b5, 0x66d59b02,
	0x5e9ad6bf, 0x5a5bdb08, 0x5718cdd1, 0x53d9c066, 0x4d9ee063, 0x495fedd4, 0x441cfb0d, 0x40ddf6ba,
	0xaca3d697, 0xa862db20, 0xa521cdf9, 0xa1e0c04e, 0xbfa7e04b, 0xbb66edfc, 0xb625fb25, 0xb2e4f692,
	0x8aabbb2f, 0x8e6ab698, 0x8329a041, 0x87e8adf6, 0x99af8df3, 0x9d6e8044, 0x902d969d, 0x94ec9b2a,
	0xe0b30de7, 0xe4720050, 0xe9311689, 0xedf01b3e, 0xf3b73b3b, 0xf776368c, 0xfa352055, 0xfef42de2,
	0xc6bb605f, 0xc27a6de8, 0xcf397b31, 0xcbf87686, 0xd5bf5683, 0xd17e5b34, 0xdc3d4ded, 0xd8fc405a,
	0x6904c0ee, 0x6dc5cd59, 0x6086db80, 0x6447d637, 0x7a00f632, 0x7ec1fb85, 0x7382ed5c, 0x7743e0eb,
	0x4f0cad56, 0x4bcda0e1, 0x468eb638, 0x424fbb8f, 0x5c089b8a, 0x58c9963d, 0x558a80e4, 0x514b8d53,
	0x25141b9e, 0x21d51629, 0x2c9600f0, 0x28570d47, 0x36102d42, 0x32d120f5, 0x3f92362c, 0x3b533b9b,
	0x031c7626, 0x07dd7b91, 0x0a9e6d48, 0x0e5f60ff, 0x101840fa, 0x14d94d4d, 0x199a5b94, 0x1d5b5623,
	0xf125760e, 0xf5e47bb9, 0xf8a76d60, 0xfc6660d7, 0xe22140d2, 0xe6e04d65, 0xeba35bbc, 0xef62560b,
	0xd72d1bb6, 0xd3ec1601, 0xdeaf00d8, 0xda6e0d6f, 0xc4292d6a, 0xc0e820dd, 0xcdab3604, 0xc96a3bb3,
	0xbd35ad7e, 0xb9f4a0c9, 0xb4b7b610, 0xb076bba7, 0xae319ba2, 0xaaf09615, 0xa7b380cc, 0xa3728d7b,
	0x9b3dc0c6, 0x9ffccd71, 0x92bfdba8, 0x967ed61f, 0x8839f61a, 0x8cf8fbad, 0x81bbed74, 0x857ae0c3,
	0x5d86a099, 0x5947ad2e, 0x5404bbf7, 0x50c5b640, 0x4e829645, 0x4a439bf2, 0x47008d2b, 0x43c1809c,
	0x7b8ecd21, 0x7f4fc096, 0x720cd64f, 0x76cddbf8, 0x688afbfd, 0x6c4bf64a, 0x6108e093, 0x65c9ed24,
	0x11967be9, 0x1557765e, 0x18146087, 0x1cd56d30, 0x02924d35, 0x06534082, 0x0b10565b, 0x0fd15bec,
	0x379e1651, 0x335f1be6, 0x3e1c0d3f, 0x3add0088, 0x249a208d, 0x205b2d3a, 0x2d183be3, 0x29d93654,
	0xc5a71679, 0xc1661bce, 0xcc250d17, 0xc8e400a0, 0xd6a320a5, 0xd2622d12, 0xdf213bcb, 0xdbe0367c,
	0xe3af7bc1, 0xe76e7676, 0xea2d60af, 0xeeec6d18, 0xf0ab4d1d, 0xf46a40aa, 0xf9295673, 0xfde85bc4,
	0x89b7cd09, 0x8d76c0be, 0x8035d667, 0x84f4dbd0, 0x9ab3fbd5, 0x9e72f662, 0x9331e0bb, 0x97f0ed0c,
	0xafbfa0b1, 0xab7ead06, 0xa63dbbdf, 0xa2fcb668, 0xbcbb966d, 0xb87a9bda, 0xb5398d03, 0xb1f880b4,
};
// clang-format on

static uint32_t rk_crc(uint32_t crc, const uint8_t *buf, size_t len)
{
	while (len--)
		crc = (crc << 8) ^ RK_CRC_T[(crc >> 24) ^ *buf++];
	return crc;
}

#pragma pack(1)
struct UPDATE_PART {
	char name[32];
	char fullpath[60];
	uint32_t flash_size; // partition size in 512-byte sectors (0 if off-flash)
	uint32_t part_offset; // byte offset of this part's data within the .img
	uint32_t flash_offset; // partition start in 512-byte sectors (0xffffffff if off-flash)
	uint32_t page_count; // part_bytecount rounded up to 2048-byte pages
	uint32_t part_bytecount; // real file size in bytes
};
struct UPDATE_HEADER {
	char magic[4]; // "RKAF"
	uint32_t length; // file size excluding the trailing 4-byte CRC
	char model[34];
	char id[30];
	char manufacturer[56];
	uint32_t unknown1;
	uint32_t version;
	uint32_t num_parts;
	UPDATE_PART parts[16];
	char reserved[116];
};
#pragma pack()
static_assert(sizeof(UPDATE_PART) == 112, "UPDATE_PART must be 112 bytes");
static_assert(sizeof(UPDATE_HEADER) == 0x800, "UPDATE_HEADER must be 2048 bytes");

static const uint32_t SECTOR = 512;
static const uint32_t PAGE = 2048;

struct Flash {
	uint32_t off_sectors;
	uint32_t size_sectors;
};

// Parse "<num>[KMGkmg]"; returns bytes. *end is advanced past the token.
static uint64_t parse_kmg(const char *s, char **end)
{
	uint64_t v = strtoull(s, end, 0);
	switch (**end) {
	case 'K':
	case 'k':
		v <<= 10;
		++*end;
		break;
	case 'M':
	case 'm':
		v <<= 20;
		++*end;
		break;
	case 'G':
	case 'g':
		v <<= 30;
		++*end;
		break;
	}
	return v;
}

// Extract the SPI-NAND mtdparts from a binary env.img and parse it into a
// name -> {flash offset, flash size} (both in 512-byte sectors) map. Format:
//   mtdparts=spi-nand0:256K(env),256K@256K(idblock),512K(uboot),...,210M(rootfs)
// A partition with no explicit @offset follows the previous one contiguously.
static std::map<std::string, Flash> parse_mtdparts(const std::vector<char> &env)
{
	std::map<std::string, Flash> out;
	static const char key[] = "mtdparts=";
	const char *base = env.data();
	const char *hit = (const char *)memmem(base, env.size(), key, sizeof(key) - 1);
	if (!hit) {
		fprintf(stderr, "afptool: no mtdparts in env image\n");
		return out;
	}
	const char *p = strchr(hit, ':'); // skip the "spi-nand0" device id
	if (!p)
		return out;
	++p;

	uint64_t running = 0; // contiguous byte offset
	while (*p && *p != '\n' && *p != '\r' && *p != ' ') {
		char *q;
		uint64_t size = 0;
		bool size_rest = false;
		if (*p == '-') {
			size_rest = true;
			q = (char *)p + 1;
		} // expand-to-end
		else
			size = parse_kmg(p, &q);

		uint64_t off = running;
		if (*q == '@') {
			off = parse_kmg(q + 1, &q);
		}

		const char *lp = strchr(q, '(');
		const char *rp = lp ? strchr(lp, ')') : nullptr;
		if (!lp || !rp)
			break;
		std::string name(lp + 1, rp - lp - 1);

		Flash f;
		f.off_sectors = (uint32_t)(off / SECTOR);
		f.size_sectors = size_rest ? 0 : (uint32_t)(size / SECTOR);
		out[name] = f;

		if (!size_rest)
			running = off + size;

		p = strchr(rp, ','); // next partition, or done
		if (!p)
			break;
		++p;
	}
	return out;
}

// fwrite the whole buffer; false on short write (e.g. disk full).
static bool fwrite_all(const void *p, size_t n, FILE *fp)
{
	return fwrite(p, 1, n, fp) == n;
}

// Append `path` to fp in 2048-byte pages (last page zero-padded). Returns bytes
// read; *pages gets the page count. Returns (uint32_t)-1 on open or write error.
static uint32_t append_padded(FILE *fp, const char *path, uint32_t *pages)
{
	FILE *in = fopen(path, "rb");
	if (!in)
		return (uint32_t)-1;
	char buf[PAGE];
	uint32_t total = 0, npages = 0;
	size_t n;
	while ((n = fread(buf, 1, PAGE, in)) != 0) {
		if (n < PAGE)
			memset(buf + n, 0, PAGE - n);
		if (!fwrite_all(buf, PAGE, fp)) {
			fclose(in);
			return (uint32_t)-1;
		}
		total += (uint32_t)n;
		++npages;
	}
	fclose(in);
	*pages = npages;
	return total;
}

static int pack_update(const char *srcdir, const char *dstfile)
{
	// 1. package-file: ordered list of "<name>\t<relpath>"
	std::string pkgpath = std::string(srcdir) + "/package-file";
	FILE *pf = fopen(pkgpath.c_str(), "r");
	if (!pf) {
		fprintf(stderr, "afptool: can't open %s\n", pkgpath.c_str());
		return -1;
	}
	std::vector<std::pair<std::string, std::string>> packages;
	char line[4096];
	while (fgets(line, sizeof(line), pf)) {
		char *s = line;
		while (*s && isspace((unsigned char)*s))
			++s;
		if (*s == '#' || *s == 0)
			continue;
		char *name = s;
		while (*s && !isspace((unsigned char)*s))
			++s;
		if (*s)
			*s++ = 0;
		while (*s && isspace((unsigned char)*s))
			++s;
		char *path = s;
		while (*s && !isspace((unsigned char)*s))
			++s;
		*s = 0;
		if (*name && *path)
			packages.emplace_back(name, path);
	}
	fclose(pf);
	if (packages.size() > 16)
		fprintf(stderr, "afptool: warning: %zu partitions listed, only first 16 packed\n",
			packages.size());

	// 2. env.img -> partition flash geometry
	std::string envpath = std::string(srcdir) + "/env.img";
	std::map<std::string, Flash> flash;
	FILE *ef = fopen(envpath.c_str(), "rb");
	if (ef) {
		fseek(ef, 0, SEEK_END);
		long sz = ftell(ef);
		fseek(ef, 0, SEEK_SET);
		if (sz > 0) {
			std::vector<char> env(
				sz + 1); // +1 NUL keeps strchr in parse_mtdparts bounded
			if (fread(env.data(), 1, sz, ef) == (size_t)sz)
				flash = parse_mtdparts(env);
		}
		fclose(ef);
	}

	// 3. write RKAF: placeholder header, then each file padded to 2048
	FILE *fp = fopen(dstfile, "wb+");
	if (!fp) {
		fprintf(stderr, "afptool: can't open %s\n", dstfile);
		return -1;
	}

	UPDATE_HEADER h;
	memset(&h, 0, sizeof(h));
	memcpy(h.magic, "RKAF", 4);
	if (!fwrite_all(&h, sizeof(h), fp)) {
		fprintf(stderr, "afptool: write error on %s\n", dstfile);
		fclose(fp);
		return -1;
	}

	uint32_t n = 0;
	for (size_t i = 0; i < packages.size() && i < 16; ++i, ++n) {
		const std::string &name = packages[i].first;
		const std::string &rel = packages[i].second;
		UPDATE_PART &part = h.parts[i];
		strncpy(part.name, name.c_str(), sizeof(part.name) - 1);
		strncpy(part.fullpath, rel.c_str(), sizeof(part.fullpath) - 1);

		part.part_offset = (uint32_t)ftell(fp);

		std::string filepath = std::string(srcdir) + "/" + rel;
		uint32_t pages = 0;
		uint32_t bytes = append_padded(fp, filepath.c_str(), &pages);
		if (bytes == (uint32_t)-1) {
			fprintf(stderr, "afptool: I/O error on input %s\n", filepath.c_str());
			fclose(fp);
			return -1;
		}
		part.part_bytecount = bytes;
		part.page_count = pages;

		auto it = flash.find(name);
		if (it != flash.end()) {
			part.flash_offset = it->second.off_sectors;
			part.flash_size = it->second.size_sectors;
		} else {
			part.flash_offset =
				0xffffffff; // not a flash partition (package-file, bootloader)
			part.flash_size = 0;
		}
		printf("  %-12s off=0x%x bytes=0x%x pages=0x%x flash_off=0x%x flash_size=0x%x\n",
			name.c_str(), part.part_offset, part.part_bytecount, part.page_count,
			part.flash_offset, part.flash_size);
	}

	h.num_parts = n;
	long filelen = ftell(fp);
	h.length = (uint32_t)filelen; // size before the trailing CRC

	fseek(fp, 0, SEEK_SET);
	if (!fwrite_all(&h, sizeof(h), fp)) {
		fprintf(stderr, "afptool: write error on %s\n", dstfile);
		fclose(fp);
		return -1;
	}

	// 4. whole-file RKCRC (init 0) appended as 4 little-endian bytes
	fseek(fp, 0, SEEK_SET);
	uint32_t crc = 0;
	char cbuf[64 * 1024];
	long remain = filelen;
	while (remain > 0) {
		size_t want = remain < (long)sizeof(cbuf) ? (size_t)remain : sizeof(cbuf);
		size_t got = fread(cbuf, 1, want, fp);
		if (!got)
			break;
		crc = rk_crc(crc, (const uint8_t *)cbuf, got);
		remain -= got;
	}
	fseek(fp, 0, SEEK_END);
	if (!fwrite_all(&crc, sizeof(crc), fp)) {
		fprintf(stderr, "afptool: write error on %s\n", dstfile);
		fclose(fp);
		return -1;
	}

	fclose(fp);
	fprintf(stderr, "afptool: packed %u partitions, %ld bytes + CRC -> %s\n", n, filelen,
		dstfile);
	return 0;
}

int main(int argc, char **argv)
{
	fprintf(stderr, "afptool (native arm64, v2.2-compatible -pack)\n");
	if (argc == 4 && strcmp(argv[1], "-pack") == 0)
		return pack_update(argv[2], argv[3]) == 0 ? 0 : 1;
	fprintf(stderr, "Usage: %s -pack <src_dir> <out.img>\n", argv[0]);
	return 1;
}
