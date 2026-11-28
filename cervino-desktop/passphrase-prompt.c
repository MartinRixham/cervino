/*
 * passphrase-prompt: asks for a passphrase on the framebuffer, styled as
 * libadwaita's dark style draws a status page with a password entry, and
 * prints it.
 *
 *   passphrase-prompt [-t title] [-d description] [-f font] [-n tries]
 *                     [-- command [argument...]]
 *
 * The command, if any, checks each passphrase, given on its standard input:
 * the prompt asks again while it fails, up to tries times (5), and prints
 * the one it accepts. disk-passphrase runs it in the initramfs, with the
 * console as its standard input, before the root (and udev) is up, so it
 * draws on /dev/fb0 (the firmware's framebuffer, or the KMS driver's), with
 * the virtual terminal on screen put in graphics mode so that the kernel
 * doesn't draw over it. It reads keys from that virtual terminal (the
 * keyboard of the screen it draws on) and from its standard input, which
 * is a serial console instead when the kernel's console is one (an arm64
 * VM's firmware or console= on the command line can make it so).
 *
 * Exit status: 0, the passphrase printed; 1, none (end of input, a signal
 * or the tries exhausted); 2, the prompt could not be shown (no
 * framebuffer, terminal or font) and nothing was read, so the caller can
 * ask on the console instead.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H

#define FONT "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf"
#define MAXPASS 512

/* libadwaita's dark style. */
#define WINDOW_BG 0x222226 /* @window_bg_color */
#define FG 0xffffff        /* @window_fg_color */
#define ACCENT 0x81d0ff    /* @accent_color (blue) */
#define ERROR 0xff938c     /* @error_color */
#define DIM 0.55f          /* .dim-label */

struct fb {
	int fd;
	uint8_t *mem;
	size_t len;
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	uint32_t *shadow; /* 0xRRGGBB, w x h */
	int w, h;
};

enum state { TYPING, CHECKING, WRONG };

static struct fb fb;
static FT_Face face;
static FT_MM_Var *mm;
static int wght = -1;
static float scale = 1;
static const char *title = "Unlock Disk";
static const char *description = "Enter the passphrase to start the system";

/* Where keys come from: standard input and the virtual terminal (kd). */
static int in[2] = { -1, -1 }, nin;
static struct termios saved_tio[2];
static int kd = -1, graphics;
static volatile sig_atomic_t quit;

static char pass[MAXPASS + 1];
static size_t passlen;

/* --- Drawing ------------------------------------------------------------ */

static float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

static void blend(int x, int y, uint32_t c, float a)
{
	if (x < 0 || y < 0 || x >= fb.w || y >= fb.h || a <= 0)
		return;
	if (a > 1)
		a = 1;
	uint32_t *p = &fb.shadow[(size_t)y * fb.w + x], d = *p, o = 0;
	for (int s = 0; s < 24; s += 8) {
		float dc = (d >> s) & 0xff, sc = (c >> s) & 0xff;
		o |= (uint32_t)lroundf(dc + (sc - dc) * a) << s;
	}
	*p = o;
}

/* Signed distance from (px, py) to a rounded rectangle, in pixels. */
static float rrect_sdf(float px, float py, float x, float y, float w, float h, float r)
{
	float cx = x + w / 2, cy = y + h / 2;
	float qx = fabsf(px - cx) - (w / 2 - r), qy = fabsf(py - cy) - (h / 2 - r);
	float ox = fmaxf(qx, 0), oy = fmaxf(qy, 0);
	return sqrtf(ox * ox + oy * oy) + fminf(fmaxf(qx, qy), 0) - r;
}

static float cover(float d)
{
	return clampf(0.5f - d, 0, 1);
}

