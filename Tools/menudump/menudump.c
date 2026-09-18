/*
 * changeover-menudump — read a DVD's menu tables and button geometry and
 * write them out as JSON (docs/menu-intelligence.md §8.3).
 *
 * Copyright (C) 2026 Changeover contributors.
 * SPDX-License-Identifier: GPL-2.0-or-later
 * See COPYING next to this file.
 *
 * ---------------------------------------------------------------------------
 * WHAT IT READS, AND WHY IT NEEDS ALMOST NOTHING TO DO IT
 *
 * A DVD's menus live in two domains, and everything this tool needs for
 * tier 1 — which button jumps to which title, how many chapters the chapter
 * menu names — is in two places that are **never CSS-scrambled**:
 *
 *   1. The IFO files (VIDEO_TS.IFO, VTS_nn_0.IFO). Plain, unencrypted
 *      tables: the title table (TT_SRPT), the menu PGC unit tables
 *      (VMGM_PGCI_UT / VTSM_PGCI_UT) and each menu PGC's cell playback
 *      table, which gives the sector range of the menu's video.
 *   2. The NAV packs at the start of each of those cells' first VOBU. A NAV
 *      pack is one 2048-byte sector carrying the PCI and DSI packets, and
 *      the PCI's highlight information is the button table: up to 36
 *      buttons, each with a rectangle, its four neighbours, an auto-action
 *      flag and an 8-byte VM command. Scrambling is signalled per pack in
 *      the pack header and a NAV pack never sets it, which is why
 *      libdvdread can hand these back before it has any key — and why this
 *      tool can read them with plain POSIX file I/O.
 *
 * So the helper **links nothing**. It opens the IFO and VOB files off the
 * mounted volume and parses the bytes. That matters under this project's
 * dependency rule: nothing installable through Homebrew is bundled in the
 * app, so a helper that cannot run without a vendored library would be a
 * helper that usually cannot run.
 *
 * The one thing that genuinely needs a library is the *picture*: the MPEG-2
 * video sectors that carry the words a menu prints. Those are scrambled, and
 * decrypting them needs libdvdcss, which libdvdread wraps. That is optional
 * and it is loaded at runtime with dlopen() from the usual Homebrew
 * locations — never linked, so a host without it still gets every table and
 * every button. When it is missing the output says so by name:
 *
 *   "helper": { ..., "css": "unavailable", "missing": ["libdvdread"],
 *               "install": ["brew install libdvdread"] }
 *
 * which is the distinction the app's Settings panel needs: "this formula is
 * not installed" is a different thing from "this disc has no menus", and the
 * two must never look alike.
 *
 * NOTHING HERE IS ON THE RIP PATH. A disc that defeats every line of this
 * file still rips exactly as it does today.
 *
 * ---------------------------------------------------------------------------
 * BUILD
 *     make            (see Makefile — cc, no -l flags, no headers needed)
 *
 * USAGE
 *     changeover-menudump --disc /Volumes/BLOODSPORT --out <dir>
 *                         [--max-bytes 67108864] [--no-cells]
 *     changeover-menudump --check          dependency report only, no disc
 *     changeover-menudump --version
 *
 * EXIT STATUS
 *     0  structure.json written (with or without cells)
 *     2  bad arguments
 *     3  no readable VIDEO_TS at --disc
 *     4  could not write the output directory
 */

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MENUDUMP_VERSION "0.1.0"
#define DVD_BLOCK 2048
#define MAX_TITLE_SETS 99
#define MAX_BUTTONS 36
#define DEFAULT_MAX_BYTES (64 * 1024 * 1024)

/* ------------------------------------------------------------------ bytes */

static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

typedef struct {
    uint8_t *data;
    size_t size;
} blob_t;

static int read_file(const char *path, blob_t *out) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long size = ftell(f);
    if (size <= 0) { fclose(f); return 0; }
    rewind(f);
    uint8_t *buf = malloc((size_t)size);
    if (!buf) { fclose(f); return 0; }
    size_t got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    if (got != (size_t)size) { free(buf); return 0; }
    out->data = buf;
    out->size = (size_t)size;
    return 1;
}

