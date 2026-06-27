// rkImageMaker -- native arm64 replacement for the x86-64 prebuilt the SDK runs
// under Rosetta in tools/linux/Linux_Pack_Firmware/mk-update_pack.sh to wrap the
// RKAF firmware archive into a flashable RKFW update.img.
//
// The fork's rockchip-tool/img_maker.cpp is the wrong, older packer (CLI
// -rk29/-rk30, no -RK1106, old chip codes), so this implements the RKFW layout the
// shipped "rkImageMaker ver 2.2" emits, verified byte-for-byte against the
// reference RV1106 update.img: the header (head_len 0x66, chip ASCII "6011", code
// 0x02000000, version 0, unknown2 1, system_fstype 0, backup_endpos 0), loader
// (download.bin) then RKAF image contiguous after it, and a trailing 32-char
// lowercase-hex MD5 over the whole preceding file.
//
// Usage (exactly as mk-update_pack.sh invokes it):
//   rkImageMaker -RK1106 <download.bin> <rkaf.img> <update.img> -os_type:androidos
//
// Build: g++ -O2 -std=gnu++11 -o rkImageMaker rkImageMaker.cpp -lcrypto

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <openssl/evp.h>

#pragma pack(1)
struct RKFW_HEADER {
	char head_code[4]; // 0x00 "RKFW"
	uint16_t head_len; // 0x04 0x66
	uint32_t version; // 0x06 0
	uint32_t code; // 0x0a 0x02000000 (ver-2.2 format)
	uint16_t year; // 0x0e build time
	uint8_t month; // 0x10
	uint8_t day; // 0x11
	uint8_t hour; // 0x12
	uint8_t minute; // 0x13
	uint8_t second; // 0x14
	uint32_t chip; // 0x15 RV1106: ASCII "6011"
	uint32_t loader_offset; // 0x19 0x66 (loader right after header)
	uint32_t loader_length; // 0x1d
	uint32_t image_offset; // 0x21
	uint32_t image_length; // 0x25
	uint32_t unknown1; // 0x29 0
	uint32_t unknown2; // 0x2d 1
	uint32_t system_fstype; // 0x31 0
	uint32_t backup_endpos; // 0x35 0 (no backup partition on this board)
	uint8_t reserved[0x66 - 0x39];
};
#pragma pack()
static_assert(sizeof(RKFW_HEADER) == 0x66, "RKFW_HEADER must be 102 bytes");

// fwrite the whole buffer; false on short write (e.g. disk full).
static bool fwrite_all(const void *p, size_t n, FILE *fp)
{
	return fwrite(p, 1, n, fp) == n;
}

// Append the whole file at `path` to `fp`; return bytes copied (0 = open or
// write error).
static uint32_t append_file(const char *path, FILE *fp)
{
	FILE *in = fopen(path, "rb");
	if (!in)
		return 0;
	char buf[64 * 1024];
	uint32_t total = 0;
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), in)) != 0) {
		if (!fwrite_all(buf, n, fp)) {
			fclose(in);
			return 0;
		}
		total += (uint32_t)n;
	}
	fclose(in);
	return total;
}

// MD5 the whole file written so far, then append it as 32 lowercase hex chars at
// the end -- the trailing digest the reference update.img carries.
static int append_md5(FILE *fp)
{
	if (fseek(fp, 0, SEEK_SET) != 0)
		return -1;
	EVP_MD_CTX *ctx = EVP_MD_CTX_new();
	if (!ctx)
		return -1;
	if (EVP_DigestInit_ex(ctx, EVP_md5(), nullptr) != 1) {
		EVP_MD_CTX_free(ctx);
		return -1;
	}
	char buf[64 * 1024];
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), fp)) != 0) {
		if (EVP_DigestUpdate(ctx, buf, n) != 1) {
			EVP_MD_CTX_free(ctx);
			return -1;
		}
	}
	unsigned char digest[EVP_MAX_MD_SIZE];
	unsigned dlen = 0;
	int ok = EVP_DigestFinal_ex(ctx, digest, &dlen);
	EVP_MD_CTX_free(ctx);
	if (ok != 1)
		return -1;
	if (fseek(fp, 0, SEEK_END) != 0)
		return -1;
	for (unsigned i = 0; i < dlen; ++i)
		if (fprintf(fp, "%02x", digest[i]) != 2)
			return -1;
	return 0;
}

