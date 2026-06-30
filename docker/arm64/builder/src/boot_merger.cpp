// boot_merger -- native arm64 replacement for the closed x86-64 rkbin boot_merger,
// for the RV1106 NEWIDB loader. Emits the same two artifacts the closed tool does:
// the "LDR " USB loader (download.bin, the ini PATH) and the idblock written to
// flash (idblock.img, the ini IDB_PATH). The closed tool is the only one that emits
// this LDR/RKNS container; the open-source u-boot boot_merger.c emits the older
// "BOOT" container the RV1106 BootROM rejects. This reimplements the NEWIDB layout,
// verified byte-for-byte against the closed "boot_merger ver 1.35" output (only
// rk_boot_header.releaseTime, the build timestamp, differs).
//
// Layout:
//   download.bin: rk_boot_header("LDR ") + 6 entries + UsbHead-RKNS+DDR+usbplug
//     (plain) + RC4-per-512( FlashHead-RKNS+DDR+SPL ) + Rockchip-CRC32.
//   idblock.img:  the FlashHead-RKNS+DDR+SPL region in plaintext (download.bin
//     embeds the RC4 form of these same bytes).
//
// Usage (drop-in for the closed tool):
//   boot_merger RKBOOT/RV1106MINIALL.ini   (paths in the ini are cwd-relative)
//
// Build: g++ -O2 -std=gnu++11 -o boot_merger boot_merger.cpp -lcrypto

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <openssl/evp.h>
#include <string>
#include <vector>

using std::string;
using std::vector;
typedef vector<uint8_t> bytes;

static const int ALIGN = 2048; // RK_SIZE_ALIGN
static const int BLK = 512; // RK_BLK_SIZE
static const int RKNS_HDR = 2048;
static const uint32_t RK_MAGIC_V2 = 0x534E4B52; // "RKNS"
static const uint8_t RC4_KEY[16] = { 124, 78, 3, 4, 85, 5, 9, 7, 45, 44, 123, 56, 23, 13, 23, 17 };

static void die(const char *msg)
{
	fprintf(stderr, "boot_merger: %s\n", msg);
	exit(1);
}

static bytes read_file(const string &path)
{
	FILE *fp = fopen(path.c_str(), "rb");
	if (!fp)
		die(("cannot open " + path).c_str());
	fseek(fp, 0, SEEK_END);
	long n = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	bytes b(n);
	if (n && fread(b.data(), 1, n, fp) != (size_t)n)
		die(("short read " + path).c_str());
	fclose(fp);
	return b;
}

static void write_file(const string &path, const bytes &b)
{
	FILE *fp = fopen(path.c_str(), "wb");
	if (!fp || fwrite(b.data(), 1, b.size(), fp) != b.size())
		die(("cannot write " + path).c_str());
	fclose(fp);
	printf("boot_merger: wrote %s (%zu bytes)\n", path.c_str(), b.size());
}

static size_t align_up(size_t n)
{
	return (n + ALIGN - 1) / ALIGN * ALIGN;
}

static void sha256(const uint8_t *p, size_t n, uint8_t out[32])
{
	unsigned len = 0;
	EVP_Digest(p, n, out, &len, EVP_sha256(), NULL);
}

// Rockchip CRC32: table-driven MSB-first, poly 0x04C10DB7, init 0, no final xor.
static uint32_t rk_crc32(const uint8_t *p, size_t n)
{
	static uint32_t t[256];
	static bool init = false;
	if (!init) {
		for (int i = 0; i < 256; i++) {
			uint32_t c = (uint32_t)i << 24;
			for (int k = 0; k < 8; k++)
				c = (c & 0x80000000) ? (c << 1) ^ 0x04C10DB7 : (c << 1);
			t[i] = c;
		}
		init = true;
	}
	uint32_t a = 0;
	for (size_t i = 0; i < n; i++)
		a = (a << 8) ^ t[(a >> 24) ^ p[i]];
	return a;
}

// RC4 each 512-byte block independently (fresh key schedule per block).
static void rc4_per_block(uint8_t *buf, size_t n)
{
	for (size_t off = 0; off < n; off += BLK) {
		size_t len = (n - off < (size_t)BLK) ? n - off : BLK;
		uint8_t S[256];
		for (int i = 0; i < 256; i++)
			S[i] = i;
		for (int i = 0, j = 0; i < 256; i++) {
			j = (j + S[i] + RC4_KEY[i % 16]) & 0xff;
			uint8_t tmp = S[i];
			S[i] = S[j];
			S[j] = tmp;
		}
		uint8_t *b = buf + off;
		for (size_t k = 0, i = 0, j = 0; k < len; k++) {
			i = (i + 1) & 0xff;
			j = (j + S[i]) & 0xff;
			uint8_t tmp = S[i];
			S[i] = S[j];
			S[j] = tmp;
			b[k] ^= S[(S[i] + S[j]) & 0xff];
		}
	}
}