/* A bounds-checked view: every table offset below comes off the disc, so an
 * authoring quirk or a damaged sector must fall out as "no menus", never as
 * a read past the end of the buffer. */
static const uint8_t *at(const blob_t *b, size_t offset, size_t need) {
    if (offset > b->size || need > b->size - offset) return NULL;
    return b->data + offset;
}

/* -------------------------------------------------------------- json out */

static FILE *out_file = NULL;

static void jprintf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(out_file, fmt, args);
    va_end(args);
}

static void jstring(const char *s) {
    fputc('"', out_file);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '"' || *p == '\\') fprintf(out_file, "\\%c", *p);
        else if (*p < 0x20) fprintf(out_file, "\\u%04x", *p);
        else fputc(*p, out_file);
    }
    fputc('"', out_file);
}

/* ------------------------------------------------------- libdvdread, late */

/* Only the block-reading API, and every pointer in it is opaque — so this
 * needs no libdvdread headers and cannot go stale against a struct layout.
 * The menu VOB domain is 2 (DVD_READ_MENU_VOBS). */
typedef void *(*dvd_open_fn)(const char *);
typedef void (*dvd_close_fn)(void *);
typedef void *(*dvd_open_file_fn)(void *, int, int);
typedef void (*dvd_close_file_fn)(void *);
typedef ssize_t (*dvd_read_blocks_fn)(void *, int, size_t, unsigned char *);
typedef ssize_t (*dvd_file_size_fn)(void *);

typedef struct {
    void *handle;
    dvd_open_fn open;
    dvd_close_fn close;
    dvd_open_file_fn open_file;
    dvd_close_file_fn close_file;
    dvd_read_blocks_fn read_blocks;
    dvd_file_size_fn file_size;
    const char *loaded_from;
} dvdread_t;

static const char *dvdread_candidates[] = {
    "/opt/homebrew/lib/libdvdread.8.dylib",
    "/opt/homebrew/lib/libdvdread.dylib",
    "/usr/local/lib/libdvdread.8.dylib",
    "/usr/local/lib/libdvdread.dylib",
    "libdvdread.8.dylib",
    "libdvdread.dylib",
    NULL,
};

static const char *dvdcss_candidates[] = {
    "/opt/homebrew/lib/libdvdcss.2.dylib",
    "/opt/homebrew/lib/libdvdcss.dylib",
    "/usr/local/lib/libdvdcss.2.dylib",
    "/usr/local/lib/libdvdcss.dylib",
    NULL,
};

