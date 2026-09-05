#!/usr/bin/env python3
"""Scan the WD grape-charts/www dir for chart JSON files and write www/manifest.json (newest first).
Part of wsprdaemon; called by grape_charts_update_manifest() in grape-utils.sh.  usage: grape-charts-manifest.py WWW_DIR"""
import sys, os, json, glob
www = sys.argv[1]
entries = []
for j in glob.glob(os.path.join(www, "*", "*", "*", "*.json")):
    try:
        with open(j) as fh:
            d = json.load(fh)
    except Exception as e:
        print("skip", j, e, file=sys.stderr); continue
    rel = os.path.relpath(j, www)
    entries.append(dict(date=d["date"], reporter=d["reporter"], receiver=d["receiver"], band=d["band"],
                        freq_hz=d.get("freq_hz") or 0, good_frac=d.get("good_frac"),
                        boundary_amp_ratio=d.get("boundary_amp_ratio"), zero_samples=d.get("zero_samples"),
                        local_tz=d.get("local_tz"), utc_offset_h=d.get("utc_offset_h"), local_tz_source=d.get("local_tz_source"),
                        json=rel, png=rel[:-5] + ".png"))
entries.sort(key=lambda e: (e["date"], e["reporter"], e["receiver"], e["freq_hz"]), reverse=True)
out = dict(generated_utc=__import__("time").strftime("%Y-%m-%d %H:%M:%S", __import__("time").gmtime()),
           host=os.uname().nodename, entries=entries)
tmp = os.path.join(www, "manifest.json.tmp")
with open(tmp, "w") as fh: json.dump(out, fh)
os.replace(tmp, os.path.join(www, "manifest.json"))
print(f"manifest: {len(entries)} charts")
