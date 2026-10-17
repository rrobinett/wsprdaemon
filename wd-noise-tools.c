// wd-noise-tools.c: get-peak-wav-sample.py and c2_noise.py in C, so WD stops starting python3 + numpy twice per band
// every cycle.  At ON5KQ-BL (8 receivers) on 2026-10-17 those two scripts ran ~130 times a two minute cycle at
// ~0.3 s of CPU each, nearly all of it importing numpy and soundfile, ~45 CPU-s a cycle.
//
//   wd-noise-tools peak FILE.wav...    prints, like get-peak-wav-sample.py, the largest |sample| over all the files
//                                      (scaled as soundfile reads them: int16/32768, int24/2^23, int32/2^31, u8,
//                                      float and double as they are) on one line with %.12f, then 20*log10 of it.
//   wd-noise-tools c2noise FILE.c2     prints, like c2_noise.py, " %6.2f": the power in dB of the lowest 30% of the
//                                      Hann-windowed 250 point spectra between 1369.5 and 1630.5 Hz of wsprd's -c file.
//
// c2noise follows c2_noise.py under numpy 1.26 step by step: the windowed samples rounded to complex64 (its in-place
// 'a *= np.hanning(250)'), the FFT in double, np.abs as hypot() then squared, rows 0..178, shifted bins 38..212.  The
// one deliberate difference: c2_noise.py sums np.partition(w, 9345)[0:9344], which is 9344 of the 9345 smallest values
// with WHICH one is left out up to numpy's selection algorithm (it differs from the 9344 smallest on 254 of 472 real
// files, by at most 0.000135 dB).  This sums exactly the 9344 smallest, which is what the comment there describes.
//
// Build: gcc -O2 -o wd-noise-tools wd-noise-tools.c -lm      (wd-setup.sh does this)

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t le32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const unsigned char *p) { return p[0] | p[1] << 8; }

