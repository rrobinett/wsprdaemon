#!/usr/bin/env python3
"""Make a 24-hour carrier strip chart from a WD GRAPE 24_hour_10sps_iq.wav.

Part of wsprdaemon (WD 3.4.6+).  Called by grape_create_chart() in grape-utils.sh; can also be run by hand.

usage: grape_strip_chart.py  IN.wav  OUT_BASE      -> OUT_BASE.png and OUT_BASE.json

Pane 1: carrier frequency offset (Hz) from the channel center.  A station usually arrives over more than one
        path -- ground wave plus one or more ionospheric hops, and on 5/10/15 MHz WWV plus WWVH -- and each
        path has its own Doppler shift, so each shows as its own line a fraction of a Hz from the others.
        The pane therefore has three layers:
          - a grey Doppler spectrogram: every 10 s spectrum, shaded from SPEC_FLOOR_DB dB over that window's
            median bin, which shows every path present, including ones too weak to be tracked as a carrier;
          - a line through the strongest carrier of each window;
          - dots on the next MAX_CARRIERS-1 carriers of each window: peaks >= SNR_MIN_DB over the median
            bin that are >= PEAK_SEP_HZ from and PROMINENCE_DB clear of a stronger one, and that hold
            their offset across neighbouring windows.  Those last two tests are what keeps the ripples on
            a strong carrier's Doppler-spread skirt from being reported as paths of their own.
Pane 2: carrier power (dBFS) = mean power of each 10 s window, and the strongest carrier's SNR.
The JSON holds the same series so the web page can overlay days/bands: freq_hz_series/power_db/snr_db for
the strongest carrier, and extra_carriers[] for the weaker ones, each a list of the windows it was seen in.
The local-time axis zone is chosen in this order:
  1. the server's own timezone, unless the server runs on UTC;
  2. the environment variable GRAPE_CHARTS_TZ (an IANA zone such as America/Los_Angeles), which WD sets
     from the GRAPE_CHARTS_TZ line of wsprdaemon.conf;
  3. the zone at the reporter's Maidenhead grid (from the <REPORTER>_<GRID> directory name), via the
     timezonefinder package, or plain solar time (longitude/15, no DST) if that package is missing.
"""
import sys, os, json, glob, re
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo
import warnings; warnings.filterwarnings("ignore")
import numpy as np, soundfile as sf
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

WINDOW_S     = 10      # seconds per estimate -> 8640 points/day
SNR_MIN_DB   = 15.0    # mask frequency estimates below this peak/median ratio
ZERO_PAD     = 8
MAX_CARRIERS = 3       # carriers tracked per window, strongest first
# A 10 s Kaiser(beta=8) window resolves carriers ~0.3 Hz apart and its skirts are ~65 dB down, so the
# sidelobes of a strong path can't be picked up as a weak second path.  Hann's -31 dB skirts could be.
KAISER_BETA  = 8.0
PEAK_SEP_HZ  = 3.0 / WINDOW_S    # main-lobe width: peaks closer than this are one carrier, not two
PROMINENCE_DB = 10.0             # ... and so is a peak the spectrum doesn't dip this far below in between.
                                 # Without it every ripple on a strong carrier's Doppler-spread skirt counts.
SPEC_FLOOR_DB = 10.0             # spectrogram white level, dB over the window's median bin.  Noise alone
                                 # exceeds it in 0.1% of bins, so anything visible above it is a signal.
# A real second path holds the same offset for at least a few windows, while a ripple on the strong
# carrier's skirt lands somewhere new each window.  So keep a weaker carrier only where PERSIST_MIN of the
# PERSIST_SPAN windows either side also show a carrier within PERSIST_TOL_HZ of it.
PERSIST_SPAN = 3
PERSIST_MIN  = 4
PERSIST_TOL_HZ = 0.1
SPEC_SPAN_MIN_DB = 25.0          # least the spectrogram's grey ramp may span; a strong day stretches it up
                                 # to the strongest carrier, so its skirts don't flood the pane with black
CARRIER_COLORS = ["tab:blue", "tab:red", "tab:purple", "tab:brown"]