static void fill_rrect(float x, float y, float w, float h, float r, uint32_t c, float a)
{
	for (int j = (int)floorf(y); j < (int)ceilf(y + h); j++)
		for (int i = (int)floorf(x); i < (int)ceilf(x + w); i++)
			blend(i, j, c, a * cover(rrect_sdf(i + 0.5f, j + 0.5f, x, y, w, h, r)));
}

/* An outline of width t inside the rectangle. */
static void stroke_rrect(float x, float y, float w, float h, float r, float t, uint32_t c, float a)
{
	for (int j = (int)floorf(y); j < (int)ceilf(y + h); j++)
		for (int i = (int)floorf(x); i < (int)ceilf(x + w); i++) {
			float d = rrect_sdf(i + 0.5f, j + 0.5f, x, y, w, h, r);
			blend(i, j, c, a * (cover(d) - cover(d + t)));
		}
}

static void fill_circle(float cx, float cy, float r, uint32_t c, float a)
{
	for (int j = (int)floorf(cy - r); j < (int)ceilf(cy + r); j++)
		for (int i = (int)floorf(cx - r); i < (int)ceilf(cx + r); i++)
			blend(i, j, c, a * cover(hypotf(i + 0.5f - cx, j + 0.5f - cy) - r));
}

/*
 * A padlock, as Adwaita's symbolic icons draw one on their 16 x 16 grid
 * (the shackle a 2-wide stroke of radius 4 about (8, 5), the body from
 * (2, 7) to (14, 15) with corners of 2), size pixels square.
 */
static void draw_lock(float x, float y, float size, uint32_t c, float a)
{
	float u = size / 16;
	for (int j = (int)floorf(y); j < (int)ceilf(y + size); j++)
		for (int i = (int)floorf(x); i < (int)ceilf(x + size); i++) {
			float px = (i + 0.5f - x) / u, py = (j + 0.5f - y) / u, ds;
			if (py < 5)
				ds = fabsf(hypotf(px - 8, py - 5) - 4) - 1;
			else
				ds = fmaxf(fabsf(fabsf(px - 8) - 4) - 1, py - 8);
			float db = rrect_sdf(px, py, 2, 7, 12, 8, 2);
			blend(i, j, c, a * cover(fminf(ds, db) * u));
		}
}

/* --- Text --------------------------------------------------------------- */

static uint32_t utf8_next(const char **s)
{
	const unsigned char *p = (const unsigned char *)*s;
	uint32_t c = *p++;
	int n = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : 0;
	if (n)
		c &= 0x3f >> n;
	while (n-- && (*p & 0xc0) == 0x80)
		c = c << 6 | (*p++ & 0x3f);
	*s = (const char *)p;
	return c;
}

/* The font at pt points (at 96 dpi, times the scale) and a weight. */
static void set_font(float pt, int weight)
{
	if (wght >= 0) {
		FT_Fixed coords[16];
		unsigned n = mm->num_axis < 16 ? mm->num_axis : 16;
		for (unsigned i = 0; i < n; i++)
			coords[i] = mm->axis[i].def;
		coords[wght] = (FT_Fixed)weight << 16;
		FT_Set_Var_Design_Coordinates(face, n, coords);
	}
	FT_Set_Char_Size(face, 0, (FT_F26Dot6)lroundf(pt * scale * 64), 96, 96);
}

static float text_width(const char *s)
{
	FT_Pos w = 0;
	while (*s)
		if (!FT_Load_Char(face, utf8_next(&s), FT_LOAD_TARGET_LIGHT))
			w += face->glyph->advance.x;
	return w / 64.0f;
}

static float ascender(void)
{
	return face->size->metrics.ascender / 64.0f;
}

static float line_height(void)
{
	return face->size->metrics.height / 64.0f;
}

