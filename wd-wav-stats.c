/* wd-wav-stats: a drop-in for the 'sox ... stats' calls in WsprDaemon.
 *
 *   wd-wav-stats [-x] [-w SECS] FILE                  == sox FILE -n stats
 *   wd-wav-stats [-x] [-w SECS] FILE START LEN [...]  == sox FILE -t wav - trim START LEN | sox - -n stats
 *                                                       (one 15-line block per START LEN pair)
 *
 * Output is the 15 lines of SoX 14.4.2 'stats' (mono), byte for byte, on stdout.
 * The statistics are a line-by-line port of sox-14.4.2/src/stats.c; START/LEN are turned
 * into sample positions exactly as sox's trim does (effects_i.c parsesamples()).
 *
 * Integer input (16/24/32-bit PCM) is converted to doubles exactly as sox does, so every
 * printed value equals sox's.  32/64-bit float input is used as is, in double precision.
 * sox instead truncates float input to 32-bit fixed point (and the trim pipeline's
 * intermediate float wav rounds that to 24 significant bits), which loses most of the
 * precision of very quiet radiod files.  -x reproduces sox's float quantization, for
 * verification only.
 *
 * Build: gcc -O2 -ffp-contract=off -o wd-wav-stats wd-wav-stats.c -lm
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define SAMPLE_MAX 2147483647
#define SAMPLE_MIN (-2147483647 - 1)
#define sqr(a) ((a) * (a))
#define linear_to_dB(x) (log10(x) * 20)

/* ---------------- wav reading ---------------- */
enum { ENC_INT, ENC_FLOAT };
typedef struct { int enc, bits; double rate; uint64_t n; void *data; } wav_t;

static uint32_t le32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const unsigned char *p) { return p[0] | p[1] << 8; }

static int read_wav(const char *path, wav_t *w)
{
    int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) { perror(path); return -1; }
    long fsize = st.st_size;
    unsigned char *b = fsize > 0 ? mmap(NULL, fsize, PROT_READ, MAP_PRIVATE, fd, 0) : MAP_FAILED;   /* only the pages a window touches are read */
    close(fd);
    if (b == MAP_FAILED) { fprintf(stderr, "%s: cannot map file\n", path); return -1; }
    if (fsize < 12 || memcmp(b, "RIFF", 4) || memcmp(b + 8, "WAVE", 4)) { fprintf(stderr, "%s: not a RIFF WAVE file\n", path); return -1; }
    int have_fmt = 0, tag = 0, ch = 0, bits = 0; uint32_t rate = 0;
    for (long i = 12; i + 8 <= fsize; ) {
        uint32_t sz = le32(b + i + 4);
        if (!memcmp(b + i, "fmt ", 4) && i + 8 + 16 <= fsize) {
            tag = le16(b + i + 8); ch = le16(b + i + 10); rate = le32(b + i + 12); bits = le16(b + i + 22);
            if (tag == 0xFFFE && sz >= 40 && i + 8 + 26 <= fsize) tag = le16(b + i + 8 + 24);   /* extensible: SubFormat */
            have_fmt = 1;
        } else if (!memcmp(b + i, "data", 4)) {
            uint64_t avail = fsize - i - 8, len = sz;
            if (!have_fmt) break;
            if (len == 0x7ffff000 || len > avail) len = avail;   /* sox ignores MS_UNSPEC; short files end at EOF */
            if (ch != 1) { fprintf(stderr, "%s: %d channels; only mono is supported\n", path, ch); return -1; }
            if (tag == 1 && (bits == 16 || bits == 24 || bits == 32)) w->enc = ENC_INT;
            else if (tag == 3 && (bits == 32 || bits == 64)) w->enc = ENC_FLOAT;
            else { fprintf(stderr, "%s: unsupported format tag %d, %d bits\n", path, tag, bits); return -1; }
            w->bits = bits; w->rate = rate; w->n = len / (bits / 8); w->data = b + i + 8;
            return 0;
        }
        i += 8 + (uint64_t)sz + (sz & 1);
    }
    fprintf(stderr, "%s: no fmt/data chunk\n", path);
    return -1;
}