def parse_path(wav):
    """.../wav-archive/<DATE>/<REPORTER>_<GRID>/<RECEIVER>@<PSWS>/<BAND>/24_hour_10sps_iq.wav"""
    band_dir = os.path.dirname(os.path.abspath(wav))
    parts = band_dir.split(os.sep)
    band, rcv, rep, date = parts[-1], parts[-2], parts[-3], parts[-4]
    # The date dir is normally YYYYMMDD, but operators park days aside under names like hold_20260813
    m = re.search(r"(20\d{6})", date)
    if m:
        date = m.group(1) if date == m.group(1) else date          # keep the odd name for display and paths ...
    date_yyyymmdd = m.group(1) if m else None                       # ... but chart with the real date
    freq_hz = None
    for f in sorted(glob.glob(os.path.join(band_dir, "*_iq.wv")))[:1]:
        m = re.search(r"_(\d+)_iq\.wv$", f)
        if m: freq_hz = int(m.group(1))
    grid = rep.rsplit("_", 1)[1] if "_" in rep else ""
    return dict(date=date, date_yyyymmdd=date_yyyymmdd, reporter=rep, receiver=rcv, band=band, freq_hz=freq_hz, grid=grid)

def maidenhead_to_latlon(grid):
    """Center of a 4- or 6-character Maidenhead locator, or None if it doesn't parse."""
    g = grid.strip().upper()
    if not re.fullmatch(r"[A-R]{2}[0-9]{2}([A-X]{2})?", g):
        return None
    lon = (ord(g[0]) - ord("A")) * 20 - 180 + int(g[2]) * 2
    lat = (ord(g[1]) - ord("A")) * 10 - 90 + int(g[3])
    if len(g) == 6:
        lon += (ord(g[4]) - ord("A")) * 5 / 60 + 2.5 / 60
        lat += (ord(g[5]) - ord("A")) * 2.5 / 60 + 1.25 / 60
    else:
        lon += 1.0
        lat += 0.5
    return lat, lon

def find_carriers(S, fr):
    """Track the MAX_CARRIERS strongest carriers of each 10 s spectrum.

    S is the spectrum in dB over the window's own median bin, shape (n_windows, n_bins); it is destroyed.
    Takes the strongest bin, refines it by parabolic interpolation, blanks the whole feature it belongs to
    -- everything the spectrum does not dip PROMINENCE_DB below on the way out to it, and at least
    PEAK_SEP_HZ either side -- and repeats.  That is what separates a second path from the skirt of the
    first: a path is a peak with a valley around it, a skirt is not.
    Returns (freq, snr) arrays of shape (MAX_CARRIERS, n_windows), strongest first, in Hz from the channel
    center and in dB over the median bin.  Nothing is masked here; the caller applies SNR_MIN_DB."""
    n, NF = S.shape
    df = fr[1] - fr[0]
    sep_bins = max(1, int(round(PEAK_SEP_HZ / df)))
    rows = np.arange(n)
    col = rows[:, None]
    out = np.arange(NF)                    # bins counted outward from the peak, wrapping at the channel edge
    ring = np.minimum(out, NF - out)       # how far out each of those bins is, in bins
    BLANK = np.float32(-999.0)
    f_out = np.full((MAX_CARRIERS, n), np.nan)
    s_out = np.full((MAX_CARRIERS, n), np.nan)
    for c in range(MAX_CARRIERS):
        k = S.argmax(1)
        kc = np.clip(k, 1, NF - 2)
        y0, y1, y2 = S[rows, kc - 1], S[rows, kc], S[rows, kc + 1]
        den = y0 - 2 * y1 + y2
        delta = np.where(den < 0, 0.5 * (y0 - y2) / np.where(den < 0, den, -1.0), 0.0)
        f_out[c] = fr[kc] + np.clip(delta, -1.0, 1.0) * df
        s_out[c] = np.where(y1 > BLANK / 2, y1, np.nan)
        idx = (k[:, None] + out) % NF                          # the row's spectrum, read outward from its peak
        R = S[col, idx]
        climb = np.where(out < NF // 2,                        # dB climbed back up since the deepest valley
                         R - np.minimum.accumulate(R, axis=1),                       # walking one way ...
                         R - np.minimum.accumulate(R[:, ::-1], axis=1)[:, ::-1])     # ... and the other
        S[col, idx] = np.where((climb >= PROMINENCE_DB) & (ring >= sep_bins), R, BLANK)
    return f_out, s_out

