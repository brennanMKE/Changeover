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
 * TWO THINGS THAT WERE WRONG HERE, BOTH FOUND ON A REAL DISC (Bloodsport,
 * 2026-09-18). The first version of this function read 29 menu PGCs and
 * zero buttons off a disc whose menus carry 151 NAV packs, every one of
 * them with buttons. Read this before touching any offset below.
 *
 *  1. `pci_gi` is **60 bytes, not 64**. Its fields are
 *     nv_pck_lbn(4) vobu_cat(2) zero1(2) vobu_uop_ctl(4) vobu_s_ptm(4)
 *     vobu_e_ptm(4) vobu_se_e_ptm(4) e_eltm(4) vobu_isrc(32) = 60.
 *     A four-byte slip put every highlight field inside the next
 *     structure: `btn_ns` was read from `foac_btnn` (0 on most discs, so
 *     the answer was a confident, plausible "this menu has no buttons")
 *     and `fosl_btnn` was read out of the colour table. The sizes are
 *     named constants below, derived from the field list, so the
 *     arithmetic has to be confronted rather than re-guessed.
 *
 *  2. The PCI packet is **not at a fixed offset**. The pack header can
 *     carry stuffing bytes and the system header is optional, so the
 *     packet is located by scanning for its start code — `00 00 01 BF`
 *     with substream id 0x00 at +6 — rather than by assuming 0x026.
 *     (0x026 happens to be right on this disc; it is not a rule.)
 *
 * Sector layout, from the DVD-Video specification and libdvdread's
 * nav_types.h. Offsets are shown for the common case where the PCI packet
 * sits at 0x026, but only the *relative* ones are relied on:
 *
 *   0x000  pack header      00 00 01 BA, 14 bytes (+ stuffing)
 *   0x00E  system header    00 00 01 BB, 24 bytes (optional)
 *   0x026  PCI PES          00 00 01 BF          <- located by start code
 *   +4     PES length       2 bytes
 *   +6     substream id     0x00 = PCI, 0x01 = DSI
 *   +7     pci_gi           60 bytes             <- PCI data starts here
 *   +67    nsml_agli        36 bytes
 *   +103   hli.hl_gi        22 bytes
 *   +125   hli.btn_colit    24 bytes
 *   +149   hli.btnit[]      18 bytes each
 *
 * Each 18-byte button packs its rectangle into six bytes of 10-bit fields,
 * its four neighbours into four 6-bit fields, and then carries the VM
 * command verbatim. The command is copied out byte for byte and never
 * interpreted here: decoding is VMCommand.swift's job, pinned by tests
 * against exactly these hex strings.
 *
 * BUTTON GROUPS. `btngr_ns` is 1..3 and `btn_ns` is the count per group,
 * but the groups are **not** packed consecutively: the button table is
 * always 36 entries and the declared groups partition it equally, so group
 * g starts at index (g-1) * (36 / btngr_ns) — index 18 for the second of
 * two, not index btn_ns. This was measured on Bloodsport, which declares
 * two groups of 4 on its root menu: entries 0-3 and 18-21 carry data and
 * 4-17 are zeros. Reading at the btn_ns stride finds those zeros and
 * reports "the groups disagree", which is how the wrong stride announces
 * itself if this is ever changed back. The groups are
 * the same buttons laid out for different display aspects (4:3, wide,
 * letterbox — `btngr<n>_dsp_ty`), and they carry the *same commands*, so
 * tier 1 cannot be affected by the choice. Group 1 is taken, because the
 * still is rendered from the stored frame and group 1's rectangles are in
 * that same stored space; every group's display type is recorded, and so
 * is whether the groups' commands actually agree — a disc where they do
 * not is visible in the archive instead of being silently halved.
 */

/* Sizes, from the field lists above. Not to be inlined as literals. */
#define PCI_GI_SIZE 60
#define NSML_AGLI_SIZE 36
#define HL_GI_SIZE 22
#define BTN_COLIT_SIZE 24
#define BTNI_SIZE 18
#define HLI_FROM_PCI_DATA (PCI_GI_SIZE + NSML_AGLI_SIZE)
#define BTNIT_FROM_HLI (HL_GI_SIZE + BTN_COLIT_SIZE)

typedef struct {
    int found;
    int pci_offset;          /* where the 00 00 01 BF start code was found */
    uint32_t lbn;            /* pci_gi.nv_pck_lbn — the pack's own address */
    int button_groups;       /* hl_gi.btngr_ns, 1..3                       */
    int buttons_per_group;   /* hl_gi.btn_ns                               */
    int forced_select;
    int group_display[3];
    int groups_agree;        /* every group's commands match group 1's     */
    int rects_inside_frame;
    int count;
    button_t buttons[MAX_BUTTONS];
    const char *error;
} nav_t;