/* sox_sample_t of sample i, as sox's wav/raw reader makes it */
static int32_t sox_sample(const wav_t *w, uint64_t i)
{
    const unsigned char *p = (const unsigned char *)w->data + i * (w->bits / 8);
    if (w->enc == ENC_INT) {
        if (w->bits == 16) return (int32_t)((uint32_t)le16(p) << 16);
        if (w->bits == 24) return (int32_t)(((uint32_t)p[0] << 8) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 24));
        return (int32_t)le32(p);
    }
    if (w->bits == 32) {   /* SOX_FLOAT_32BIT_TO_SAMPLE: truncates toward zero */
        float f; memcpy(&f, p, 4);
        double t = f * (SAMPLE_MAX + 1.);
        return t < SAMPLE_MIN ? SAMPLE_MIN : t >= SAMPLE_MAX + 1. ? SAMPLE_MAX : (int32_t)t;
    } else {               /* SOX_FLOAT_64BIT_TO_SAMPLE: rounds */
        double d; memcpy(&d, p, 8);
        double t = d * (SAMPLE_MAX + 1.);
        return t < 0 ? (t <= SAMPLE_MIN - .5 ? SAMPLE_MIN : (int32_t)(t - .5)) : (t >= SAMPLE_MAX + .5 ? SAMPLE_MAX : (int32_t)(t + .5));
    }
}

/* the native float value of sample i (float input only) */
static double float_value(const wav_t *w, uint64_t i)
{
    const unsigned char *p = (const unsigned char *)w->data + i * (w->bits / 8);
    if (w->bits == 32) { float f; memcpy(&f, p, 4); return f; }
    double d; memcpy(&d, p, 8); return d;
}

/* ---------------- sox trim position parsing (effects_i.c parsesamples, '+' anchor) ---------------- */
static const char *parsesamples(double rate, const char *str0, uint64_t *samples, int def, int combine)
{
    char *str = (char *)str0;
    do {
        uint64_t samples_part;
        int found_samples = 0, found_time = 0;
        const char *end, *pos;
        int found_colon, found_dot, found_e;
        for (; *str == ' '; ++str);
        for (end = str; *end && strchr("0123456789:.ets", *end); ++end);
        if (end == str) return NULL;
        pos = strchr(str, ':'); found_colon = pos && pos < end;
        pos = strchr(str, '.'); found_dot = pos && pos < end;
        pos = strchr(str, 'e'); found_e = pos && pos < end;
        if (found_colon || (found_dot && !found_e) || *(end - 1) == 't') found_time = 1;
        else if (*(end - 1) == 's') found_samples = 1;
        if (found_time || (def == 't' && !found_samples)) {
            int i;
            if (found_e) return NULL;
            for (samples_part = 0, i = 0; *str != '.' && i < 3; ++i) {
                char *last_str = str;
                long part = strtol(str, &str, 10);
                if (!i && str == last_str) return NULL;
                samples_part += rate * part;
                if (i < 2) { if (*str != ':') break; ++str; samples_part *= 60; }
            }
            if (*str == '.') {
                char *last_str = str;
                double part = strtod(str, &str);
                if (str == last_str) return NULL;
                samples_part += rate * part + .5;
            }
            if (*str == 't') str++;
        } else {
            char *last_str = str;
            double part = strtod(str, &str);
            if (str == last_str) return NULL;
            samples_part = part + .5;
            if (*str == 's') str++;
        }
        if (str != end) return NULL;
        switch (combine) {
            case '+': *samples += samples_part; break;
            case '-': *samples = samples_part <= *samples ? *samples - samples_part : 0; break;
        }
        combine = '\0';
        if (*str && strchr("+-", *str)) combine = *str++;
    } while (combine);
    return str;
}

/* lsx_parseposition() with default anchor '+'; '-' (end-relative) anchors are supported too */
static int parseposition(double rate, const char *str, uint64_t *samples, uint64_t latest, uint64_t end)
{
    char anchor = '+', combine = '+';
    if (*str && strchr("+-=", *str)) anchor = *str++;
    if (strchr("+-", anchor)) { combine = anchor; if (*str && strchr("+-", *str)) combine = *str++; }
    *samples = anchor == '=' ? 0 : anchor == '+' ? latest : end;
    const char *r = parsesamples(rate, str, samples, 't', combine);
    return r && !*r ? 0 : -1;
}

