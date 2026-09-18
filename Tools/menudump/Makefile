# changeover-menudump — no -l flags, no -I flags, no vendored anything.
#
# The helper links nothing. Everything tier 1 needs (IFO tables, NAV pack
# button geometry, the raw VM commands) is unscrambled and read with plain
# POSIX file I/O; libdvdread is dlopen()ed at runtime, from wherever Homebrew
# put it, only to decrypt menu video for stills. So this builds on any Mac,
# including one with no DVD tooling installed at all, and the binary runs
# there too — it just reports what it could not find.
#
#   make                 build build/changeover-menudump
#   make test            build, generate a synthetic VIDEO_TS, dump it
#   make clean

CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -O2
BUILD   ?= build
TARGET   = $(BUILD)/changeover-menudump

.PHONY: all test clean

all: $(TARGET)

$(TARGET): menudump.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

# The only self-check available without a disc: write the structures from the
# published layout, read them back, and diff the button commands. See
# make-test-disc.py's header for what this proves and what it does not.
test: $(TARGET)
	rm -rf $(BUILD)/test-disc $(BUILD)/test-out
	python3 make-test-disc.py $(BUILD)/test-disc
	$(TARGET) --disc $(BUILD)/test-disc --out $(BUILD)/test-out
	python3 -c "import json,sys; d=json.load(open('$(BUILD)/test-out/structure.json')); \
	  assert d['titles'][0]['ptts']==23, d['titles']; \
	  m={x['id']:x for x in d['menus']}; \
	  assert m['vtsm-01-lu1-pgc1']['entryType']=='root'; \
	  assert m['vtsm-01-lu1-pgc1']['buttons'][0]['command']=='3002000000010000'; \
	  assert m['vtsm-01-lu1-pgc1']['buttons'][0]['rect']==[388,148,550,178]; \
	  assert m['vtsm-01-lu1-pgc2']['entryType']=='chapter'; \
	  assert len(m['vtsm-01-lu1-pgc2']['buttons'])==6; \
	  print('menudump self-test OK:', len(d['menus']), 'menu PGCs')"

clean:
	rm -rf $(BUILD)