def persistent(f_c, good):
    """Of the carriers weaker than the strongest, keep only the ones that hold their offset across
    neighbouring windows (see PERSIST_*).  All ranks count as evidence, since which path is the strongest
    swaps back and forth.  Returns a copy of the good mask with the transient detections cleared."""
    f = np.where(good, f_c, np.nan)
    keep = good.copy()
    for c in range(1, f.shape[0]):
        seen = np.zeros(f.shape[1], dtype=int)
        for d in [d for d in range(-PERSIST_SPAN, PERSIST_SPAN + 1) if d]:
            near = np.full_like(f, np.nan)
            near[:, max(d, 0):f.shape[1] + min(d, 0)] = f[:, max(-d, 0):f.shape[1] - max(d, 0)]
            seen += np.any(np.abs(near - f[c]) <= PERSIST_TOL_HZ, axis=0)
        keep[c] &= seen >= PERSIST_MIN
    return keep

def analyze(wav):
    x, fs = sf.read(wav, dtype="float32"); fs = int(fs)
    if x.ndim != 2 or x.shape[1] != 2:
        raise SystemExit(f"{wav}: expected 2-channel IQ, got shape {x.shape}")
    z = x[:, 0] + 1j * x[:, 1]
    L = WINDOW_S * fs
    n = len(z) // L
    zz = z[:n * L].reshape(n, L)
    win = np.kaiser(L, KAISER_BETA)
    NF = ZERO_PAD * L
    P = np.abs(np.fft.fftshift(np.fft.fft(zz * win, NF, axis=1), axes=1)) ** 2
    fr = np.fft.fftshift(np.fft.fftfreq(NF, 1.0 / fs))
    r = np.arange(n)
    med = np.median(P, axis=1)
    spec_db = (10 * np.log10(np.maximum(P, 1e-30) / np.maximum(med, 1e-30)[:, None])).astype(np.float32)
    del P
    f_c, s_c = find_carriers(spec_db.copy(), fr)         # find_carriers blanks what it has taken
    pwr_db = 10 * np.log10((np.abs(zz) ** 2).mean(1) + 1e-30)
    good = persistent(f_c, s_c >= SNR_MIN_DB)
    f_c = np.where(good, f_c, np.nan)
    # The strongest carrier keeps its SNR everywhere so pane 2 shows it fading through the mask threshold;
    # the weaker ones exist only where they were detected.
    s_c[1:] = np.where(good[1:], s_c[1:], np.nan)

    # Minute-boundary artifact check on the raw 10 sps series: mean |dA| at the
    # .wv join (sample 0 of each minute) relative to the median over the minute.
    amp = np.abs(z)
    da = np.abs(np.diff(amp))
    m = (len(da) // 600) * 600
    fold = da[:m].reshape(-1, 600).mean(0)
    boundary_ratio = float(fold[0] / max(np.median(fold), 1e-30))

    return dict(fs=fs, n=n, t_h=r * WINDOW_S / 3600.0, f=f_c[0], snr=s_c[0], pwr=pwr_db,
                carrier_f=f_c, carrier_snr=s_c, spec_db=spec_db, spec_f=fr,
                good_frac=float(good[0].mean()),
                multipath_frac=float(good[1].mean()) if len(good) > 1 else 0.0,
                carrier_fracs=[float(g.mean()) for g in good], boundary_amp_ratio=boundary_ratio,
                samples=len(z), zero_samples=int((amp == 0).sum()))

def chart_timezone(meta):
    """(tzinfo or None for the server's zone, description of where it came from), in the search order:
    server zone if not UTC -> GRAPE_CHARTS_TZ -> reporter's grid (timezonefinder, else solar time)."""
    now = datetime.now().astimezone()
    if not (now.utcoffset() == timedelta(0) and now.tzname() in ("UTC", "GMT", "Etc/UTC", "Z", "")):
        return None, "at server"
    name = os.environ.get("GRAPE_CHARTS_TZ", "").strip()
    if name:
        try:
            return ZoneInfo(name), f"per GRAPE_CHARTS_TZ {name}"
        except Exception:
            print(f"WARNING: GRAPE_CHARTS_TZ='{name}' is not a known IANA timezone; ignoring it", file=sys.stderr)
    grid = meta.get("grid") or ""
    latlon = maidenhead_to_latlon(grid)
    if latlon:
        lat, lon = latlon
        try:
            from timezonefinder import TimezoneFinder
            zone = TimezoneFinder().timezone_at(lng=lon, lat=lat)
            if zone:
                return ZoneInfo(zone), f"at grid {grid} ({zone})"
        except ImportError:
            print("NOTE: python package timezonefinder is not installed, so using solar time at the grid (no DST)", file=sys.stderr)
        except Exception as e:
            print(f"WARNING: timezonefinder failed for grid {grid}: {e}", file=sys.stderr)
        hours = int(round(lon / 15.0))
        return timezone(timedelta(hours=hours), f"UTC{hours:+d}"), f"solar time at grid {grid}, no DST"
    return None, "at server (UTC)"

def local_ticks(date_str, tz):
    """For each UTC hour 0..24 of the chart date, the local hour label in timezone tz (None => server's zone).
    Returns (labels, tz_abbrev_at_noon, utc_offset_hours_at_noon); (None, None, None) if the date is unknown."""
    if not date_str:
        return None, None, None
    d = datetime.strptime(date_str, "%Y%m%d").replace(tzinfo=timezone.utc)
    labels = []
    for h in range(25):
        lt = (d + timedelta(hours=h)).astimezone(tz)         # DST-aware per hour
        labels.append(lt.strftime("%H"))
    noon = (d + timedelta(hours=12)).astimezone(tz)
    return labels, noon.strftime("%Z"), noon.utcoffset().total_seconds() / 3600.0

def plot(meta, a, png):
    t, F, S, pwr = a["t_h"], a["carrier_f"], a["carrier_snr"], a["pwr"]
    fin = F[np.isfinite(F)]
    yl = 1.0 if fin.size == 0 else float(min(5.0, max(0.5, np.percentile(np.abs(fin), 99.5) * 1.3)))
    # A narrow second column holds pane 1's colorbar; pane 2's slot is empty so both panes stay one width.
    fig, axs = plt.subplots(2, 2, figsize=(14, 7.6), sharex="col",
                            gridspec_kw=dict(width_ratios=[80, 1], wspace=0.015))
    ax = [axs[0, 0], axs[1, 0]]
    axs[1, 1].axis("off")

    sel = np.abs(a["spec_f"]) <= yl
    dfh = (a["spec_f"][1] - a["spec_f"][0]) / 2
    vmax = max(SPEC_FLOOR_DB + SPEC_SPAN_MIN_DB, float(np.nanpercentile(S[0], 95)))
    im = ax[0].imshow(a["spec_db"][:, sel].T, aspect="auto", origin="lower", cmap="Greys",
                      interpolation="nearest", vmin=SPEC_FLOOR_DB, vmax=vmax,
                      extent=(0, 24, a["spec_f"][sel][0] - dfh, a["spec_f"][sel][-1] + dfh))
    cb = fig.colorbar(im, cax=axs[0, 1]); cb.set_label("dB over median bin", fontsize=8); cb.ax.tick_params(labelsize=7)
    ax[0].plot(t, F[0], lw=0.6, color=CARRIER_COLORS[0], label="strongest carrier")
    for c in range(1, F.shape[0]):
        ax[0].plot(t, F[c], ls="none", marker=".", ms=1.5, color=CARRIER_COLORS[c % len(CARRIER_COLORS)],
                   label=f"carrier {c + 1} ({100 * a['carrier_fracs'][c]:.0f}% of day)")
    ax[0].set_ylabel("carrier offset (Hz)")
    ax[0].set_ylim(-yl, yl); ax[0].axhline(0, color="k", lw=0.4, alpha=0.5)
    ax[0].grid(alpha=0.25, color="0.4"); ax[0].set_axisbelow(False)
    ax[0].legend(loc="upper right", fontsize=8, framealpha=0.85, markerscale=8, ncol=F.shape[0])
    fz = f"{meta['freq_hz']/1e6:g} MHz" if meta.get("freq_hz") else ""
    ax[0].set_title(y=1.22, fontsize=10, label=f"{meta['reporter']}  {meta['receiver']}  {meta['band']} {fz}   {meta['date']} UTC"
                    f"    ({WINDOW_S} s windows; strongest carrier visible {100*a['good_frac']:.0f}% of day, "
                    f"a second path {100*a['multipath_frac']:.0f}%)")
    tz, tz_source = chart_timezone(meta)
    labels, tzname, off = local_ticks(meta["date_yyyymmdd"], tz)
    if labels:
        top = ax[0].secondary_xaxis("top")
        top.set_xticks(range(0, 25, 2)); top.set_xticklabels(labels[0:25:2])
        top.set_xlabel(f"local time {tz_source} ({tzname}, UTC{off:+g})", fontsize=9)
    ax[1].plot(t, pwr, lw=0.6, color="tab:orange", label="carrier power (dBFS)")
    ax[1].set_ylabel("carrier power (dBFS)", color="tab:orange"); ax[1].set_xlabel("UTC hour"); ax[1].grid(alpha=0.3)
    snr_ax = ax[1].twinx()
    snr_ax.plot(t, S[0], lw=0.6, color="tab:green", alpha=0.8,
                label=f"strongest carrier SNR (dB): peak / median 0.1 Hz bin; dashed = {SNR_MIN_DB:g} dB detection threshold")
    snr_ax.axhline(SNR_MIN_DB, color="tab:green", lw=0.7, ls="--", alpha=0.7)
    snr_ax.set_ylabel("carrier SNR (dB)", color="tab:green")
    snr_ax.set_ylim(0, max(40.0, float(np.nanmax(S[0])) * 1.05))
    h1, l1 = ax[1].get_legend_handles_labels(); h2, l2 = snr_ax.get_legend_handles_labels()
    ax[1].legend(h1 + h2, l1 + l2, loc="upper right", fontsize=8, framealpha=0.8)
    ax[1].set_xlim(0, 24); ax[1].set_xticks(range(0, 25, 2))
    fig.text(0.5, 0.006, f"grey = every {WINDOW_S} s spectrum, from {SPEC_FLOOR_DB:g} dB over its median bin "
             f"up, so every path shows however weak; "
             f"dots = carriers >= {SNR_MIN_DB:g} dB that are >= {PEAK_SEP_HZ:g} Hz from and {PROMINENCE_DB:g} dB "
             f"clear of a stronger one and hold their offset over {PERSIST_SPAN * WINDOW_S} s",
             ha="center", fontsize=8, color="0.35")
    plt.tight_layout(rect=(0, 0.022, 1, 1)); plt.savefig(png, dpi=100); plt.close(fig)

def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    wav, out = sys.argv[1], sys.argv[2]
    meta = parse_path(wav)
    a = analyze(wav)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    plot(meta, a, out + ".png")
    def rl(v, nd): return [None if not np.isfinite(x) else round(float(x), nd) for x in v]
    tz, tz_source = chart_timezone(meta)
    _, tzname, off = local_ticks(meta["date_yyyymmdd"], tz)
    # freq_hz_series/power_db/snr_db are the strongest carrier, as they have always been.  The weaker
    # carriers go in extra_carriers, one entry per rank, listed only for the windows they were detected in:
    # window[j] indexes the same 10 s grid the full-length series use.
    extra = []
    for c in range(1, a["carrier_f"].shape[0]):
        at = np.flatnonzero(np.isfinite(a["carrier_f"][c]))
        if at.size:
            extra.append(dict(rank=c + 1, good_frac=round(a["carrier_fracs"][c], 3), window=at.tolist(),
                              freq_hz=rl(a["carrier_f"][c][at], 4), snr_db=rl(a["carrier_snr"][c][at], 1)))
    doc = dict(meta, local_tz=tzname, utc_offset_h=off, local_tz_source=tz_source, window_s=WINDOW_S, snr_min_db=SNR_MIN_DB, n=int(a["n"]),
               samples=a["samples"], zero_samples=a["zero_samples"],
               good_frac=round(a["good_frac"], 3), multipath_frac=round(a["multipath_frac"], 3),
               max_carriers=MAX_CARRIERS, peak_sep_hz=round(PEAK_SEP_HZ, 3),
               boundary_amp_ratio=round(a["boundary_amp_ratio"], 2),
               wav=os.path.abspath(wav),
               freq_hz_series=rl(a["f"], 4), power_db=rl(a["pwr"], 1), snr_db=rl(a["snr"], 1),
               extra_carriers=extra)
    tmp = out + ".json.tmp"
    with open(tmp, "w") as fh: json.dump(doc, fh, separators=(",", ":"))
    os.replace(tmp, out + ".json")
    print(f"{meta['date']} {meta['band']}: {a['n']} windows, carrier visible {100*a['good_frac']:.0f}%, "
          f"2nd carrier {100*a['multipath_frac']:.0f}%, "
          f"boundary |dA| ratio {a['boundary_amp_ratio']:.2f} -> {out}.png")

if __name__ == "__main__":
    main()