/* ---------------- stats.c port ---------------- */
typedef struct {
    double time_constant, scale;
    double last, sigma_x, sigma_x2, avg_sigma_x2, min_sigma_x2, max_sigma_x2;
    double min, max, mult, min_run, min_runs, max_run, max_runs;
    int64_t num_samples, tc_samples, min_count, max_count;
    uint32_t mask;
    double rate;
} priv_t;

static void st_start(priv_t *p, double rate, double time_constant)
{
    memset(p, 0, sizeof(*p));
    p->time_constant = time_constant; p->scale = 1; p->rate = rate;
    p->last = 0;
    p->mult = exp((-1 / p->time_constant / rate));
    p->tc_samples = 5 * p->time_constant * rate + .5;
    p->sigma_x = p->sigma_x2 = p->avg_sigma_x2 = p->max_sigma_x2 = 0;
    p->min = p->min_sigma_x2 = 2;
    p->max = -p->min;
    p->num_samples = 0;
    p->mask = 0;
}

/* flow() over n samples; state is kept in locals so the loop runs from registers */
static void st_flow(priv_t *p, const double *x, uint64_t n)
{
    double last = p->last, min = p->min, max = p->max, min_run = p->min_run, max_run = p->max_run;
    double min_runs = p->min_runs, max_runs = p->max_runs, sigma_x = p->sigma_x, sigma_x2 = p->sigma_x2;
    double avg_sigma_x2 = p->avg_sigma_x2, min_sigma_x2 = p->min_sigma_x2, max_sigma_x2 = p->max_sigma_x2, mult = p->mult;
    int64_t num_samples = p->num_samples, tc_samples = p->tc_samples, min_count = p->min_count, max_count = p->max_count;

    for (uint64_t i = 0; i < n; ++i, ++num_samples) {
        double d = x[i];
        if (d < min)
            min = d, min_count = 1, min_run = 1, min_runs = 0;
        else if (d == min) {
            ++min_count;
            min_run = d == last ? min_run + 1 : 1;
        }
        else if (last == min)
            min_runs += sqr(min_run);

        if (d > max)
            max = d, max_count = 1, max_run = 1, max_runs = 0;
        else if (d == max) {
            ++max_count;
            max_run = d == last ? max_run + 1 : 1;
        }
        else if (last == max)
            max_runs += sqr(max_run);

        sigma_x += d;
        sigma_x2 += sqr(d);
        avg_sigma_x2 = avg_sigma_x2 * mult + (1 - mult) * sqr(d);

        if (num_samples >= tc_samples) {
            if (avg_sigma_x2 > max_sigma_x2) max_sigma_x2 = avg_sigma_x2;
            if (avg_sigma_x2 < min_sigma_x2) min_sigma_x2 = avg_sigma_x2;
        }
        last = d;
    }
    p->last = last; p->min = min; p->max = max; p->min_run = min_run; p->max_run = max_run;
    p->min_runs = min_runs; p->max_runs = max_runs; p->sigma_x = sigma_x; p->sigma_x2 = sigma_x2;
    p->avg_sigma_x2 = avg_sigma_x2; p->min_sigma_x2 = min_sigma_x2; p->max_sigma_x2 = max_sigma_x2;
    p->num_samples = num_samples; p->min_count = min_count; p->max_count = max_count;
}

static void st_drain(priv_t *p)
{
    if (p->last == p->min) p->min_runs += sqr(p->min_run);
    if (p->last == p->max) p->max_runs += sqr(p->max_run);
}

static int32_t f64_to_sample(double d)   /* SOX_FLOAT_64BIT_TO_SAMPLE */
{
    double t = d * (SAMPLE_MAX + 1.);
    return t < 0 ? (t <= SAMPLE_MIN - .5 ? SAMPLE_MIN : (int32_t)(t - .5))
                 : (t >= SAMPLE_MAX + .5 ? SAMPLE_MAX : (int32_t)(t + .5));
}

static unsigned bit_depth(uint32_t mask, double min, double max, unsigned *x)
{
    unsigned result = 32;
    for (; result && !(mask & 1); --result, mask >>= 1);
    if (x) *x = result;
    mask = f64_to_sample(max);
    if (min < 0) mask |= ~((uint32_t)f64_to_sample(min) << 1);
    for (; result && !(mask & (uint32_t)SAMPLE_MIN); --result, mask <<= 1);
    return result;
}

