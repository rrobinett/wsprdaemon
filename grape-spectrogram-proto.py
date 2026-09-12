#!/usr/bin/env python3
"""PROTOTYPE: publish a GRAPE channel's Doppler spectrogram as data a browser can re-shade interactively.

usage: grape-spectrogram-proto.py  IN.wav  OUT_DIR  [WINDOW_S]

The static PNG strip chart has to pick one grey ramp, and on a strong day the main carrier's skirts use up
all of it, hiding the weaker paths.  Here the whole spectrogram is shipped to the browser instead and the
page maps dB to colour as you drag sliders, so a path 40 dB down can be brought up without regenerating
anything.  Three files land in OUT_DIR:

  spec.png   the spectrogram itself, 8 bit greyscale, one column per WINDOW, one row per frequency bin,
             row 0 = highest frequency.  Pixel value v means DB_LO + v * (DB_HI - DB_LO) / 255 dB over that
             window's median bin.  It is data, not a picture -- the page never shows it as-is.
  meta.json  axes, the pixel->dB scale, and the tracked carriers (offset and SNR per window) that the page
             needs to overlay them, to notch the strongest one out, and to shade relative to it.
  index.html the viewer, copied from grape-spectrogram-proto.html next to this script.

WINDOW_S overrides the 10 s analysis window.  A longer window resolves paths that a shorter one merges --
30 s gives 0.033 Hz instead of 0.1 Hz -- at the cost of smearing anything that moves within it, so it is
worth generating both and flipping between them.  The constants that are tied to the window's main lobe
follow it.

The analysis comes from grape-strip-chart.py, loaded by path since its name isn't importable.
"""
import sys, os, json, shutil, importlib.util
import numpy as np

F_MAX_HZ  = 2.5      # frequency range published, from the +-5 Hz the 10 sps channel holds
DB_LO     = -10.0    # pixel value 0 ...
DB_HI     =  70.0    # ... and 255, in dB over the window's median bin

HERE = os.path.dirname(os.path.abspath(__file__))

def load_analysis():
    path = os.path.join(HERE, "grape-strip-chart.py")
    spec = importlib.util.spec_from_file_location("grape_strip_chart", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    wav, out_dir = sys.argv[1], sys.argv[2]
    gsc = load_analysis()
    if len(sys.argv) == 4:
        gsc.WINDOW_S = int(sys.argv[3])
        gsc.PEAK_SEP_HZ = 3.0 / gsc.WINDOW_S          # the main lobe narrows with the window ...
        gsc.PERSIST_TOL_HZ = gsc.PEAK_SEP_HZ / 3      # ... and so does "the same offset as last window"
    f_bin_hz = 1.0 / (4.0 * gsc.WINDOW_S)             # ~a quarter of the real resolution: smooth, not bloated
    meta = gsc.parse_path(wav)
    a = gsc.analyze(wav)
    os.makedirs(out_dir, exist_ok=True)

    fr, spec_db = a["spec_f"], a["spec_db"]
    keep = np.abs(fr) <= F_MAX_HZ
    group = max(1, int(round(f_bin_hz / (fr[1] - fr[0]))))
    n_f = int(keep.sum()) // group * group
    first = int(np.flatnonzero(keep)[0])
    band = spec_db[:, first:first + n_f].reshape(len(spec_db), n_f // group, group)
    # thin by taking the strongest bin of each group: averaging would bury a carrier in its own noise floor
    thin = band.max(axis=2)
    f_bin = fr[first:first + n_f].reshape(-1, group).mean(axis=1)

    u8 = np.clip((thin - DB_LO) * (255.0 / (DB_HI - DB_LO)), 0, 255).astype(np.uint8)
    from PIL import Image
    Image.fromarray(u8[:, ::-1].T, "L").save(os.path.join(out_dir, "spec.png"), optimize=True)

    def series(v, nd):
        return [None if not np.isfinite(x) else round(float(x), nd) for x in v]
    doc = dict(meta, window_s=gsc.WINDOW_S, n_t=int(a["n"]), n_f=int(thin.shape[1]),
               f_top_hz=float(f_bin[-1]), f_bottom_hz=float(f_bin[0]), f_bin_hz=float(f_bin[1] - f_bin[0]),
               db_lo=DB_LO, db_hi=DB_HI, snr_min_db=gsc.SNR_MIN_DB, peak_sep_hz=gsc.PEAK_SEP_HZ,
               good_frac=round(a["good_frac"], 3), multipath_frac=round(a["multipath_frac"], 3),
               local_tz=None, utc_offset_h=None,
               carriers=[dict(rank=c + 1, freq_hz=series(a["carrier_f"][c], 3), snr_db=series(a["carrier_snr"][c], 1))
                         for c in range(a["carrier_f"].shape[0])])
    tz, tz_source = gsc.chart_timezone(meta)
    _, doc["local_tz"], doc["utc_offset_h"] = gsc.local_ticks(meta["date_yyyymmdd"], tz)
    doc["local_tz_source"] = tz_source
    with open(os.path.join(out_dir, "meta.json"), "w") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    shutil.copy(os.path.join(HERE, "grape-spectrogram-proto.html"), os.path.join(out_dir, "index.html"))

    png = os.path.join(out_dir, "spec.png")
    print(f"{meta['date']} {meta['band']}: {doc['n_t']} x {doc['n_f']} spectrogram, "
          f"{os.path.getsize(png)/1e6:.1f} MB png -> {out_dir}/index.html")

if __name__ == "__main__":
    main()