static void unpack_button(const uint8_t *b, int number, button_t *out) {
    out->number = number;
    out->x_start = ((b[0] & 0x3F) << 4) | (b[1] >> 4);
    out->x_end = ((b[1] & 0x03) << 8) | b[2];
    out->auto_action = (b[3] >> 6) & 0x03;
    out->y_start = ((b[3] & 0x3F) << 4) | (b[4] >> 4);
    out->y_end = ((b[4] & 0x03) << 8) | b[5];
    out->up = b[6] & 0x3F;
    out->down = b[7] & 0x3F;
    out->left = b[8] & 0x3F;
    out->right = b[9] & 0x3F;
    memcpy(out->command, b + 10, 8);
}

/* The PCI packet's start code, anywhere in the first pack of the sector.
 * The DSI packet shares the 00 00 01 BF start code and is told apart by
 * its substream id, so the id is part of the match rather than a check
 * made afterwards. */
static int find_pci_offset(const uint8_t *sector) {
    for (int offset = 0; offset + 8 < 1024; offset++) {
        if (sector[offset] == 0x00 && sector[offset + 1] == 0x00
            && sector[offset + 2] == 0x01 && sector[offset + 3] == 0xBF
            && sector[offset + 6] == 0x00) {
            return offset;
        }
    }
    return -1;
}