static const char *sigfigs3(double number)   /* lsx_sigfigs3 */
{
    static const char symbols[] = "\0kMGTPEZY";
    static char string[16][10];
    static unsigned n;
    unsigned a, b, c;
    sprintf(string[n = (n + 1) & 15], "%#.3g", number);
    switch (sscanf(string[n], "%u.%ue%u", &a, &b, &c)) {
        case 2: if (b) return string[n]; /* fall through */
        case 1: c = 2; break;
        case 3: a = 100 * a + b; break;
    }
    if (c < sizeof(symbols) * 3 - 3) switch (c % 3) {
        case 0: sprintf(string[n], "%u.%02u%c", a / 100, a % 100, symbols[c / 3]); break;
        case 1: sprintf(string[n], "%u.%u%c", a / 10, a % 10, symbols[c / 3]); break;
        case 2: sprintf(string[n], "%u%c", a, symbols[c / 3]); break;
    }
    return string[n];
}

static void output(const priv_t *p, double x) { printf(" %9.*f", fabs(p->scale) < 10 ? 6 : 5, p->scale * x); }

static void st_stop(priv_t *q)   /* stop() for one flow (mono) */
{
    double min_runs = 0, max_count = 0, min = 2, max = -2, max_sigma_x = 0, sigma_x = 0, sigma_x2 = 0, min_sigma_x2 = 2, max_sigma_x2 = 0, avg_peak = 0;
    int64_t num_samples = 0, min_count = 0, max_runs = 0;
    uint32_t mask = 0;
    unsigned b1, b2;
    const priv_t *p = q;

    min = min <= q->min ? min : q->min;   /* sox: min(a,b) ((a)<=(b)?(a):(b)) */
    max = max >= q->max ? max : q->max;
    if (q->num_samples < q->tc_samples)
        q->min_sigma_x2 = q->max_sigma_x2 = q->sigma_x2 / q->num_samples;
    min_sigma_x2 = q->min_sigma_x2 < min_sigma_x2 ? q->min_sigma_x2 : min_sigma_x2;
    max_sigma_x2 = q->max_sigma_x2 > max_sigma_x2 ? q->max_sigma_x2 : max_sigma_x2;
    sigma_x += q->sigma_x;
    sigma_x2 += q->sigma_x2;
    num_samples += q->num_samples;
    mask |= q->mask;
    if (fabs(q->sigma_x) > fabs(max_sigma_x)) max_sigma_x = q->sigma_x;
    min_count += q->min_count;
    min_runs += q->min_runs;
    max_count += q->max_count;
    max_runs += q->max_runs;
    avg_peak += (-q->min > q->max ? -q->min : q->max);
    avg_peak /= 1; (void)sigma_x;

    if (!num_samples) { fprintf(stderr, "wd-wav-stats WARN stats: no audio\n"); return; }

    printf("DC offset ");
    output(p, max_sigma_x / p->num_samples);
    printf("\nMin level ");
    output(p, min);
    printf("\nMax level ");
    output(p, max);
    printf("\nPk lev dB %10.2f", linear_to_dB(-min > max ? -min : max));
    printf("\nRMS lev dB%10.2f", linear_to_dB(sqrt(sigma_x2 / num_samples)));
    printf("\nRMS Pk dB %10.2f", linear_to_dB(sqrt(max_sigma_x2)));
    printf("\nRMS Tr dB ");
    if (min_sigma_x2 != 1) printf("%10.2f", linear_to_dB(sqrt(min_sigma_x2)));
    else printf("         -");
    printf("\nCrest factor %7.2f", sigma_x2 ? avg_peak / sqrt(sigma_x2 / num_samples) : 1);
    printf("\nFlat factor%9.2f", linear_to_dB((min_runs + max_runs) / (min_count + max_count)));
    printf("\nPk count   %9s", sigfigs3((min_count + max_count) / 1));
    b1 = bit_depth(mask, min, max, &b2);
    printf("\nBit-depth      %2u/%-2u", b1, b2);
    printf("\nNum samples%9s", sigfigs3((double)p->num_samples));
    printf("\nLength s   %9.3f", p->num_samples / p->rate);
    printf("\nScale max ");
    output(p, 1.);
    printf("\nWindow s   %9.3f", p->time_constant);
    printf("\n");
}