#pragma pack(1)
struct rk_boot_entry {
	uint8_t size;
	uint32_t type;
	uint16_t name[20];
	uint32_t dataOffset;
	uint32_t dataSize;
	uint32_t dataDelay;
};
struct rk_boot_header {
	uint32_t tag;
	uint16_t size;
	uint32_t version;
	uint32_t mergerVersion;
	uint16_t year;
	uint8_t month, day, hour, minute, second;
	uint32_t chipType;
	uint8_t c471Num;
	uint32_t c471Off;
	uint8_t c471Size;
	uint8_t c472Num;
	uint32_t c472Off;
	uint8_t c472Size;
	uint8_t ldrNum;
	uint32_t ldrOff;
	uint8_t ldrSize;
	uint8_t signFlag;
	uint8_t rc4Flag;
	uint8_t reserved[57];
};
#pragma pack()
static_assert(sizeof(rk_boot_entry) == 57, "entry must be 57 bytes");
static_assert(sizeof(rk_boot_header) == 102, "header must be 102 bytes");

// Build an RKNS region: [2048 header][img0 aligned][img1 aligned], hashes filled
// per rkcommon_set_header0_v2(). Returns the plaintext region.
static bytes build_rkns_region(const vector<const bytes *> &imgs)
{
	size_t total = RKNS_HDR;
	vector<size_t> asz;
	for (const bytes *b : imgs) {
		asz.push_back(align_up(b->size()));
		total += asz.back();
	}
	bytes r(total, 0);
	// place images
	size_t off = RKNS_HDR;
	for (size_t i = 0; i < imgs.size(); i++) {
		memcpy(r.data() + off, imgs[i]->data(), imgs[i]->size());
		off += asz[i];
	}
	// header fields
	uint32_t magic = RK_MAGIC_V2;
	memcpy(r.data() + 0, &magic, 4);
	uint32_t sni = (2u << 16) + 384;
	memcpy(r.data() + 8, &sni, 4);
	uint32_t bflag = 1; // HASH_SHA256
	memcpy(r.data() + 12, &bflag, 4);
	uint32_t sector_off = 4;
	for (size_t i = 0; i < imgs.size(); i++) {
		uint8_t *e = r.data() + 120 + i * 88;
		uint32_t blocks = asz[i] / BLK;
		uint32_t size_and_off = (blocks << 16) | sector_off;
		uint32_t addr = 0xFFFFFFFF;
		uint32_t flag = 0;
		uint32_t counter = i + 1;
		memcpy(e + 0, &size_and_off, 4);
		memcpy(e + 4, &addr, 4);
		memcpy(e + 8, &flag, 4);
		memcpy(e + 12, &counter, 4);
		sha256(r.data() + sector_off * BLK, asz[i], e + 24);
		sector_off += blocks;
	}
	sha256(r.data(), 1536, r.data() + 1536);
	return r;
}

// "rv1106_ddr_924MHz_v1.15.bin" -> u16 name[20], basename cut at first '.', <=20.
// Plain labels ("UsbHead", "FlashData", ...) have no '/' or '.' so pass through.
static void set_name(uint16_t name[20], const string &path)
{
	size_t slash = path.find_last_of('/');
	string base = (slash == string::npos) ? path : path.substr(slash + 1);
	size_t dot = base.find('.');
	if (dot != string::npos)
		base.resize(dot);
	memset(name, 0, 40);
	for (size_t i = 0; i < base.size() && i < 20; i++)
		name[i] = (uint8_t)base[i];
}

static void put(bytes &dst, const void *p, size_t n)
{
	const uint8_t *b = static_cast<const uint8_t *>(p);
	dst.insert(dst.end(), b, b + n);
}

