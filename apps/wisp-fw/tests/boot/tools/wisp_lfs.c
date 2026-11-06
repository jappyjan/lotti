/*
 * SPDX-License-Identifier: MIT
 *
 * wisp_lfs — build and inspect a G2 NOR image (32 MiB, littlefs at 0x1400000 with the stock
 * geometry) on the host, with the same littlefs source Wisp Boot links. Rung-3 harness tool.
 *
 *   wisp_lfs new  <nor.bin>                      erased NOR (all 0xFF), no filesystem
 *   wisp_lfs format <nor.bin>                    erased NOR + empty littlefs
 *   wisp_lfs put  <nor.bin> <lfs-path> <file>    write a file (parent directories created)
 *   wisp_lfs get  <nor.bin> <lfs-path> <file>    read a file out (exit 2 if missing)
 *   wisp_lfs rm   <nor.bin> <lfs-path>           remove a file (exit 2 if missing)
 *   wisp_lfs ls   <nor.bin>                      recursive listing: "<size> <path>"
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lfs.h"
#include "wisp_boot_layout.h"

static unsigned char *nor;

static int bd_read(const struct lfs_config *c, lfs_block_t b, lfs_off_t off, void *buf, lfs_size_t n)
{
	memcpy(buf, nor + WISP_LFS_BASE + (size_t)b * c->block_size + off, n);
	return 0;
}

static int bd_prog(const struct lfs_config *c, lfs_block_t b, lfs_off_t off, const void *buf,
		   lfs_size_t n)
{
	unsigned char *d = nor + WISP_LFS_BASE + (size_t)b * c->block_size + off;
	const unsigned char *s = buf;

	for (lfs_size_t i = 0; i < n; i++) {
		d[i] &= s[i]; /* NOR semantics */
	}
	return 0;
}

static int bd_erase(const struct lfs_config *c, lfs_block_t b)
{
	memset(nor + WISP_LFS_BASE + (size_t)b * c->block_size, 0xFF, c->block_size);
	return 0;
}

static int bd_sync(const struct lfs_config *c)
{
	(void)c;
	return 0;
}

static const struct lfs_config cfg = {
	.read = bd_read,
	.prog = bd_prog,
	.erase = bd_erase,
	.sync = bd_sync,
	.read_size = WISP_LFS_READ_SIZE,
	.prog_size = WISP_LFS_PROG_SIZE,
	.block_size = WISP_LFS_BLOCK_SIZE,
	.block_count = WISP_LFS_BLOCK_COUNT,
	.block_cycles = WISP_LFS_BLOCK_CYCLES,
	.cache_size = WISP_LFS_CACHE_SIZE,
	.lookahead_size = WISP_LFS_LOOKAHEAD,
};

static void die(const char *what, int err)
{
	fprintf(stderr, "wisp_lfs: %s: %d\n", what, err);
	exit(1);
}

static void load(const char *path)
{
	FILE *f = fopen(path, "rb");

	nor = malloc(WISP_NOR_SIZE);
	if (!nor || !f) {
		die(path, errno);
	}
	if (fread(nor, 1, WISP_NOR_SIZE, f) != WISP_NOR_SIZE) {
		die("short NOR image", 0);
	}
	fclose(f);
}

static void save(const char *path)
{
	FILE *f = fopen(path, "wb");

	if (!f || fwrite(nor, 1, WISP_NOR_SIZE, f) != WISP_NOR_SIZE || fclose(f) != 0) {
		die(path, errno);
	}
}

static void mkparents(lfs_t *lfs, const char *path)
{
	char buf[LFS_NAME_MAX + 1];

	for (const char *p = strchr(path, '/'); p; p = strchr(p + 1, '/')) {
		size_t n = (size_t)(p - path);

		memcpy(buf, path, n);
		buf[n] = 0;
		int e = lfs_mkdir(lfs, buf);
		if (e && e != LFS_ERR_EXIST) {
			die("mkdir", e);
		}
	}
}

static void ls(lfs_t *lfs, const char *dir)
{
	lfs_dir_t d;
	struct lfs_info info;
	char sub[512];

	if (lfs_dir_open(lfs, &d, dir) < 0) {
		return;
	}
	while (lfs_dir_read(lfs, &d, &info) > 0) {
		if (!strcmp(info.name, ".") || !strcmp(info.name, "..")) {
			continue;
		}
		snprintf(sub, sizeof(sub), "%s%s%s", dir, strcmp(dir, "/") ? "/" : "", info.name);
		if (info.type == LFS_TYPE_DIR) {
			printf("dir %s\n", sub);
			ls(lfs, sub);
		} else {
			printf("%lu %s\n", (unsigned long)info.size, sub);
		}
	}
	lfs_dir_close(lfs, &d);
}

int main(int argc, char **argv)
{
	lfs_t lfs;
	int e;

	if (argc < 3) {
		fprintf(stderr, "usage: wisp_lfs new|format|put|get|rm|ls <nor.bin> [...]\n");
		return 64;
	}
	const char *cmd = argv[1], *img = argv[2];

	if (!strcmp(cmd, "new") || !strcmp(cmd, "format")) {
		nor = malloc(WISP_NOR_SIZE);
		memset(nor, 0xFF, WISP_NOR_SIZE);
		if (!strcmp(cmd, "format") && (e = lfs_format(&lfs, &cfg)) != 0) {
			die("format", e);
		}
		save(img);
		return 0;
	}
	load(img);
	if ((e = lfs_mount(&lfs, &cfg)) != 0) {
		die("mount", e);
	}
	if (!strcmp(cmd, "ls")) {
		ls(&lfs, "/");
	} else if (!strcmp(cmd, "put") && argc == 5) {
		FILE *f = fopen(argv[4], "rb");
		lfs_file_t lf;
		static unsigned char buf[65536];
		size_t n;

		if (!f) {
			die(argv[4], errno);
		}
		mkparents(&lfs, argv[3]);
		if ((e = lfs_file_open(&lfs, &lf, argv[3], LFS_O_WRONLY | LFS_O_CREAT | LFS_O_TRUNC)) < 0) {
			die("open", e);
		}
		while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
			if (lfs_file_write(&lfs, &lf, buf, (lfs_size_t)n) != (lfs_ssize_t)n) {
				die("write", 0);
			}
		}
		fclose(f);
		if ((e = lfs_file_close(&lfs, &lf)) != 0) {
			die("close", e);
		}
		lfs_unmount(&lfs);
		save(img);
		return 0;
	} else if (!strcmp(cmd, "get") && argc == 5) {
		lfs_file_t lf;
		static unsigned char buf[65536];
		lfs_ssize_t n;
		FILE *f;

		if (lfs_file_open(&lfs, &lf, argv[3], LFS_O_RDONLY) < 0) {
			return 2;
		}
		f = fopen(argv[4], "wb");
		while ((n = lfs_file_read(&lfs, &lf, buf, sizeof(buf))) > 0) {
			fwrite(buf, 1, (size_t)n, f);
		}
		fclose(f);
		lfs_file_close(&lfs, &lf);
	} else if (!strcmp(cmd, "rm") && argc == 4) {
		if (lfs_remove(&lfs, argv[3]) != 0) {
			return 2;
		}
		lfs_unmount(&lfs);
		save(img);
		return 0;
	} else {
		fprintf(stderr, "wisp_lfs: bad command\n");
		return 64;
	}
	lfs_unmount(&lfs);
	return 0;
}