/* ---------------- main ---------------- */
static void usage(void)
{
    fprintf(stderr,
        "usage: wd-wav-stats [-x] [-w SECS] FILE [START LEN]...\n"
        "  no START LEN : same 15 lines as 'sox FILE -n stats'\n"
        "  START LEN    : same 15 lines as 'sox FILE -t wav - trim START LEN | sox - -n stats', one block per pair\n"
        "  -w SECS      : RMS window time constant (sox stats -w), default 0.05\n"
        "  -x           : float input: reproduce sox's 32-bit fixed point (and pipeline 24-bit) quantization\n");
    exit(2);
}

int main(int argc, char **argv)
{
    int sox_exact = 0, ai = 1;
    double tc = .05;
    for (; ai < argc && argv[ai][0] == '-' && argv[ai][1]; ai++) {
        if (!strcmp(argv[ai], "-x")) sox_exact = 1;
        else if (!strcmp(argv[ai], "-w") && ai + 1 < argc) {
            tc = strtod(argv[++ai], NULL);
            if (!(tc >= .01 && tc <= 10)) usage();
        } else usage();
    }
    if (ai >= argc || (argc - ai - 1) % 2) usage();
    wav_t w;
    if (read_wav(argv[ai], &w)) return 1;
    int nwin = (argc - ai - 1) / 2, rc = 0;
    for (int k = 0; k < (nwin ? nwin : 1); k++) {
        uint64_t s0 = 0, s1 = w.n;
        int windowed = nwin > 0;
        if (windowed) {
            uint64_t a, b;
            if (parseposition(w.rate, argv[ai + 1 + 2 * k], &a, 0, w.n) ||
                parseposition(w.rate, argv[ai + 2 + 2 * k], &b, a, w.n) || b < a) {
                fprintf(stderr, "wd-wav-stats: bad trim position '%s %s'\n", argv[ai + 1 + 2 * k], argv[ai + 2 + 2 * k]);
                rc = 1; continue;
            }
            s0 = a < w.n ? a : w.n; s1 = b < w.n ? b : w.n;
        }
        if (windowed && s0 >= s1) {   /* sox: trim emits no samples, so no wav header reaches the second sox, which fails */
            fprintf(stderr, "wd-wav-stats FAIL: trim %s %s selects no samples of %s (%.3f s long)\n",
                    argv[ai + 1 + 2 * k], argv[ai + 2 + 2 * k], argv[ai], w.n / w.rate);
            rc = 2; continue;
        }
        priv_t p;
        st_start(&p, w.rate, tc);
        uint32_t mask = 0;
        int native_float = w.enc == ENC_FLOAT && !sox_exact;
        int pipe_round = w.enc == ENC_FLOAT && w.bits == 32 && windowed && sox_exact;
        enum { CHUNK = 4096 };
        double x[CHUNK];
        for (uint64_t c0 = s0; c0 < s1; c0 += CHUNK) {
            uint64_t n = s1 - c0 < CHUNK ? s1 - c0 : CHUNK;
            if (w.enc == ENC_INT && w.bits == 16) {                  /* the common case, kept tight */
                const unsigned char *b = (const unsigned char *)w.data + c0 * 2;
                for (uint64_t i = 0; i < n; i++) {
                    int32_t v = (int32_t)((uint32_t)le16(b + 2 * i) << 16);
                    mask |= (uint32_t)v;
                    x[i] = v * (1. / (SAMPLE_MAX + 1.));         /* SOX_SAMPLE_TO_FLOAT_64BIT */
                }
            } else for (uint64_t i = 0; i < n; i++) {
                int32_t v = sox_sample(&w, c0 + i);
                if (pipe_round)   /* -x: the trim pipeline writes a float wav (24-bit mantissa) and reads it back */
                    v = v > SAMPLE_MAX - 64 ? SAMPLE_MAX : (int32_t)(((int64_t)v + 64) & ~(int64_t)127);
                mask |= (uint32_t)v;
                x[i] = native_float ? float_value(&w, c0 + i) : v * (1. / (SAMPLE_MAX + 1.));
            }
            st_flow(&p, x, n);
        }
        p.mask = mask;
        st_drain(&p);
        st_stop(&p);
    }
    return rc;
}