// Minimal ini value lookup: find "key=" after "[section]" header. With
// required=false a missing section/key yields "" instead of aborting.
static string ini_get(
	const string &ini, const string &section, const string &key, bool required = true)
{
	size_t s = ini.find(section);
	if (s == string::npos) {
		if (!required)
			return "";
		die(("ini missing " + section).c_str());
	}
	size_t next = ini.find('[', s + section.size());
	string blk = ini.substr(s, next == string::npos ? string::npos : next - s);
	size_t k = blk.find("\n" + key + "=");
	if (k == string::npos) {
		if (!required)
			return "";
		die(("ini missing " + key + " in " + section).c_str());
	}
	size_t v = blk.find('=', k) + 1;
	size_t e = blk.find_first_of("\r\n", v);
	return blk.substr(v, e == string::npos ? string::npos : e - v);
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <RV1106MINIALL.ini>\n", argv[0]);
		return 1;
	}
	bytes inib = read_file(argv[1]);
	string ini(inib.begin(), inib.end());

	int major = atoi(ini_get(ini, "[VERSION]", "MAJOR").c_str());
	int minor = atoi(ini_get(ini, "[VERSION]", "MINOR").c_str());
	int sleep471 = atoi(ini_get(ini, "[CODE471_OPTION]", "Sleep").c_str());
	string ddr_path = ini_get(ini, "[CODE471_OPTION]", "Path1");
	string usb_path = ini_get(ini, "[CODE472_OPTION]", "Path1");
	string spl_path = ini_get(ini, "[LOADER_OPTION]", "FlashBoot");
	string out_path = ini_get(ini, "[OUTPUT]", "PATH");
	string idb_path = ini_get(ini, "[OUTPUT]", "IDB_PATH", false);
	bool create_idb = ini_get(ini, "[FLAG]", "CREATE_IDB", false) == "true";

	bytes ddr = read_file(ddr_path);
	bytes usb = read_file(usb_path);
	bytes spl = read_file(spl_path);

	bytes usb_region = build_rkns_region({ &ddr, &usb });
	bytes flash_region = build_rkns_region({ &ddr, &spl });
	// idblock.img (IDB_PATH) is this flash region in plaintext; download.bin embeds
	// its RC4 form below. The closed tool writes it when CREATE_IDB=true.
	if (create_idb && !idb_path.empty())
		write_file(idb_path, flash_region);
	rc4_per_block(flash_region.data(), flash_region.size());

	size_t ddr_a = align_up(ddr.size());
	size_t usb_a = align_up(usb.size());
	size_t spl_a = align_up(spl.size());

	// offsets in the final file
	uint32_t entry_off = sizeof(rk_boot_header); // 102
	uint32_t usbhead_off = entry_off + 6 * sizeof(rk_boot_entry); // 444
	uint32_t ddr_off = usbhead_off + RKNS_HDR;
	uint32_t usb_off = ddr_off + ddr_a;
	uint32_t flashhead_off = usb_off + usb_a;
	uint32_t fddr_off = flashhead_off + RKNS_HDR;
	uint32_t spl_off = fddr_off + ddr_a;

	rk_boot_header h;
	memset(&h, 0, sizeof(h));
	h.tag = 0x2052444C; // "LDR "
	h.size = sizeof(rk_boot_header);
	h.version = ((major / 10) << 12) | ((major % 10) << 8) | ((minor / 10) << 4) | (minor % 10);
	h.mergerVersion = 0x01000000;
	// Reproducible when SOURCE_DATE_EPOCH is set; else current local time (the
	// closed boot_merger stamps the build time the same way).
	time_t now = time(NULL);
	const char *sde = getenv("SOURCE_DATE_EPOCH");
	struct tm *tm;
	if (sde && *sde) {
		now = (time_t)strtoull(sde, NULL, 10);
		tm = gmtime(&now);
	} else {
		tm = localtime(&now);
	}
	h.year = tm->tm_year + 1900;
	h.month = tm->tm_mon + 1;
	h.day = tm->tm_mday;
	h.hour = tm->tm_hour;
	h.minute = tm->tm_min;
	h.second = tm->tm_sec;
	memcpy(&h.chipType, "6011", 4); // RV1106 chip code
	h.c471Num = 2;
	h.c471Off = entry_off;
	h.c471Size = sizeof(rk_boot_entry);
	h.c472Num = 1;
	h.c472Off = entry_off + 2 * sizeof(rk_boot_entry);
	h.c472Size = sizeof(rk_boot_entry);
	h.ldrNum = 3;
	h.ldrOff = entry_off + 3 * sizeof(rk_boot_entry);
	h.ldrSize = sizeof(rk_boot_entry);
	h.signFlag = 0;
	h.rc4Flag = 1;
	h.reserved[0] = 1; // NEWIDB marker (closed boot_merger sets reserved[0]=1)

	rk_boot_entry e[6];
	memset(e, 0, sizeof(e));
	struct {
		uint32_t type;
		string name; // literal label, or blob path (set_name takes the basename stem)
		uint32_t off;
		uint32_t size;
		uint32_t delay;
	} spec[6] = {
		{ 1, "UsbHead", usbhead_off, RKNS_HDR, (uint32_t)sleep471 },
		{ 1, ddr_path, ddr_off, (uint32_t)ddr_a, (uint32_t)sleep471 },
		{ 2, usb_path, usb_off, (uint32_t)usb_a, 0 },
		{ 4, "FlashHead", flashhead_off, RKNS_HDR, 0 },
		{ 4, "FlashData", fddr_off, (uint32_t)ddr_a, 0 },
		{ 4, "FlashBoot", spl_off, (uint32_t)spl_a, 0 },
	};
	for (int i = 0; i < 6; i++) {
		e[i].size = sizeof(rk_boot_entry);
		e[i].type = spec[i].type;
		set_name(e[i].name, spec[i].name);
		e[i].dataOffset = spec[i].off;
		e[i].dataSize = spec[i].size;
		e[i].dataDelay = spec[i].delay;
	}

	bytes out;
	out.reserve(sizeof(h) + sizeof(e) + usb_region.size() + flash_region.size() + 4);
	put(out, &h, sizeof(h));
	put(out, e, sizeof(e));
	put(out, usb_region.data(), usb_region.size());
	put(out, flash_region.data(), flash_region.size());
	uint32_t crc = rk_crc32(out.data(), out.size());
	put(out, &crc, sizeof(crc));

	write_file(out_path, out);
	return 0;
}
