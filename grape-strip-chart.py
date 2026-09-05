#!/usr/bin/env python3
"""Make a 24-hour carrier strip chart from a WD GRAPE 24_hour_10sps_iq.wav.

Part of wsprdaemon (WD 3.4.6+).  Called by grape_create_chart() in grape-utils.sh; can also be run by hand.

usage: grape_strip_chart.py  IN.wav  OUT_BASE      -> OUT_BASE.png and OUT_BASE.json

Pane 1: carrier frequency offset (Hz) from the channel center, estimated as the
        interpolated FFT peak of each 10 s window; masked where the peak is < SNR_MIN_DB
        above the window's median spectral bin (no carrier, just noise).
Pane 2: carrier power (dBFS) = mean power of each 10 s window.
The JSON holds the same series so the web page can overlay days/bands.
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

WINDOW_S   = 10      # seconds per estimate -> 8640 points/day
SNR_MIN_DB = 15.0    # mask frequency estimates below this peak/median ratio
ZERO_PAD   = 8

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

def analyze(wav):
    x, fs = sf.read(wav, dtype="float32"); fs = int(fs)
    if x.ndim != 2 or x.shape[1] != 2:
        raise SystemExit(f"{wav}: expected 2-channel IQ, got shape {x.shape}")
    z = x[:, 0] + 1j * x[:, 1]
    L = WINDOW_S * fs
    n = len(z) // L
    zz = z[:n * L].reshape(n, L)
    win = np.hanning(L)
    NF = ZERO_PAD * L
    P = np.abs(np.fft.fftshift(np.fft.fft(zz * win, NF, axis=1), axes=1)) ** 2
    fr = np.fft.fftshift(np.fft.fftfreq(NF, 1.0 / fs))
    df = fr[1] - fr[0]
    k = np.clip(P.argmax(1), 1, NF - 2)
    r = np.arange(n)
    y0, y1, y2 = P[r, k - 1], P[r, k], P[r, k + 1]
    den = y0 - 2 * y1 + y2
    delta = np.where(den != 0, 0.5 * (y0 - y2) / np.where(den != 0, den, 1), 0.0)
    f_est = fr[k] + delta * df
    med = np.median(P, axis=1)
    snr_db = 10 * np.log10(np.maximum(y1, 1e-30) / np.maximum(med, 1e-30))
    pwr_db = 10 * np.log10((np.abs(zz) ** 2).mean(1) + 1e-30)
    good = snr_db >= SNR_MIN_DB
    f_masked = np.where(good, f_est, np.nan)

    # Minute-boundary artifact check on the raw 10 sps series: mean |dA| at the
    # .wv join (sample 0 of each minute) relative to the median over the minute.
    amp = np.abs(z)
    da = np.abs(np.diff(amp))
    m = (len(da) // 600) * 600
    fold = da[:m].reshape(-1, 600).mean(0)
    boundary_ratio = float(fold[0] / max(np.median(fold), 1e-30))

    return dict(fs=fs, n=n, t_h=r * WINDOW_S / 3600.0, f=f_masked, snr=snr_db, pwr=pwr_db,
                good_frac=float(good.mean()), boundary_amp_ratio=boundary_ratio,
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
    t, f, pwr = a["t_h"], a["f"], a["pwr"]
    fin = f[np.isfinite(f)]
    yl = 1.0 if fin.size == 0 else float(min(5.0, max(0.5, np.percentile(np.abs(fin), 99.5) * 1.3)))
    fig, ax = plt.subplots(2, 1, figsize=(14, 7.6), sharex=True)
    ax[0].plot(t, f, lw=0.6, color="tab:blue")
    ax[0].set_ylabel("carrier offset (Hz)")
    ax[0].set_ylim(-yl, yl); ax[0].axhline(0, color="k", lw=0.4, alpha=0.5); ax[0].grid(alpha=0.3)
    fz = f"{meta['freq_hz']/1e6:g} MHz" if meta.get("freq_hz") else ""
    ax[0].set_title(y=1.22, label=f"{meta['reporter']}  {meta['receiver']}  {meta['band']} {fz}   {meta['date']} UTC"
                    f"    ({WINDOW_S} s windows; freq shown only where carrier SNR >= {SNR_MIN_DB:g} dB, "
                    f"{100*a['good_frac']:.0f}% of day)")
    tz, tz_source = chart_timezone(meta)
    labels, tzname, off = local_ticks(meta["date_yyyymmdd"], tz)
    if labels:
        top = ax[0].secondary_xaxis("top")
        top.set_xticks(range(0, 25, 2)); top.set_xticklabels(labels[0:25:2])
        top.set_xlabel(f"local time {tz_source} ({tzname}, UTC{off:+g})", fontsize=9)
    ax[1].plot(t, pwr, lw=0.6, color="tab:orange", label="carrier power (dBFS)")
    ax[1].set_ylabel("carrier power (dBFS)", color="tab:orange"); ax[1].set_xlabel("UTC hour"); ax[1].grid(alpha=0.3)
    snr_ax = ax[1].twinx()
    snr_ax.plot(t, a["snr"], lw=0.6, color="tab:green", alpha=0.8,
                label=f"carrier SNR (dB): peak / median 0.1 Hz bin; dashed = {SNR_MIN_DB:g} dB freq mask")
    snr_ax.axhline(SNR_MIN_DB, color="tab:green", lw=0.7, ls="--", alpha=0.7)
    snr_ax.set_ylabel("carrier SNR (dB)", color="tab:green")
    snr_ax.set_ylim(0, max(40.0, float(np.nanmax(a["snr"])) * 1.05))
    h1, l1 = ax[1].get_legend_handles_labels(); h2, l2 = snr_ax.get_legend_handles_labels()
    ax[1].legend(h1 + h2, l1 + l2, loc="upper right", fontsize=8, framealpha=0.8)
    ax[1].set_xlim(0, 24); ax[1].set_xticks(range(0, 25, 2))
    plt.tight_layout(); plt.savefig(png, dpi=100); plt.close(fig)

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
    doc = dict(meta, local_tz=tzname, utc_offset_h=off, local_tz_source=tz_source, window_s=WINDOW_S, snr_min_db=SNR_MIN_DB, n=int(a["n"]),
               samples=a["samples"], zero_samples=a["zero_samples"],
               good_frac=round(a["good_frac"], 3), boundary_amp_ratio=round(a["boundary_amp_ratio"], 2),
               wav=os.path.abspath(wav),
               freq_hz_series=rl(a["f"], 4), power_db=rl(a["pwr"], 1), snr_db=rl(a["snr"], 1))
    tmp = out + ".json.tmp"
    with open(tmp, "w") as fh: json.dump(doc, fh, separators=(",", ":"))
    os.replace(tmp, out + ".json")
    print(f"{meta['date']} {meta['band']}: {a['n']} windows, carrier visible {100*a['good_frac']:.0f}%, "
          f"boundary |dA| ratio {a['boundary_amp_ratio']:.2f} -> {out}.png")

if __name__ == "__main__":
    main()
