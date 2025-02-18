# The ka9q-radio [hardware] section

A typical configuration of this section for wsprdaemon use follows:

```
[rx888]
device = "rx888" # required so it won't be seen as a demod section
description = "rx888 wsprdaemon" # good to put callsign and antenna description in here
#gain = 20 # dB
# rest are defaults
#description = "rx888"
#number = 0
#samprate = 129600000     # Hz
samprate =   64800000     # 128 Msps will eventual burn out the stock RX888 Mk II, and this 64 Msps frees much CPU on older CPUs
#calibrate = 0            # 1e-6 is +1 ppm
#firmware = SDDC_FX3.img
#queuedepth = 16          # buffers in USB queue
#reqsize = 32             # size of each USB buffer in 16KB units
#dither = no              # built-in A/D dither
#rand = no                # Randomize A/D output bits to spread digital->analog crosstalk
#att = 0                  # PE4312 digital attenuator, 0-31.5 dB in 0.5 dB steps
#gainmode = high          # AD8370 VGA gain mode
#gain = 1.5               # AD8370 VGA gain, -25 to +17 dB (low gain mode) or -8 to +34 dB (high gain mode)
```

Phil Karn's comprehensive documentation of this section:

## Hardware Configuration
----------------------

This document describes the hardware definition section in a *radiod*
config file.  The section name must match the **hardware** entry in
the [global] section, e.g.,

[global]  
hardware = airspy  
...

[airspy]  
device = airspy  
description = "airspy on 2m antenna"


In this example the name of the hardware definition section matches
the device type, but this is not required.

### Supported Hardware
------------------

Six SDR front ends are currently supported in *ka9q-radio*:

[airspy](airspy.md) - Airspy R2, Airspy Mini]  
[airspyhf](airspy.md) - Airspy HF+  
[funcube](funcube.md) - AMSAT UK Funcube Pro+ dongle  
[rx888](rx888.md) - RX888 Mkii (direct conversion only)  
[rtlsdr](rtlsdr.md) - Generic RTL-SDR dongle (VHF/UHF only)  
[sig_gen](sig_gen.md) - synthetic front end with signal generator (to be documented)

The configuration of each device type is necessarily
hardware-dependent, so separate documents describe the options unique
to each one. Only the parameters common to all of them are described
here. In most cases, the default hardware-specific options need not be changed.

#### device = {airspy|airspyhf|funcube|rx888|rtlsdr|sig_gen} (no default, required)

Select the front end hardware type. If there is only one such device
on a system, it will automatically be selected. If there's more than one,
it can usually be selected by serial number.

The funcube does not have serial
numbers so this is not possible.

Support for multiple rx888s (which has serial numbers) is not yet supported.
I don't recommend more than one per system because of the heavy load they place on the USB controller.
Each rx888 running at full sample rate generates a little over 2 Gb/s of data.x


#### description = (no default, optional but recommended)

Gives free-format text that
will be advertised through the *radiod* program to the
control/status stream and the *control* program that
listens to it. It will also be advertised in DNS SRV (service
discovery) records by the Linux mDNS daemon *avahi*, so keep
it short but descriptive.

The sections defining groups of receiver channels are omitted. See **ka9q-radio.md** for details on the options
for those sections.

Multiple instances of *radiod* can run on the same system, provided each has its own front end (they cannot be shared).
You can have as many as you want, subject to your CPU and USB limits.
The RX888 MkII produces a real flood of bits: over 2Gb/s at a sample rate of 129.6 MHz, which is why it uses USB 3.
While a midrange x86 is enough to handle the processing requirements, they are not exactly insubstantial either so I recommend
only one per host.

In the excerpt above, the **hardware** entry in the [global] section specifies the section containing RX888 configuration
information. (In this example the name of the hardware section happens to be the same as the device type, but it is not essential.)

Only one entry is mandatory: **device**. This specifies the front end hardware type, i.e, "rx888", which means an RX-888 MkII.
The defaults should be good for most cases, but you can override them as needed.