static void parse_nav_pack(const uint8_t *sector, int frame_w, int frame_h, nav_t *nav) {
    memset(nav, 0, sizeof *nav);
    nav->button_groups = 1;
    nav->groups_agree = 1;
    nav->rects_inside_frame = 1;

    if (!(sector[0] == 0x00 && sector[1] == 0x00 && sector[2] == 0x01 && sector[3] == 0xBA)) {
        nav->error = "not a pack (no 00 00 01 BA)";
        return;
    }
    int pci_offset = find_pci_offset(sector);
    if (pci_offset < 0) {
        nav->error = "no PCI packet (no 00 00 01 BF with substream 0)";
        return;
    }
    nav->found = 1;
    nav->pci_offset = pci_offset;

    const uint8_t *pci = sector + pci_offset + 7;
    nav->lbn = be32(pci);

    const uint8_t *hl_gi = pci + HLI_FROM_PCI_DATA;
    int groups = (hl_gi[0x0E] >> 4) & 0x03;   /* zero(2) btngr_ns(2) zero(1) btngr1_dsp_ty(3) */
    int count = hl_gi[0x11] & 0x3F;           /* zero(2) btn_ns(6)                            */
    nav->forced_select = hl_gi[0x14] & 0x3F;  /* zero(2) fosl_btnn(6)                         */
    nav->group_display[0] = hl_gi[0x0E] & 0x07;
    nav->group_display[1] = (hl_gi[0x0F] >> 4) & 0x07;
    nav->group_display[2] = hl_gi[0x0F] & 0x07;
    nav->button_groups = groups > 0 ? groups : 1;
    nav->buttons_per_group = count;

    if (count == 0) return;                   /* a menu PGC with no highlight yet */
    if (count > MAX_BUTTONS || count > MAX_BUTTONS / nav->button_groups) {
        nav->error = "implausible button count — the highlight offsets do not fit";
        nav->buttons_per_group = 0;
        return;
    }

    const uint8_t *btnit = hl_gi + BTNIT_FROM_HLI;
    for (int i = 0; i < count; i++) {
        unpack_button(btnit + (size_t)i * BTNI_SIZE, i + 1, &nav->buttons[i]);
        button_t *b = &nav->buttons[i];
        if (b->x_end <= b->x_start || b->y_end <= b->y_start
            || b->x_end > frame_w || b->y_end > frame_h) {
            nav->rects_inside_frame = 0;
        }
    }
    nav->count = count;

    /* Do the other groups really carry the same commands? On Bloodsport
     * they do — identical commands, wider rectangles for the letterbox
     * layout — which is what makes taking group 1 safe for tier 1. If a
     * disc ever disagrees, the archive says so instead of silently
     * choosing. */
    int group_stride = MAX_BUTTONS / nav->button_groups;
    for (int g = 1; g < nav->button_groups; g++) {
        for (int i = 0; i < count; i++) {
            int index = g * group_stride + i;
            if (index >= MAX_BUTTONS) break;
            const uint8_t *other = btnit + (size_t)index * BTNI_SIZE;
            if (memcmp(other + 10, nav->buttons[i].command, 8) != 0) nav->groups_agree = 0;
        }
    }
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

/* One cell's button table.
 *
 * Split out of the PGC loop because a menu's pages are its cells: a
 * multi-page scene index is one PGC, and reading only cell 0 sees page 1 and
 * calls it the whole menu. Every caller gets the same bounded walk — the
 * first VOBU of a cell starts with a NAV pack and a still menu repeats its
 * button table in every one, but a motion menu whose highlight starts later
 * has an empty table until it does, so keep looking a bounded way in rather
 * than reporting "no buttons", which is the one answer a reader must never
 * give when it simply has not looked yet. */
static void scan_cell_nav(FILE *vob, uint32_t first_sector, uint32_t last_sector,
                          int frame_w, int frame_h, nav_t *out_nav,
                          uint32_t *out_sector, int *out_lbn_matches,
                          const char **out_error) {
    memset(out_nav, 0, sizeof *out_nav);
    out_nav->button_groups = 1;      /* the defaults a menu with no */
    out_nav->groups_agree = 1;       /* readable NAV pack reports,  */
    out_nav->rects_inside_frame = 1; /* so "unknown" never reads as a failed check */
    *out_sector = 0;
    *out_lbn_matches = 0;
    *out_error = "no NAV pack with buttons in the cell";

    uint32_t limit = last_sector >= first_sector ? last_sector : first_sector;
    if (limit > first_sector + 64) limit = first_sector + 64;
    for (uint32_t s = first_sector; s <= limit; s++) {
        uint8_t sector[DVD_BLOCK];
        if (fseek(vob, (long)s * DVD_BLOCK, SEEK_SET) != 0) {
            *out_error = "seek past the end of the menu VOB";
            break;
        }
        if (fread(sector, 1, DVD_BLOCK, vob) != DVD_BLOCK) {
            *out_error = "short read from the menu VOB";
            break;
        }
        nav_t candidate;
        parse_nav_pack(sector, frame_w, frame_h, &candidate);
        if (!candidate.found) continue;
        *out_nav = candidate;
        *out_sector = s;
        *out_lbn_matches = (candidate.lbn == s);
        if (candidate.count > 0) { *out_error = candidate.error; break; }
    }
}

/* The button array, as JSON. Shared by a menu's legacy top-level "buttons"
 * (cell 0, so nothing that already reads this file has to change) and by each
 * entry of "pages". */
static void emit_buttons(const nav_t *nav) {
    for (int b = 0; b < nav->count; b++) {
        jprintf("%s\n        { \"number\": %d, \"rect\": [%d, %d, %d, %d], \"autoAction\": %s, \"command\": \"",
                b ? "," : "", nav->buttons[b].number,
                nav->buttons[b].x_start, nav->buttons[b].y_start,
                nav->buttons[b].x_end, nav->buttons[b].y_end,
                nav->buttons[b].auto_action ? "true" : "false");
        for (int k = 0; k < 8; k++) jprintf("%02x", nav->buttons[b].command[k]);
        jprintf("\", \"up\": %d, \"down\": %d, \"left\": %d, \"right\": %d }",
                nav->buttons[b].up, nav->buttons[b].down, nav->buttons[b].left, nav->buttons[b].right);
    }
}

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

                nav_t nav;
                memset(&nav, 0, sizeof nav);
                nav.button_groups = 1;
                nav.groups_agree = 1;
                nav.rects_inside_frame = 1;
                const char *nav_error = "no cell to read";
                uint32_t nav_sector = 0;
                int nav_lbn_matches = 0;

                uint32_t first_sector = 0, last_sector = 0;
                if (cells && cell_count > 0) {
                    first_sector = be32(cells + 0x08);
                    last_sector = be32(cells + 0x14);
                    if (!have_vob) {
                        nav_error = "could not open the menu VOB";
                    } else {
                        scan_cell_nav(vob, first_sector, last_sector, frame_w, frame_h,
                                      &nav, &nav_sector, &nav_lbn_matches, &nav_error);
                    }
                }

                /* Every cell, not just the first. A multi-page scene menu is
                 * one PGC whose pages are its successive cells — Oppenheimer's
                 * CHAPTERS menu is pgc19 with five cells, one per page of four
                 * scenes, and the "5-8"…"17-20" buttons are PGCs with no cells
                 * of their own that set a register and link back into it. So a
                 * reader that stops at cell 0 sees page 1 and concludes the
                 * disc offers four scenes. Dumping every cell is what lets the
                 * later stages see all twenty.
                 *
                 * Cell 0 keeps the plain `<id>.vob` name so nothing that
                 * already reads these files has to learn a new one; the rest
                 * are `<id>-cell2.vob` upward, numbered as a viewer would
                 * count pages. */
                unsigned char dumped[256];
                memset(dumped, 0, sizeof dumped);
                int dumped_cell = 0;
                for (int c = 0; c < cell_count && c < 256 && dvd_file && cells; c++) {
                    const uint8_t *cell = cells + (size_t)c * 24;
                    uint32_t cell_first = be32(cell + 0x08), cell_last = be32(cell + 0x14);
                    if (cell_last < cell_first) continue;

                    long want = ((long)cell_last - (long)cell_first + 1) * DVD_BLOCK;
                    if (bytes_used + want > options.max_bytes) break;

                    char cell_path[2200];
                    if (c == 0) snprintf(cell_path, sizeof cell_path, "%s/%s.vob", cells_dir, id);
                    else snprintf(cell_path, sizeof cell_path, "%s/%s-cell%d.vob", cells_dir, id, c + 1);
                    FILE *cf = fopen(cell_path, "wb");
                    if (!cf) continue;

                    unsigned char *buf = malloc(DVD_BLOCK * 256);
                    long done = 0, total = (long)cell_last - (long)cell_first + 1;
                    while (buf && done < total) {
                        int chunk = (total - done) > 256 ? 256 : (int)(total - done);
                        ssize_t got = lib.read_blocks(dvd_file, (int)(cell_first + done), (size_t)chunk, buf);
                        if (got <= 0) break;
                        fwrite(buf, DVD_BLOCK, (size_t)got, cf);
                        done += got;
                    }
                    free(buf);
                    fclose(cf);
                    if (done > 0) { dumped[c] = 1; dumped_cell = 1; bytes_used += done * DVD_BLOCK; }
                    else unlink(cell_path);
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

                /* The PGC's own command table. Bloodsport's Play Movie
                 * button is a LinkTailPGC — "run this PGC's post-commands" —
                 * and those end with JumpVTS_TT 1. Without this table the
                 * button resolves to nothing and the disc's own answer to
                 * "which title is the feature" is unreadable, which is
                 * exactly what happened the first time it was left out.
                 * Emitted verbatim; §4.1 follows exactly one indirection
                 * and never emulates the VM. */
                {
                    uint16_t cto = be16(pgc + 0xE4);
                    const uint8_t *ct = cto ? at(&ifo, pgcit_base + pgc_offset + cto, 8) : NULL;
                    int npre = 0, npost = 0, ncell = 0;
                    if (ct) { npre = be16(ct); npost = be16(ct + 2); ncell = be16(ct + 4); }
                    if (ct && !at(&ifo, pgcit_base + pgc_offset + cto + 8,
                                  (size_t)(npre + npost + ncell) * 8)) ct = NULL;
                    jprintf("      \"commands\": ");
                    if (!ct) {
                        jprintf("null,\n");
                    } else {
                        const uint8_t *c = ct + 8;
                        const char *names[3] = { "pre", "post", "cell" };
                        int counts[3] = { npre, npost, ncell };
                        jprintf("{ ");
                        for (int part = 0; part < 3; part++) {
                            jprintf("%s\"%s\": [", part ? ", " : "", names[part]);
                            for (int k = 0; k < counts[part]; k++) {
                                jprintf("%s\"", k ? ", " : "");
                                for (int byte = 0; byte < 8; byte++) jprintf("%02x", c[byte]);
                                jprintf("\"");
                                c += 8;
                            }
                            jprintf("]");
                        }
                        jprintf(" },\n");
                    }
                }
                jprintf("      \"reachableFrom\": [\"%s\"],\n", (entry_id & 0x80) ? "entry" : "link");
                jprintf("      \"buttonGroups\": %d,\n", nav.button_groups);
                /* Why there are no buttons is as much a finding as the
                 * buttons are. The first version of this tool reported an
                 * empty array for every menu on a disc full of them and
                 * said nothing about why, so every absence now names its
                 * own cause and the reader's self-checks are published
                 * alongside the data they validate. */
                jprintf("      \"nav\": { \"sector\": %u, \"pciOffset\": %d, \"lbn\": %u, \"lbnMatches\": %s,"
                        " \"buttonsPerGroup\": %d, \"groupDisplayTypes\": [%d, %d, %d], \"groupsAgree\": %s,"
                        " \"rectsInsideFrame\": %s, \"error\": ",
                        nav_sector, nav.found ? nav.pci_offset : -1, nav.lbn,
                        nav_lbn_matches ? "true" : "false",
                        nav.buttons_per_group,
                        nav.group_display[0], nav.group_display[1], nav.group_display[2],
                        nav.groups_agree ? "true" : "false",
                        nav.rects_inside_frame ? "true" : "false");
                if (nav.count > 0 && !nav.error) jprintf("null");
                else jstring(nav.error ? nav.error : nav_error);
                jprintf(" },\n");
                if (nav.found)
                    jprintf("      \"highlight\": { \"start\": null, \"buttons\": %d, \"forcedSelect\": %d },\n",
                            nav.count, nav.forced_select);
                else
                    jprintf("      \"highlight\": null,\n");
                jprintf("      \"buttons\": [");
                emit_buttons(&nav);
                jprintf("%s],\n", nav.count > 0 ? "\n      " : "");
                jprintf("      \"stills\": [");
                if (dumped_cell) {
                    int emitted = 0;
                    for (int c = 0; c < cell_count && c < 256; c++) {
                        if (!dumped[c]) continue;
                        char still_id[2200];
                        if (c == 0) snprintf(still_id, sizeof still_id, "%s", id);
                        else snprintf(still_id, sizeof still_id, "%s-cell%d", id, c + 1);
                        if (emitted++) jprintf(", ");
                        jstring(still_id);
                    }
                }
                jprintf("],\n");

                /* One entry per cell, each naming the still it was rendered
                 * to and carrying that cell's own buttons.
                 *
                 * A scene index spreads its chapters over pages, and the
                 * pages are cells of a single PGC — Oppenheimer's CHAPTERS
                 * menu is pgc19 with five of them. The top-level "buttons"
                 * above is cell 0, which is page 1 and nothing else, so a
                 * consumer that reads only that sees four scenes on a disc
                 * offering twenty, then throws the set away for naming fewer
                 * than half the chapters. "pages" is what lets a name be
                 * paired with its own page's geometry.
                 *
                 * The scan is redone here rather than cached: it is a bounded
                 * walk over at most 64 sectors of an already-open file, and
                 * holding a nav_t per cell would put 200 KB on the stack for
                 * a menu that has no pages worth speaking of. */
                jprintf("      \"pages\": [");
                int page_index = 0;
                for (int c = 0; c < cell_count && c < 256 && cells && have_vob; c++) {
                    const uint8_t *cell = cells + (size_t)c * 24;
                    uint32_t cell_first = be32(cell + 0x08), cell_last = be32(cell + 0x14);
                    if (cell_last < cell_first) continue;

                    nav_t page_nav;
                    uint32_t page_sector = 0;
                    int page_lbn_matches = 0;
                    const char *page_error = NULL;
                    scan_cell_nav(vob, cell_first, cell_last, frame_w, frame_h,
                                  &page_nav, &page_sector, &page_lbn_matches, &page_error);
                    if (page_nav.count == 0) continue;

                    char still_id[2200];
                    if (c == 0) snprintf(still_id, sizeof still_id, "%s", id);
                    else snprintf(still_id, sizeof still_id, "%s-cell%d", id, c + 1);

                    jprintf("%s\n      { \"cell\": %d, \"still\": ", page_index ? "," : "", c + 1);
                    jstring(still_id);
                    jprintf(", \"rendered\": %s", (c < 256 && dumped[c]) ? "true" : "false");
                    jprintf(", \"nav\": { \"sector\": %u, \"lbnMatches\": %s, \"buttonsPerGroup\": %d,"
                            " \"groupsAgree\": %s, \"rectsInsideFrame\": %s, \"error\": ",
                            page_sector, page_lbn_matches ? "true" : "false",
                            page_nav.buttons_per_group,
                            page_nav.groups_agree ? "true" : "false",
                            page_nav.rects_inside_frame ? "true" : "false");
                    if (page_nav.count > 0 && !page_nav.error) jprintf("null");
                    else jstring(page_nav.error ? page_nav.error : page_error);
                    jprintf(" }, \"buttons\": [");
                    emit_buttons(&page_nav);
                    jprintf("%s] }", page_nav.count > 0 ? "\n      " : "");
                    page_index++;
                }
                jprintf("%s],\n", page_index ? "\n      " : "");
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