/* Text with its top at y, starting at x. */
static void draw_text(float x, float y, const char *s, uint32_t c, float a)
{
	float pen = x, base = roundf(y + ascender());
	while (*s) {
		if (FT_Load_Char(face, utf8_next(&s), FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT))
			continue;
		FT_GlyphSlot g = face->glyph;
		FT_Bitmap *b = &g->bitmap;
		int ox = (int)roundf(pen) + g->bitmap_left, oy = (int)base - g->bitmap_top;
		for (unsigned j = 0; j < b->rows; j++)
			for (unsigned i = 0; i < b->width; i++)
				blend(ox + (int)i, oy + (int)j, c, a * b->buffer[j * b->pitch + i] / 255.0f);
		pen += g->advance.x / 64.0f;
	}
}

static void draw_text_centred(float cx, float y, const char *s, uint32_t c, float a)
{
	draw_text(roundf(cx - text_width(s) / 2), y, s, c, a);
}

/* --- The page ----------------------------------------------------------- */

static int caps_lock(void)
{
	char leds = 0;
	return kd >= 0 && ioctl(kd, KDGKBLED, &leds) == 0 && (leds & K_CAPSLOCK);
}

static size_t chars(const char *s, size_t n)
{
	size_t c = 0;
	for (size_t i = 0; i < n; i++)
		c += ((unsigned char)s[i] & 0xc0) != 0x80;
	return c;
}

static int band_top, band_bottom;

/*
 * An AdwStatusPage: its icon (128 px, half opaque), title (.title-1:
 * 20 pt, weight 800), description and child, an entry 34 px high with
 * corners of 6 px, filled with the foreground at 10%, and focused: an
 * outline of 2 px in the accent colour at 50%, or the error colour once a
 * passphrase was wrong. Below it, what is happening.
 */
static void draw(enum state st, int caret)
{
	float s = scale, cx = fb.w / 2.0f;
	float icon = 128 * s, gap = 36 * s, entry_h = 34 * s;
	float entry_w = fminf(320 * s, fb.w - 24 * s);

	set_font(20, 800);
	float title_h = line_height();
	set_font(11, 400);
	float body_h = line_height();

	float total = icon + gap + title_h + 12 * s + body_h + gap + entry_h + 12 * s + body_h;
	float y = roundf((fb.h - total) / 2);
	band_top = (int)fmaxf(0, y - 4 * s);
	band_bottom = (int)fminf(fb.h, y + total + 4 * s);

	for (int j = band_top; j < band_bottom; j++)
		for (int i = 0; i < fb.w; i++)
			fb.shadow[(size_t)j * fb.w + i] = WINDOW_BG;

	draw_lock(roundf(cx - icon / 2), y, icon, FG, 0.5f);
	y += icon + gap;

	set_font(20, 800);
	draw_text_centred(cx, y, title, FG, 1);
	y += title_h + 12 * s;

	set_font(11, 400);
	draw_text_centred(cx, y, description, FG, 1);
	y += body_h + gap;

	float ex = roundf(cx - entry_w / 2), ey = y, r = 6 * s;
	float on = st == CHECKING ? 0.5f : 1; /* :disabled */
	fill_rrect(ex, ey, entry_w, entry_h, r, FG, 0.1f * on);
	if (st != CHECKING)
		stroke_rrect(ex, ey, entry_w, entry_h, r, 2 * s,
			     st == WRONG ? ERROR : ACCENT, 0.5f);

	/* The text: a dot for each character, or the placeholder. */
	float pad = 9 * s, tx = ex + pad, right = ex + entry_w - pad;
	float mid = ey + entry_h / 2, adv = 10 * s, dot = 3 * s;
	size_t n = chars(pass, passlen);
	float tw = n * adv;
	float start = tx + fminf(0, right - 2 * s - tx - tw); /* scrolled to the caret */
	uint32_t tc = st == WRONG ? ERROR : FG;
	if (n == 0 && st != CHECKING) {
		draw_text(tx, roundf(mid - line_height() / 2), "Passphrase", FG, 0.5f);
	}
	for (size_t i = 0; i < n; i++) {
		float dx = start + i * adv + adv / 2;
		if (dx - dot >= tx - 0.5f)
			fill_circle(dx, mid, dot, tc, on);
	}
	if (caret && st != CHECKING) {
		float h = roundf(17 * s), x = roundf(start + tw);
		for (int j = 0; j < (int)h; j++)
			for (int i = 0; i < (int)fmaxf(1, roundf(s)); i++)
				blend((int)x + i, (int)roundf(mid - h / 2) + j, tc, 1);
	}
	y += entry_h + 12 * s;

	if (st == CHECKING)
		draw_text_centred(cx, y, "Unlocking…", FG, DIM);
	else if (st == WRONG)
		draw_text_centred(cx, y, "Wrong passphrase. Try again.", ERROR, 1);
	else if (caps_lock())
		draw_text_centred(cx, y, "Caps Lock is on", FG, DIM);
}

