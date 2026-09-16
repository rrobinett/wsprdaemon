# Reference FFTW wisdom

One file per FFTW build string and CPU model, measured once on an idle machine so that no
site has to measure its own plan while its receiver is running.

    wisdom/<fftw build string>/<cpu model slug>.wisdom

The build string is what radiod prints at startup, e.g. `fftw-3.3.10-sse2-avx`; it names the
codelet set FFTW chose, and wisdom is only meaningful within one of them.  The CPU model slug
is `lscpu`'s "Model name" lowercased with every run of non-alphanumeric characters replaced by
a single `-`.

## Why measure on an idle machine

`fftw-wisdom` defaults to FFTW_PATIENT, which chooses between candidate plans by TIMING them.
On a live WD host those timings are taken while radiod's fft thread owns a core and the
decoders burst across the rest, so the ranking reflects the contention as much as the plan.

## How the reference here was measured

`amd-ryzen-7-5825u-with-radeon-graphics.wisdom`, 2026-09-16, on n6gn5: 95,437 bytes, 985 plans.

  - wsprdaemon.service and radiod stopped; the machine measured 99.90% idle
  - pinned with `taskset -c 2` to the core radiod's fft thread runs on, so each plan was chosen
    on the same core, at the same 3.0 GHz ceiling, inside the same resctrl/CAT partition
    (the `radiod` group holds `L3:0=03ff`, 10 of 16 ways = 10 MB)
  - `fftwf-wisdom -v -T 1 -n -w <previous reference> -o ...` over the 86-spec union below.
    `-n` so it did not read system wisdom; `-w` so the 3,240,000 and 1,620,000 point forward
    transforms were imported from the previous measurement rather than measured again.
  - 15:53.53 elapsed, 953.16 s user, 99% CPU, exit 0

The big forward transform was measured separately on 2026-09-15 under the same conditions and
took 1:47:51 on its own.

## Getting the spec list right -- read fft.log, do not guess

ka9q-radio never measures a plan.  `src/filter.c` asks for `FFTW_WISDOM_ONLY|FFTW_PATIENT` and,
on a miss, falls straight to `FFTW_ESTIMATE` -- then logs the transform it could not find to
`/var/lib/ka9q-radio/fft.log`, in exactly the syntax `fftwf-wisdom` takes as arguments:

    fprintf(FFT_log,"%c%c%c%d\n", 'r', in==out?'i':'o', 'f', N);     ->  rof3240000

So coverage is binary and per transform, and the authoritative list of what a site actually
needs is that log.  WD's hand-written spec list was not that list: it planned `rof3240000` and a
`cob` ladder, while n6gn5's fft.log held **56 distinct transforms** it had never planned --
17 `cif`, 16 `cob`, 13 `rof`, 10 `cof` -- with 26,535 fallbacks recorded, 17,713 of them `cif300`
alone.  Every spectrum zoom level in ka9q-web asks for a `cof`/`cob`/`cif` triple at a new bin
count, and not one of them was covered.

This reference was built from the union of WD's 33 specs and those 56.

**Acceptance test.** After installing it and restarting radiod, `fft.log` did not grow by a single
line -- through steady-state operation and through a walk over every ka9q-web zoom level.  That is
the check to repeat when adding a reference for another CPU: the log must stop growing.

## Installed as the SYSTEM wisdom, not over the site's own

radiod imports `/etc/fftw/wisdomf` and then `/var/lib/ka9q-radio/wisdom`, and FFTW accumulates
both.  So WD installs a reference as the system file and leaves the site's own file alone.
Nothing a site has measured is lost, and the reference fills in what it lacks.
