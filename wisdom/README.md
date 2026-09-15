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

`amd-ryzen-7-5825u-with-radeon-graphics.wisdom`, 2026-09-15, on n6gn5:

  - wsprdaemon.service and radiod stopped; the machine measured 99.90% idle
  - pinned with `taskset -c 2` to the core radiod's fft thread runs on, so the plan was chosen
    on the same core, at the same 3.0 GHz ceiling, inside the same resctrl/CAT partition
    (the `radiod` group holds `L3:0=03ff`, 10 of 16 ways = 10 MB)
  - `fftwf-wisdom -v -T 1 -n <specs>` -- `-n` so it did NOT read the existing system wisdom,
    making this a clean from-scratch measurement rather than an accumulation
  - 1:47:51 elapsed, 6469.89 s user, 99% CPU, exit 0, all 33 transforms planned

The result is 15,121 bytes and 156 plans.  Note that this is the same SIZE as the files a
number of sites already carry: a complete plan of WD's spec list is a ~15 KB file, and a
larger file means extra sizes accumulated from elsewhere, not a more thorough job.

## Installed as the SYSTEM wisdom, not over the site's own

radiod imports `/etc/fftw/wisdomf` and then `/var/lib/ka9q-radio/wisdom`, and FFTW accumulates
both.  So WD installs a reference as the system file and leaves the site's own file alone.
Nothing a site has measured is lost, and the reference fills in what it lacks -- which is not a
theoretical concern: comparing all 50 collected fleet wisdom files against this reference, EVERY
one was missing between 32 and 155 of its entries, including files three times its size.