/* The shadow's rows from top to bottom, in the framebuffer's format. */
static void flush(int top, int bottom)
{
	struct fb_var_screeninfo *v = &fb.var;
	int bpp = (v->bits_per_pixel + 7) / 8;
	for (int j = top; j < bottom; j++) {
		uint8_t *row = fb.mem + (size_t)(j + v->yoffset) * fb.fix.line_length +
			       (size_t)v->xoffset * bpp;
		for (int i = 0; i < fb.w; i++) {
			uint32_t c = fb.shadow[(size_t)j * fb.w + i];
			uint32_t r = c >> 16 & 0xff, g = c >> 8 & 0xff, b = c & 0xff;
			uint32_t p = (r >> (8 - v->red.length)) << v->red.offset |
				     (g >> (8 - v->green.length)) << v->green.offset |
				     (b >> (8 - v->blue.length)) << v->blue.offset;
			memcpy(row + (size_t)i * bpp, &p, bpp); /* little-endian */
		}
	}
}

static void show(enum state st, int caret)
{
	draw(st, caret);
	flush(band_top, band_bottom);
}

/* --- Setting up and tearing down ---------------------------------------- */

static void restore(void)
{
	if (graphics)
		ioctl(kd, KDSETMODE, KD_TEXT);
	graphics = 0;
	for (int i = 0; i < nin; i++)
		tcsetattr(in[i], TCSAFLUSH, &saved_tio[i]);
	nin = 0;
}

static void on_signal(int sig)
{
	(void)sig;
	quit = 1;
}

static int open_fb(void)
{
	fb.fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
	if (fb.fd < 0 || ioctl(fb.fd, FBIOGET_VSCREENINFO, &fb.var) ||
	    ioctl(fb.fd, FBIOGET_FSCREENINFO, &fb.fix))
		return -1;
	struct fb_var_screeninfo *v = &fb.var;
	if (fb.fix.type != FB_TYPE_PACKED_PIXELS || fb.fix.visual != FB_VISUAL_TRUECOLOR ||
	    (v->bits_per_pixel != 16 && v->bits_per_pixel != 24 && v->bits_per_pixel != 32) ||
	    !v->red.length || v->red.length > 8 || !v->green.length || v->green.length > 8 ||
	    !v->blue.length || v->blue.length > 8)
		return -1;
	fb.w = (int)v->xres;
	fb.h = (int)v->yres;
	fb.len = fb.fix.smem_len;
	fb.mem = mmap(NULL, fb.len, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd, 0);
	if (fb.mem == MAP_FAILED)
		return -1;
	if ((size_t)(v->yoffset + v->yres) * fb.fix.line_length > fb.len)
		return -1;
	fb.shadow = malloc((size_t)fb.w * fb.h * sizeof *fb.shadow);
	if (!fb.shadow)
		return -1;
	for (size_t i = 0; i < (size_t)fb.w * fb.h; i++)
		fb.shadow[i] = WINDOW_BG;

	/* Twice the size on a high-density screen, as GNOME would choose. */
	int dense;
	if ((int)v->width > 0 && (int)v->height > 0)
		dense = fb.w * 25.4f / v->width >= 192 && fb.h >= 1200;
	else
		dense = fb.h >= 2000;
	scale = dense ? 2 : 1;
	return 0;
}

