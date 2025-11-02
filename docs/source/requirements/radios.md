# Compatible Radios

Please note, for the present and in collaboration with HamSCI efforts, WD supports kiwiSDR and RX888.  The documentation here also primarily addresses the configuration and use of WD with those two radios.  

## KiwiSDR

## Radios that work with ka9q-radio

### RX888

The RX888 connects to your computer via a USB 3 -- SuperSpeed connection.  These typically have a BLUE tab on the computer socket as distinct from the white or black for USB 2. However, apparently not all blue USB sockets support superspeed or the OS sometimes does not assign drivers properly. Use `lsusb` at the CLI if you have trouble.  If the RX888 does not identify on a USB 3 controller, try another blue socket.


As delivered the RX888 has sub-optimal thermal protection and for radio science applications it needs an external GPSDO @ 27 MHz clock (although you can alter this).

Paul Elliott WB6CXC created a screwdriver-only kit which enhances the thermal protection and adds a ground-isolated external clock SMA input port. Paul describes the installation and use of his kit on [his website](https://turnislandsystems.com/wp-content/uploads/2024/05/RX888-Kit-2.pdf)

The kit is available at [the TAPR web store](https://tapr.org/product/rx888-clock-kit-and-thermal-pad/).

### Airspy variants

- Airspy R2
- Airspy HF+

### RTL-SDR

### SDRPLAY variants

Not directly suppported by radiod.  
- RSPduo
- RSPdx

### FobosSDR

### Others...

- Funcube Dongle
- OpenHPSDR variants