// Largest |sample| of one WAV file, as soundfile (libsndfile) reads it to float64.  Returns 0 on success.
static int wav_peak(const char *path, double *peak) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    unsigned char h[12];
    if (fread(h, 1, 12, f) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) { fclose(f); return -1; }
    int format = 0, bits = 0, have_fmt = 0;
    size_t data_left = SIZE_MAX;
    for (;;) {
        unsigned char ch[8];
        if (fread(ch, 1, 8, f) != 8) { fclose(f); return -1; }
        uint32_t size = le32(ch + 4);
        if (!memcmp(ch, "fmt ", 4)) {
            unsigned char fmt[64] = {0};
            uint32_t n = size < sizeof fmt ? size : sizeof fmt;
            if (fread(fmt, 1, n, f) != n) { fclose(f); return -1; }
            if (size > n) fseek(f, size - n, SEEK_CUR);
            format = le16(fmt);
            bits = le16(fmt + 14);
            if (format == 0xFFFE && n >= 26) format = le16(fmt + 24);     // WAVE_FORMAT_EXTENSIBLE: the subformat GUID's first two bytes
            have_fmt = 1;
        } else if (!memcmp(ch, "data", 4)) {
            if (!have_fmt) { fclose(f); return -1; }
            data_left = (size == 0 || size == 0xFFFFFFFFu) ? SIZE_MAX : size;   // unset or still-open header: read to EOF
            break;
        } else {
            fseek(f, size + (size & 1), SEEK_CUR);
        }
        if (size & 1 && !memcmp(ch, "fmt ", 4)) fseek(f, 1, SEEK_CUR);
    }
    double max = 0;
    unsigned char buf[65536];
    size_t got, bytes = bits / 8, carry = 0;
    if (!((format == 1 && (bits == 8 || bits == 16 || bits == 24 || bits == 32)) || (format == 3 && (bits == 32 || bits == 64)))) { fclose(f); return -1; }
    // The data chunk's size, else (unset, or more than the file holds) to the end of the file, as libsndfile reads it
    while (data_left > 0 && (got = fread(buf + carry, 1, (sizeof buf - carry) < data_left ? sizeof buf - carry : data_left, f)) > 0) {
        data_left -= got;
        size_t have = carry + got, i;
        for (i = 0; i + bytes <= have; i += bytes) {
            const unsigned char *p = buf + i;
            double v;
            if (format == 3 && bits == 32) { float x; uint32_t u = le32(p); memcpy(&x, &u, 4); v = x; }
            else if (format == 3) { double x; uint64_t u = le32(p) | (uint64_t)le32(p + 4) << 32; memcpy(&x, &u, 8); v = x; }
            else if (bits == 8) v = (p[0] - 128) / 128.0;
            else if (bits == 16) v = (int16_t)le16(p) / 32768.0;
            else if (bits == 24) v = ((int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8) / 8388608.0;
            else v = (int32_t)le32(p) / 2147483648.0;
            v = fabs(v);
            if (v > max) max = v;
        }
        carry = have - i;
        memmove(buf, buf + i, carry);
    }
    fclose(f);
    *peak = max;
    return 0;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

#define C2_SAMPLES 45000
#define FFT_N 250
#define ROWS 179                     // c2_noise.py's w[0:179] of its 180 spectra
#define BIN_LO 38                    // and bins 38:213 of the shifted spectrum: 1369.5 to 1630.5 Hz
#define BIN_HI 213
#define KEEP 9344                    // the lowest 30% of the 179 * 175 = 31,325 values

static int c2noise(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "can't open %s\n", path); return 1; }
    unsigned char hdr[26];
    float *s = malloc(2 * C2_SAMPLES * sizeof *s);
    if (fread(hdr, 1, 26, f) != 26 || fread(s, sizeof *s, 2 * C2_SAMPLES, f) != 2 * C2_SAMPLES) {
        fprintf(stderr, "%s is not a complete wsprd -c file\n", path);
        fclose(f); free(s); return 1;
    }
    fclose(f);
    double win[FFT_N], cs[FFT_N], sn[FFT_N];
    for (int i = 0; i < FFT_N; i++) {
        win[i] = 0.5 + 0.5 * cos(M_PI * (1 - FFT_N + 2 * i) / (FFT_N - 1));     // np.hanning(250), as numpy computes it
        cs[i] = cos(2 * M_PI * i / FFT_N);
        sn[i] = sin(2 * M_PI * i / FFT_N);
    }
    static double w[ROWS * (BIN_HI - BIN_LO)];
    size_t nw = 0;
    float re[FFT_N], im[FFT_N];
    for (int r = 0; r < ROWS; r++) {
        for (int n = 0; n < FFT_N; n++) {
            // c2 floats are little-endian I,Q pairs; 'a *= np.hanning(250)' on complex64 rounds the product to float
            re[n] = (float)((double)s[2 * (r * FFT_N + n)] * win[n]);
            im[n] = (float)((double)s[2 * (r * FFT_N + n) + 1] * win[n]);
        }
        for (int b = BIN_LO; b < BIN_HI; b++) {
            int k = (b + FFT_N / 2) % FFT_N;                              // np.fft.fftshift
            double xr = 0, xi = 0;
            for (int n = 0, m = 0; n < FFT_N; n++, m = (m + k) % FFT_N) { // X[k] = sum x[n] e^(-2 pi i k n / N)
                xr += re[n] * cs[m] + im[n] * sn[m];
                xi += im[n] * cs[m] - re[n] * sn[m];
            }
            double a = hypot(xr, xi);                                     // np.abs, then np.square
            w[nw++] = a * a;
        }
    }
    free(s);
    qsort(w, nw, sizeof *w, cmp_double);
    double sum = 0;
    for (int i = 0; i < KEEP; i++) sum += w[i];
    printf(" %6.2f\n", 10 * log10(sum));
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "c2noise")) return c2noise(argv[2]);
    if (argc >= 3 && !strcmp(argv[1], "peak")) {
        double max = -INFINITY;
        int any = 0;
        for (int i = 2; i < argc; i++) {
            double p;
            if (wav_peak(argv[i], &p)) { printf("Error processing %s: can't read it as a WAV file\n", argv[i]); continue; }
            any = 1;
            if (p > max) max = p;
        }
        if (!any) { printf("\nNo valid files processed.\n"); return 0; }
        printf("%.12f\n%.12f\n", max, max > 0 ? 20 * log10(max) : -INFINITY);
        return 0;
    }
    fprintf(stderr, "usage: %s peak FILE.wav... | c2noise FILE.c2\n", argv[0]);
    return 2;
}