static int load_dvdread(dvdread_t *lib) {
    memset(lib, 0, sizeof *lib);
    for (int i = 0; dvdread_candidates[i]; i++) {
        void *handle = dlopen(dvdread_candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (!handle) continue;
        lib->handle = handle;
        lib->loaded_from = dvdread_candidates[i];
        lib->open = (dvd_open_fn)dlsym(handle, "DVDOpen");
        lib->close = (dvd_close_fn)dlsym(handle, "DVDClose");
        lib->open_file = (dvd_open_file_fn)dlsym(handle, "DVDOpenFile");
        lib->close_file = (dvd_close_file_fn)dlsym(handle, "DVDCloseFile");
        lib->read_blocks = (dvd_read_blocks_fn)dlsym(handle, "DVDReadBlocks");
        lib->file_size = (dvd_file_size_fn)dlsym(handle, "DVDFileSize");
        if (lib->open && lib->close && lib->open_file && lib->close_file && lib->read_blocks) return 1;
        dlclose(handle);
        memset(lib, 0, sizeof *lib);
    }
    return 0;
}

static const char *find_existing(const char **candidates) {
    for (int i = 0; candidates[i]; i++) {
        if (candidates[i][0] != '/') continue;
        if (access(candidates[i], R_OK) == 0) return candidates[i];
    }
    return NULL;
}

/* --------------------------------------------------------------- buttons */

typedef struct {
    int number;
    int x_start, y_start, x_end, y_end;
    int auto_action;
    int up, down, left, right;
    uint8_t command[8];
} button_t;

/*
 * The button table inside a NAV pack.
 *
 * Sector layout, from the DVD-Video specification and libdvdread's
 * nav_types.h — every offset below is from the start of the 2048-byte
 * sector:
 *
 *   0x000  pack header      00 00 01 BA, 14 bytes
 *   0x00E  system header    00 00 01 BB, 24 bytes
 *   0x026  PCI PES          00 00 01 BF, length 0x03D4
 *   0x02C  substream id     0x00 = PCI
 *   0x02D  pci_gi           64 bytes
 *   0x06D  nsml_agli        36 bytes
 *   0x091  hli.hl_gi        22 bytes  (btn_ns at 0x0A2, btngr_ns at 0x09F)
 *   0x0A7  hli.btn_colit    24 bytes
 *   0x0BF  hli.btnit[36]    18 bytes each
 *   0x400  DSI PES          00 00 01 BF, substream 0x01
 *
 * Each 18-byte button packs its rectangle into six bytes of 10-bit fields,
 * its four neighbours into four 6-bit fields, and then carries the VM
 * command verbatim. The command is copied out byte for byte and never
 * interpreted here: decoding is VMCommand.swift's job, pinned by tests
 * against exactly these hex strings.
 */
static int parse_nav_pack(const uint8_t *sector, button_t *buttons, int *button_groups, int *forced_select) {
    if (!(sector[0] == 0x00 && sector[1] == 0x00 && sector[2] == 0x01 && sector[3] == 0xBA)) return -1;
    if (!(sector[0x26] == 0x00 && sector[0x27] == 0x00 && sector[0x28] == 0x01 && sector[0x29] == 0xBF)) return -1;
    if (sector[0x2C] != 0x00) return -1;

    const uint8_t *hl_gi = sector + 0x91;
    int groups = (hl_gi[0x0E] >> 4) & 0x03;   /* 0x09F: zero(2) btngr_ns(2) ... */
    int count = hl_gi[0x11] & 0x3F;           /* 0x0A2: zero(2) btn_ns(6)      */
    int fosl = hl_gi[0x14] & 0x3F;            /* 0x0A5: zero(2) fosl_btnn(6)   */
    if (count < 0 || count > MAX_BUTTONS) return -1;
    if (button_groups) *button_groups = groups > 0 ? groups : 1;
    if (forced_select) *forced_select = fosl;

    /* Button group 1 only (§1.2 rule 4): groups 2 and 3 are the same buttons
     * re-laid-out for widescreen and letterbox, and the count is recorded so
     * a disc whose groups differ shows up in the archive. */
    for (int i = 0; i < count; i++) {
        const uint8_t *b = sector + 0xBF + (size_t)i * 18;
        buttons[i].number = i + 1;
        buttons[i].x_start = ((b[0] & 0x3F) << 4) | (b[1] >> 4);
        buttons[i].x_end = ((b[1] & 0x03) << 8) | b[2];
        buttons[i].auto_action = (b[3] >> 6) & 0x03;
        buttons[i].y_start = ((b[3] & 0x3F) << 4) | (b[4] >> 4);
        buttons[i].y_end = ((b[4] & 0x03) << 8) | b[5];
        buttons[i].up = b[6] & 0x3F;
        buttons[i].down = b[7] & 0x3F;
        buttons[i].left = b[8] & 0x3F;
        buttons[i].right = b[9] & 0x3F;
        memcpy(buttons[i].command, b + 10, 8);
    }
    return count;
}

/* ------------------------------------------------------------------- IFOs */

typedef struct {
    int title;      /* VMG title number, 1-based  */
    int vts;
    int vts_ttn;
    int ptts;
    int angles;
} title_entry_t;

/*
 * The menu-id nibble of a PGC's entry_id. Taken from libdvdnav's vm.c
 * (DVD_MENU_Title = 2 … DVD_MENU_Part = 7), which is the authority; the
 * design note in docs/menu-intelligence.md §1.1 lists these one lower and
 * is wrong. §8.6's chapter-menu invariant depends on getting this right,
 * so it is spelled out here rather than inferred.
 */
static const char *entry_type_name(int entry_id) {
    if (!(entry_id & 0x80)) return "none";
    switch (entry_id & 0x0F) {
        case 2: return "title";
        case 3: return "root";
        case 4: return "subpicture";
        case 5: return "audio";
        case 6: return "angle";
        case 7: return "chapter";
        default: return "none";
    }
}

static void frame_size(const uint8_t *video_attr, int *width, int *height, const char **standard) {
    int format = (video_attr[0] >> 4) & 0x03;   /* 0 = NTSC, 1 = PAL */
    int picture = (video_attr[1] >> 2) & 0x03;
    int base = (format == 1) ? 576 : 480;
    *standard = (format == 1) ? "PAL" : "NTSC";
    switch (picture) {
        case 0: *width = 720; *height = base; break;
        case 1: *width = 704; *height = base; break;
        case 2: *width = 352; *height = base; break;
        default: *width = 352; *height = base / 2; break;
    }
}

/* ------------------------------------------------------------------ paths */

static int path_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

/* macOS mounts a DVD's UDF volume with upper-case names, but a folder copied
 * off one can be either; try both rather than failing on a capture the user
 * made by hand. */
static int resolve_video_ts(const char *disc, char *out, size_t out_size) {
    const char *shapes[] = { "%s/VIDEO_TS", "%s/video_ts", "%s", NULL };
    for (int i = 0; shapes[i]; i++) {
        snprintf(out, out_size, shapes[i], disc);
        char probe[2048];
        snprintf(probe, sizeof probe, "%s/VIDEO_TS.IFO", out);
        if (path_exists(probe)) return 1;
        snprintf(probe, sizeof probe, "%s/video_ts.ifo", out);
        if (path_exists(probe)) return 1;
    }
    return 0;
}

static int open_ifo(const char *video_ts, int title_set, blob_t *blob) {
    char path[2048];
    if (title_set == 0) {
        snprintf(path, sizeof path, "%s/VIDEO_TS.IFO", video_ts);
        if (read_file(path, blob)) return 1;
        snprintf(path, sizeof path, "%s/video_ts.ifo", video_ts);
        return read_file(path, blob);
    }
    snprintf(path, sizeof path, "%s/VTS_%02d_0.IFO", video_ts, title_set);
    if (read_file(path, blob)) return 1;
    snprintf(path, sizeof path, "%s/vts_%02d_0.ifo", video_ts, title_set);
    return read_file(path, blob);
}

static int open_menu_vob(const char *video_ts, int title_set, FILE **out) {
    char path[2048];
    if (title_set == 0) {
        snprintf(path, sizeof path, "%s/VIDEO_TS.VOB", video_ts);
        *out = fopen(path, "rb");
        if (*out) return 1;
        snprintf(path, sizeof path, "%s/video_ts.vob", video_ts);
        *out = fopen(path, "rb");
        return *out != NULL;
    }
    snprintf(path, sizeof path, "%s/VTS_%02d_0.VOB", video_ts, title_set);
    *out = fopen(path, "rb");
    if (*out) return 1;
    snprintf(path, sizeof path, "%s/vts_%02d_0.vob", video_ts, title_set);
    *out = fopen(path, "rb");
    return *out != NULL;
}

/* ------------------------------------------------------------------- main */

typedef struct {
    const char *disc;
    const char *out_dir;
    long max_bytes;
    int dump_cells;
    int check_only;
} options_t;

static void usage(void) {
    fprintf(stderr,
            "changeover-menudump " MENUDUMP_VERSION "\n"
            "usage: changeover-menudump --disc <path> --out <dir> [--max-bytes N] [--no-cells]\n"
            "       changeover-menudump --check\n"
            "       changeover-menudump --version\n");
}

/* The dependency report, on its own, in the same shape the structure.json
 * "helper" block carries — so the app can read one schema whether it ran a
 * disc or only asked what is installed. */
static void print_dependency_report(FILE *f, const dvdread_t *lib, const char *css_path) {
    fprintf(f, "{\n  \"format\": \"changeover-menu-dependencies/1\",\n");
    fprintf(f, "  \"helper\": { \"name\": \"changeover-menudump\", \"version\": \"" MENUDUMP_VERSION "\" },\n");
    fprintf(f, "  \"libdvdread\": { \"status\": \"%s\", \"path\": ", lib->handle ? "available" : "missing");
    if (lib->loaded_from) fprintf(f, "\"%s\"", lib->loaded_from); else fprintf(f, "null");
    fprintf(f, ", \"formula\": \"libdvdread\", \"install\": \"brew install libdvdread\" },\n");
    fprintf(f, "  \"libdvdcss\": { \"status\": \"%s\", \"path\": ", css_path ? "available" : "missing");
    if (css_path) fprintf(f, "\"%s\"", css_path); else fprintf(f, "null");
    fprintf(f, ", \"formula\": \"libdvdcss\", \"install\": \"brew install libdvdcss\" },\n");
    fprintf(f, "  \"tier1\": { \"status\": \"available\", \"note\": \"IFO tables and NAV packs are never scrambled; buttons and targets need no library\" }\n}\n");
}

int main(int argc, char **argv) {
    options_t options = { NULL, NULL, DEFAULT_MAX_BYTES, 1, 0 };

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--version")) { printf("changeover-menudump %s\n", MENUDUMP_VERSION); return 0; }
        else if (!strcmp(argv[i], "--check")) options.check_only = 1;
        else if (!strcmp(argv[i], "--no-cells")) options.dump_cells = 0;
        else if (!strcmp(argv[i], "--disc") && i + 1 < argc) options.disc = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) options.out_dir = argv[++i];
        else if (!strcmp(argv[i], "--max-bytes") && i + 1 < argc) options.max_bytes = atol(argv[++i]);
        else { usage(); return 2; }
    }

    dvdread_t lib;
    int have_dvdread = load_dvdread(&lib);
    const char *css_path = find_existing(dvdcss_candidates);

    if (options.check_only) {
        print_dependency_report(stdout, &lib, css_path);
        return 0;
    }
    if (!options.disc || !options.out_dir) { usage(); return 2; }

    char video_ts[2048];
    if (!resolve_video_ts(options.disc, video_ts, sizeof video_ts)) {
        fprintf(stderr, "menudump: no readable VIDEO_TS under %s\n", options.disc);
        fprintf(stdout, "{\"format\":\"changeover-menu-structure/1\",\"error\":\"noVideoTS\",\"disc\":");
        out_file = stdout; jstring(options.disc); fputc('}', stdout); fputc('\n', stdout);
        return 3;
    }

    mkdir(options.out_dir, 0755);
    char cells_dir[2048];
    snprintf(cells_dir, sizeof cells_dir, "%s/cells", options.out_dir);
    if (options.dump_cells && have_dvdread) mkdir(cells_dir, 0755);

    char structure_path[2048];
    snprintf(structure_path, sizeof structure_path, "%s/structure.json", options.out_dir);
    out_file = fopen(structure_path, "w");
    if (!out_file) {
        fprintf(stderr, "menudump: cannot write %s: %s\n", structure_path, strerror(errno));
        return 4;
    }

    blob_t vmgi = { NULL, 0 };
    if (!open_ifo(video_ts, 0, &vmgi)) {
        fprintf(stderr, "menudump: cannot read VIDEO_TS.IFO\n");
        fclose(out_file);
        return 3;
    }

    int title_sets = 0;
    uint32_t tt_srpt_sector = 0, vmgm_pgci_ut_sector = 0;
    int frame_w = 720, frame_h = 480;
    const char *standard = "NTSC";
    if (vmgi.size >= 0x102 && memcmp(vmgi.data, "DVDVIDEO-VMG", 12) == 0) {
        title_sets = be16(vmgi.data + 0x3E);
        tt_srpt_sector = be32(vmgi.data + 0xC4);
        vmgm_pgci_ut_sector = be32(vmgi.data + 0xC8);
        frame_size(vmgi.data + 0x100, &frame_w, &frame_h, &standard);
    }
    if (title_sets > MAX_TITLE_SETS) title_sets = MAX_TITLE_SETS;

    /* The title table — what makes a JumpTT number mean HandBrake's title. */
    title_entry_t titles[256];
    int title_count = 0;
    if (tt_srpt_sector) {
        const uint8_t *tt = at(&vmgi, (size_t)tt_srpt_sector * DVD_BLOCK, 8);
        if (tt) {
            int n = be16(tt);
            if (n > 256) n = 256;
            for (int i = 0; i < n; i++) {
                const uint8_t *e = at(&vmgi, (size_t)tt_srpt_sector * DVD_BLOCK + 8 + (size_t)i * 12, 12);
                if (!e) break;
                titles[title_count].title = i + 1;
                titles[title_count].angles = e[1];
                titles[title_count].ptts = be16(e + 2);
                titles[title_count].vts = e[6];
                titles[title_count].vts_ttn = e[7];
                title_count++;
            }
        }
    }

    long bytes_used = 0;

    jprintf("{\n");
    jprintf("  \"format\": \"changeover-menu-structure/1\",\n");
    jprintf("  \"helper\": { \"name\": \"changeover-menudump\", \"version\": \"%s\", \"css\": \"%s\"",
            MENUDUMP_VERSION, (have_dvdread && css_path) ? "available" : "unavailable");
    jprintf(", \"libdvdread\": \"%s\"", have_dvdread ? "available" : "missing");
    jprintf(", \"missing\": [");
    {
        int wrote = 0;
        if (!have_dvdread) { jprintf("\"libdvdread\""); wrote = 1; }
        if (!css_path) { if (wrote) jprintf(", "); jprintf("\"libdvdcss\""); wrote = 1; }
        (void)wrote;
    }
    jprintf("], \"install\": [");
    {
        int wrote = 0;
        if (!have_dvdread) { jprintf("\"brew install libdvdread\""); wrote = 1; }
        if (!css_path) { if (wrote) jprintf(", "); jprintf("\"brew install libdvdcss\""); }
    }
    jprintf("] },\n");
    jprintf("  \"frame\": { \"width\": %d, \"height\": %d, \"standard\": \"%s\" },\n", frame_w, frame_h, standard);

    jprintf("  \"titles\": [");
    for (int i = 0; i < title_count; i++) {
        jprintf("%s\n    { \"title\": %d, \"vts\": %d, \"vtsTTN\": %d, \"ptts\": %d, \"angles\": %d }",
                i ? "," : "", titles[i].title, titles[i].vts, titles[i].vts_ttn, titles[i].ptts, titles[i].angles);
    }
    jprintf("%s],\n", title_count ? "\n  " : "");

    jprintf("  \"menus\": [");
    int menu_index = 0;

    /* One pass over the VMGM domain and each VTSM domain. Both have the same
     * shape — a PGCI_UT of language units, each holding menu PGCs — so the
     * body below runs once per domain with the sector offsets swapped. */
    for (int ts = 0; ts <= title_sets; ts++) {
        blob_t ifo = { NULL, 0 };
        uint32_t pgci_ut_sector = 0;
        const char *domain = "VMGM";

        if (ts == 0) {
            ifo = vmgi;
            pgci_ut_sector = vmgm_pgci_ut_sector;
        } else {
            if (!open_ifo(video_ts, ts, &ifo)) continue;
            domain = "VTSM";
            if (ifo.size >= 0xD4 && memcmp(ifo.data, "DVDVIDEO-VTS", 12) == 0) {
                pgci_ut_sector = be32(ifo.data + 0xD0);
            }
        }
        if (!pgci_ut_sector) { if (ts != 0) free(ifo.data); continue; }

        size_t ut_base = (size_t)pgci_ut_sector * DVD_BLOCK;
        const uint8_t *ut = at(&ifo, ut_base, 8);
        if (!ut) { if (ts != 0) free(ifo.data); continue; }
        int lu_count = be16(ut);

        FILE *vob = NULL;
        int have_vob = open_menu_vob(video_ts, ts, &vob);

        void *dvd = NULL, *dvd_file = NULL;
        if (options.dump_cells && have_dvdread) {
            dvd = lib.open(options.disc);
            if (dvd) dvd_file = lib.open_file(dvd, ts, 2 /* DVD_READ_MENU_VOBS */);
        }

        for (int lu = 0; lu < lu_count; lu++) {
            const uint8_t *lu_entry = at(&ifo, ut_base + 8 + (size_t)lu * 8, 8);
            if (!lu_entry) break;
            uint16_t lang = be16(lu_entry);
            uint32_t pgcit_offset = be32(lu_entry + 4);
            size_t pgcit_base = ut_base + pgcit_offset;
            const uint8_t *pgcit = at(&ifo, pgcit_base, 8);
            if (!pgcit) continue;
            int pgc_count = be16(pgcit);

            for (int p = 0; p < pgc_count; p++) {
                const uint8_t *srp = at(&ifo, pgcit_base + 8 + (size_t)p * 8, 8);
                if (!srp) break;
                int entry_id = srp[0];
                uint32_t pgc_offset = be32(srp + 4);
                const uint8_t *pgc = at(&ifo, pgcit_base + pgc_offset, 0xEC);
                if (!pgc) continue;

                int cell_count = pgc[3];
                uint16_t cell_playback_offset = be16(pgc + 0xE8);
                const uint8_t *cells = cell_playback_offset
                    ? at(&ifo, pgcit_base + pgc_offset + cell_playback_offset, (size_t)cell_count * 24)
                    : NULL;

                char id[128];
                if (ts == 0) snprintf(id, sizeof id, "vmgm-lu%d-pgc%d", lu + 1, p + 1);
                else snprintf(id, sizeof id, "vtsm-%02d-lu%d-pgc%d", ts, lu + 1, p + 1);

                button_t buttons[MAX_BUTTONS];
                memset(buttons, 0, sizeof buttons);
                int button_count = -1, button_groups = 1, forced_select = 0;

                uint32_t first_sector = 0, last_sector = 0;
                if (cells && cell_count > 0) {
                    first_sector = be32(cells + 0x08);
                    last_sector = be32(cells + 0x14);
                    if (have_vob) {
                        uint8_t sector[DVD_BLOCK];
                        if (fseek(vob, (long)first_sector * DVD_BLOCK, SEEK_SET) == 0
                            && fread(sector, 1, DVD_BLOCK, vob) == DVD_BLOCK) {
                            button_count = parse_nav_pack(sector, buttons, &button_groups, &forced_select);
                        }
                    }
                }

                int dumped_cell = 0;
                if (dvd_file && cells && cell_count > 0 && last_sector >= first_sector) {
                    long want = ((long)last_sector - (long)first_sector + 1) * DVD_BLOCK;
                    if (bytes_used + want <= options.max_bytes) {
                        char cell_path[2200];
                        snprintf(cell_path, sizeof cell_path, "%s/%s.vob", cells_dir, id);
                        FILE *cf = fopen(cell_path, "wb");
                        if (cf) {
                            unsigned char *buf = malloc(DVD_BLOCK * 256);
                            long done = 0, total = (long)last_sector - (long)first_sector + 1;
                            while (buf && done < total) {
                                int chunk = (total - done) > 256 ? 256 : (int)(total - done);
                                ssize_t got = lib.read_blocks(dvd_file, (int)(first_sector + done), (size_t)chunk, buf);
                                if (got <= 0) break;
                                fwrite(buf, DVD_BLOCK, (size_t)got, cf);
                                done += got;
                            }
                            free(buf);
                            fclose(cf);
                            if (done > 0) { dumped_cell = 1; bytes_used += done * DVD_BLOCK; }
                            else unlink(cell_path);
                        }
                    }
                }

                jprintf("%s\n    {\n", menu_index ? "," : "");
                jprintf("      \"id\": "); jstring(id); jprintf(",\n");
                jprintf("      \"domain\": \"%s\",", domain);
                if (ts == 0) jprintf(" \"vts\": null,"); else jprintf(" \"vts\": %d,", ts);
                jprintf(" \"languageUnit\": %d,", lu + 1);
                if (lang >> 8 >= 'a' && (lang & 0xFF) >= 'a')
                    jprintf(" \"languageCode\": \"%c%c\",", lang >> 8, lang & 0xFF);
                else
                    jprintf(" \"languageCode\": null,");
                jprintf(" \"pgc\": %d,\n", p + 1);
                jprintf("      \"entryType\": \"%s\",\n", entry_type_name(entry_id));
                jprintf("      \"cells\": [");
                for (int c = 0; c < cell_count && cells; c++) {
                    const uint8_t *cell = cells + (size_t)c * 24;
                    jprintf("%s{ \"firstSector\": %u, \"lastSector\": %u, \"durationMS\": null }",
                            c ? ", " : "", be32(cell + 0x08), be32(cell + 0x14));
                }
                jprintf("],\n");
                jprintf("      \"reachableFrom\": [\"%s\"],\n", (entry_id & 0x80) ? "entry" : "link");
                jprintf("      \"buttonGroups\": %d,\n", button_groups);
                if (button_count >= 0)
                    jprintf("      \"highlight\": { \"start\": null, \"buttons\": %d, \"forcedSelect\": %d },\n",
                            button_count, forced_select);
                else
                    jprintf("      \"highlight\": null,\n");
                jprintf("      \"buttons\": [");
                for (int b = 0; b < button_count; b++) {
                    jprintf("%s\n        { \"number\": %d, \"rect\": [%d, %d, %d, %d], \"autoAction\": %s, \"command\": \"",
                            b ? "," : "", buttons[b].number,
                            buttons[b].x_start, buttons[b].y_start, buttons[b].x_end, buttons[b].y_end,
                            buttons[b].auto_action ? "true" : "false");
                    for (int k = 0; k < 8; k++) jprintf("%02x", buttons[b].command[k]);
                    jprintf("\", \"up\": %d, \"down\": %d, \"left\": %d, \"right\": %d }",
                            buttons[b].up, buttons[b].down, buttons[b].left, buttons[b].right);
                }
                jprintf("%s],\n", button_count > 0 ? "\n      " : "");
                jprintf("      \"stills\": [");
                if (dumped_cell) { jstring(id); }
                jprintf("],\n");
                jprintf("      \"truncated\": %s\n", (bytes_used >= options.max_bytes) ? "true" : "false");
                jprintf("    }");
                menu_index++;
            }
        }

        if (dvd_file) lib.close_file(dvd_file);
        if (dvd) lib.close(dvd);
        if (vob) fclose(vob);
        if (ts != 0) free(ifo.data);
    }

    jprintf("%s]\n}\n", menu_index ? "\n  " : "");
    fclose(out_file);
    free(vmgi.data);

    fprintf(stderr, "menudump: %d menu PGCs, %ld bytes of menu video, libdvdread %s, libdvdcss %s\n",
            menu_index, bytes_used,
            have_dvdread ? "available" : "MISSING (brew install libdvdread)",
            css_path ? "available" : "MISSING (brew install libdvdcss)");
    if (lib.handle) dlclose(lib.handle);
    return 0;
}