static int open_font(const char *path)
{
	FT_Library lib;
	if (FT_Init_FreeType(&lib) || FT_New_Face(lib, path, 0, &face))
		return -1;
	if (FT_HAS_MULTIPLE_MASTERS(face) && !FT_Get_MM_Var(face, &mm))
		for (unsigned i = 0; i < mm->num_axis && i < 16; i++)
			if (mm->axis[i].tag == FT_MAKE_TAG('w', 'g', 'h', 't'))
				wght = (int)i;
	return 0;
}

/* A terminal to read keys from, one at a time and without echo. */
static void add_input(int fd)
{
	if (tcgetattr(fd, &saved_tio[nin]))
		return;
	struct termios t = saved_tio[nin];
	t.c_lflag &= ~(ICANON | ECHO | ECHONL | ISIG | IEXTEN);
	t.c_iflag &= ~(ICRNL | INLCR | IGNCR | IXON);
	t.c_cc[VMIN] = 1;
	t.c_cc[VTIME] = 0;
	if (tcsetattr(fd, TCSAFLUSH, &t))
		return;
	in[nin++] = fd;
}

static int open_tty(void)
{
	/*
	 * The screen's keyboard and display: the console's virtual terminal,
	 * or, when the console is a serial port, the one on screen (tty0).
	 * Keys typed there never reach a serial console, so it is read too.
	 */
	if (ioctl(STDIN_FILENO, KDGKBTYPE, &(char){0}) == 0)
		kd = STDIN_FILENO;
	else
		kd = open("/dev/tty0", O_RDWR | O_CLOEXEC | O_NOCTTY);
	add_input(STDIN_FILENO);
	if (kd >= 0 && kd != STDIN_FILENO)
		add_input(kd);
	return nin ? 0 : -1;
}

/* --- Checking ----------------------------------------------------------- */

/* Whether the command accepts the passphrase on its standard input. */
static int check(char **argv)
{
	int p[2];
	if (pipe2(p, O_CLOEXEC))
		return 0;
	pid_t pid = fork();
	if (pid < 0) {
		close(p[0]);
		close(p[1]);
		return 0;
	}
	if (pid == 0) {
		int null = open("/dev/null", O_RDWR);
		dup2(p[0], STDIN_FILENO);
		dup2(null, STDOUT_FILENO);
		dup2(null, STDERR_FILENO);
		signal(SIGPIPE, SIG_DFL);
		execvp(argv[0], argv);
		_exit(127);
	}
	close(p[0]);
	for (size_t off = 0; off < passlen;) {
		ssize_t w = write(p[1], pass + off, passlen - off);
		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			break;
		off += (size_t)w;
	}
	close(p[1]);
	int status;
	while (waitpid(pid, &status, 0) < 0)
		if (errno != EINTR)
			return 0;
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

/* --- Input -------------------------------------------------------------- */

static long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/*
 * A byte from either terminal, or -1 if none comes within ms (-1: wait),
 * or -2 at the end (of both: a serial console that hangs up leaves the
 * screen's keyboard).
 */
static int get_byte(int ms)
{
	struct pollfd pf[2];
	for (int i = 0; i < nin; i++)
		pf[i] = (struct pollfd){ .fd = in[i], .events = POLLIN };
	for (;;) {
		if (quit)
			return -2;
		int open = 0;
		for (int i = 0; i < nin; i++)
			open += pf[i].fd >= 0;
		if (!open)
			return -2;
		int r = poll(pf, nin, ms);
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0)
			return -2;
		if (r == 0)
			return -1;
		for (int i = 0; i < nin; i++) {
			if (!pf[i].revents)
				continue;
			unsigned char c;
			ssize_t n = read(pf[i].fd, &c, 1);
			if (n == 1)
				return c;
			if (n < 0 && (errno == EINTR || errno == EAGAIN))
				continue;
			pf[i].fd = -1; /* ended: poll ignores it */
		}
	}
}