int main(int argc, char **argv)
{
	fprintf(stderr, "rkImageMaker (native arm64, ver 2.2-compatible)\n");

	// mk-update_pack.sh: -RK<chip> <loader> <image> <out> [-os_type:...]
	if (argc < 5 || strncmp(argv[1], "-RK", 3) != 0) {
		fprintf(stderr,
			"Usage: %s -RK<chip> <loader.bin> <rkaf.img> <update.img> [-os_type:...]\n",
			argv[0]);
		return 1;
	}

	const char *chip_tag = argv[1] + 3; // e.g. "1106"
	const char *loader = argv[2];
	const char *image = argv[3];
	const char *outfile = argv[4];

	RKFW_HEADER h;
	memset(&h, 0, sizeof(h));
	memcpy(h.head_code, "RKFW", 4);
	h.head_len = sizeof(h); // 0x66
	h.loader_offset = sizeof(h); // loader immediately after the header
	h.version = 0;
	h.code = 0x02000000;
	h.unknown1 = 0;
	h.unknown2 = 1;
	h.system_fstype = 0;
	h.backup_endpos = 0;

	// RV1106 ("-RK1106") stores its chip id as the ASCII string "6011".
	if (strcmp(chip_tag, "1106") == 0) {
		memcpy(&h.chip, "6011", 4);
	} else {
		fprintf(stderr, "ERROR: unsupported chip -RK%s (only RK1106 is mapped)\n",
			chip_tag);
		return 1;
	}

	time_t now = time(nullptr);
	struct tm lt;
	localtime_r(&now, &lt);
	h.year = (uint16_t)(lt.tm_year + 1900);
	h.month = (uint8_t)(lt.tm_mon + 1);
	h.day = (uint8_t)lt.tm_mday;
	h.hour = (uint8_t)lt.tm_hour;
	h.minute = (uint8_t)lt.tm_min;
	h.second = (uint8_t)lt.tm_sec;

	FILE *fp = fopen(outfile, "wb+");
	if (!fp) {
		fprintf(stderr, "ERROR: can't open %s\n", outfile);
		return 1;
	}

	// placeholder header; offsets/lengths are patched in once the payloads are known
	if (!fwrite_all(&h, sizeof(h), fp)) {
		fprintf(stderr, "ERROR: write failed on %s\n", outfile);
		fclose(fp);
		return 1;
	}

	h.loader_length = append_file(loader, fp);
	if (h.loader_length == 0) {
		fprintf(stderr, "ERROR: loader %s missing, empty, or write failed\n", loader);
		fclose(fp);
		return 1;
	}

	h.image_offset = h.loader_offset + h.loader_length;
	h.image_length = append_file(image, fp);
	if (h.image_length == 0) {
		fprintf(stderr, "ERROR: image %s missing, empty, or write failed\n", image);
		fclose(fp);
		return 1;
	}

	// rewrite the now-complete header, then append the whole-file MD5
	fseek(fp, 0, SEEK_SET);
	if (!fwrite_all(&h, sizeof(h), fp)) {
		fprintf(stderr, "ERROR: write failed on %s\n", outfile);
		fclose(fp);
		return 1;
	}
	if (append_md5(fp) != 0) {
		fprintf(stderr, "ERROR: md5 append failed\n");
		fclose(fp);
		return 1;
	}

	fclose(fp);
	fprintf(stderr, "rkImageMaker: %s OK (loader %u B, image %u B)\n", outfile, h.loader_length,
		h.image_length);
	return 0;
}
