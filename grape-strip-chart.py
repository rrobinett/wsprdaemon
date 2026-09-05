#!/usr/bin/env python3
"""Make a 24-hour carrier strip chart from a WD GRAPE 24_hour_10sps_iq.wav.

Part of wsprdaemon (WD 3.4.6+).  Called by grape_create_chart() in grape-utils.sh; can also be run by hand.

usage: grape_strip_chart.py  IN.wav  OUT_BASE      -> OUT_BASE.png and OUT_BASE.json

Pane 1: carrier frequency offset (Hz) from the channel center, estimated as the
        interpolated FFT peak of each 10 s window; masked where the peak is < SNR_MIN_DB
        above the window's median spectral bin (no carrier, just noise).
Pane 2: carrier power (dBFS) = mean power of each 10 s window.
The JSON holds the same series so the web page can overlay days/bands.
"""
import sys, os, json, glob, re
from datetime import datetime, timezone, timedelta
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
    freq_hz = None
    for f in sorted(glob.glob(os.path.join(band_dir, "*_iq.wv")))[:1]:
        m = re.search(r"_(\d+)_iq\.wv$", f)
        if m: freq_hz = int(m.group(1))
    return dict(date=date, reporter=rep, receiver=rcv, band=band, freq_hz=freq_hz)

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

def local_ticks(date_str):
    """For each UTC hour 0..24 of the chart date, the local (server timezone) hour label.
    Returns (labels, tz_abbrev_at_noon, utc_offset_hours_at_noon)."""
    d = datetime.strptime(date_str, "%Y%m%d").replace(tzinfo=timezone.utc)
    labels = []
    for h in range(25):
        lt = (d + timedelta(hours=h)).astimezone()          # server's local zone, DST-aware per hour
        labels.append(lt.strftime("%H"))
    noon = (d + timedelta(hours=12)).astimezone()
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
    labels, tzname, off = local_ticks(meta["date"])
    top = ax[0].secondary_xaxis("top")
    top.set_xticks(range(0, 25, 2)); top.set_xticklabels(labels[0:25:2])
    top.set_xlabel(f"local time at server ({tzname}, UTC{off:+g})", fontsize=9)
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
    _, tzname, off = local_ticks(meta["date"])
    doc = dict(meta, local_tz=tzname, utc_offset_h=off, window_s=WINDOW_S, snr_min_db=SNR_MIN_DB, n=int(a["n"]),
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