/* Skips the rest of an escape sequence (a function or cursor key). */
static int skip_escape(void)
{
	int c = get_byte(50);
	if (c == -1)
		return 1; /* Escape itself */
	if (c == '[' || c == 'O') {
		c = get_byte(50);
		if (c == '[') /* the Linux console's F1 to F5 */
			return get_byte(50) == -2 ? -1 : 0;
		while (c >= 0 && !(c >= 0x40 && c <= 0x7e))
			c = get_byte(50);
	}
	return c == -2 ? -1 : 0;
}

int main(int argc, char **argv)
{
	const char *font = FONT;
	int tries = 5, opt;
	while ((opt = getopt(argc, argv, "+t:d:f:n:")) != -1) {
		switch (opt) {
		case 't': title = optarg; break;
		case 'd': description = optarg; break;
		case 'f': font = optarg; break;
		case 'n': tries = atoi(optarg); break;
		default:
			fprintf(stderr, "usage: %s [-t title] [-d description] [-f font] "
					"[-n tries] [-- command...]\n", argv[0]);
			return 2;
		}
	}
	char **cmd = optind < argc ? argv + optind : NULL;

	if (open_font(font) || open_fb() || open_tty()) {
		restore();
		return 2;
	}

	struct sigaction sa = { .sa_handler = on_signal };
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	if (kd >= 0 && ioctl(kd, KDSETMODE, KD_GRAPHICS) == 0)
		graphics = 1;
	ioctl(fb.fd, FBIOBLANK, FB_BLANK_UNBLANK);
	flush(0, fb.h);

	/* GTK's caret: blinking every 600 ms, and steady after 10 s idle. */
	enum state st = TYPING;
	int caret = 1, result = 1;
	long typed = now_ms();
	show(st, caret);
	for (;;) {
		int idle = now_ms() - typed >= 10000;
		int c = get_byte(idle ? -1 : 600);
		if (c == -2)
			break;
		if (c == -1) {
			caret = idle || !caret;
			show(st, caret);
			continue;
		}
		if (st == WRONG)
			st = TYPING;
		if (c == '\r' || c == '\n') {
			if (passlen == 0)
				goto redraw;
			if (cmd) {
				show(CHECKING, 0);
				if (!check(cmd)) {
					explicit_bzero(pass, sizeof pass);
					passlen = 0;
					for (int i = 0; i < nin; i++)
						tcflush(in[i], TCIFLUSH);
					if (--tries <= 0 || quit)
						break;
					st = WRONG;
					goto redraw;
				}
			}
			result = 0;
			break;
		} else if (c == 0x7f || c == 0x08) { /* Backspace */
			while (passlen && ((unsigned char)pass[--passlen] & 0xc0) == 0x80)
				;
		} else if (c == 0x15 || c == 0x03) { /* Ctrl-U, Ctrl-C */
			passlen = 0;
		} else if (c == 0x1b) {
			int e = skip_escape();
			if (e < 0)
				break;
			if (e)
				passlen = 0;
		} else if (c >= 0x20 && passlen < MAXPASS) {
			pass[passlen++] = (char)c;
		}
redraw:
		caret = 1;
		typed = now_ms();
		show(st, caret);
	}

	/* The screen as the console left it, so that its messages follow. */
	for (size_t i = 0; i < (size_t)fb.w * fb.h; i++)
		fb.shadow[i] = 0;
	flush(0, fb.h);
	restore();
	if (result == 0 && fwrite(pass, 1, passlen, stdout) != passlen)
		result = 1;
	explicit_bzero(pass, sizeof pass);
	return fflush(stdout) ? 1 : result;
}