**description** Optional. Free-format text to
advertise through the *radiod* program on the
control/status stream to the *control* program that
listens to it. It will also be advertised in DNS SRV (service
discovery) records by the Linux mDNS daemon *avahi*, so keep
it short but descriptive.

**number** Optional, default 0.
Select the index of the RX-888 to use if there's more than one on the system. Probably won't do what you want since the multiple
devices are enumerated in undefined order.
It will be possible to select a unit by serial number but this isn't a high priority because it's unlikely you'll have more than one on a system for performance reasons. Nor do I recommend it.

**samprate** Integer, default 64,800,000 Hz (64.8 MHz). 
Set the A/D sample rate. The RX-888 MkII is actually rated for 130 MHz but several users have had thermal problems so the default is to run it at half speed.
Full rate would be 129600000 (129.6 MHz). This is below the 130 MHz rating of the LTC2208 A/D converter and can be generated by small rational factors from the 27 MHz clock. This
improves phase noise from the Si5351 clock generator.

**gain** Decimal, default +1.5 dB.
Set the gain of the AD8370 analog
VGA ahead of the A/D converter. There is no front end AGC in hardware or software (yet) so this
should be set with some care. Choose a value that results in an RMS
A/D output level of -20 to -25 dBFS. I generally use +10 dB and may
make this the default.

**att** Decimal, range 0 to 31.5 dB in 0.5 dB steps, default 0.
Set the attenuation of the PE4312 attenuator ahead of the AD8370 variable gain amplifier.

**gainmode** String, either "high" or "low", default "high".
Set the gain mode of the AD8370 variable gain amplifier. The gains available in the two modes overlap, but even at the same gain the noise figure in "low" mode is considerably higher (worse) than in high mode. Use gainmode=low only if resistance to strong signals (i.e., increasing the IP3) is especially important.

**bias** Boolean, default off. Enable the bias tee (preamplifier
power).

**calibrate** Decimal, default 0.  Set the clock error fraction for
the built-in 27 MHz sampling clock.  A value of -1e-6 means that the
sample clock frequency is 1 part per million (ppm) low.  The
correction is currently done with an ***experimental*** sample
interpolation scheme that corrects both the tuning frequency and the
output sample rate.  It works, but the CPU usage is high and creates
an annoying "chugging" sound in the background noise at low signal
levels (e.g., at upper HF frequencies) that I don't fully understand.
There are other correction methods (such as simply biasing the tuning
frequency) that use little CPU but this wouldn't also correct the
output sample rate. So this is purely experimental. If you need a precise
sampling clock, I recommend opening the unit and finding the connector
for an external 27 MHz frequency reference.

**firmware** String, default "SDDC_FX3.img".
Specify the path name of the firmware file to be loaded into the unit at startup. If not absolute it will be relative to /usr/local/share/ka9q-radio.

**queuedepth** Integer, default 16.
The number of buffers to be queued up for transfer over the USB. Larger numbers have occasionaly given problems.

**reqsize** Integer, default 32.
Set the size of each transfer buffer in internal units, which apparently defaults to 16 KB. reqsize = 32 therefore corresponds to 512KB per buffer, or 8 MB for all 16. This affects latency, but at these high sample rates the effect is minimal (a few milliseconds, compared to the typically 20 ms of latency inside *radiod* itself.)

**dither** Boolean, default no.
Enable the built-in dither feature of the LTC2208 A/D converter. Doesn't seem necessary given that antenna noise is almost certainly much greater than the quantization
noise floor of this 16 bit A/D. It's probably exceeded even by the thermal noise of the VGA.

**rand** Boolean, default no.
Enable the data randomization feature of the LTC2208 A/D converter and automatically de-randomizes the data after reception. This is supposed to lower spurs resulting from digital-to-analog crosstalk
on the circuit board. The actual benefit hasn't been measured, but the CPU cost is minimal.
