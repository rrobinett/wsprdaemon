# History

## WsprDaemon Development Timeline

### Origins (2018)
WsprDaemon was originally developed by Rob Robinett AI6VN in July 2018, starting as a Mac OSX project before being ported to Raspberry Pi 3b+. The initial goal was to improve upon the built-in autowspr mode of KiwiSDR receivers by:

- Processing uncompressed audio through the latest 'wsprd' utility from WSJT-x
- Implementing deep search mode (`wsprd -d`) for 10% more signal detection
- Leveraging more powerful CPUs for better performance on busy bands

### Major Version History

**Version 1.x (2018-2019)**
- Initial release supporting KiwiSDR receivers
- Basic WSPR decoding and reporting to wsprnet.org
- Raspberry Pi 3b+ support with up to 12 simultaneous sessions

**Version 2.x (2019-2020)**
- Enhanced multi-receiver support
- Spot merging capabilities
- Background noise level recording
- Improved reliability and error recovery

**Version 3.0.x (2020-2021)**
- Major architecture refactoring
- Added support for multiple SDR types
- Enhanced scheduling capabilities
- Improved logging and monitoring

**Version 3.1.x (2021-2022)**
- KA9Q-radio integration
- RX888 SDR support
- WSPR-2 spectral spreading reports
- GRAPE system integration for ionospheric research
- Fixed AGC level support for KA9Q receivers

**Version 3.2.x (2023-2024)**
- Universal binary support (all wsprd and jt9 binaries included)
- Raspberry Pi 5 compatibility
- KA9Q-web interface
- FT4/8 reporting capabilities
- Enhanced performance optimizations

**Version 3.3.x (2024-Present)**
- Current stable release
- Improved reliability and performance
- Enhanced documentation
- Broader hardware compatibility

### Key Milestones

**2018**: First deployment on Raspberry Pi systems
**2019**: Integration with major WSPR monitoring networks
**2020**: Adoption by top-spotting sites (20+ sites using WD)
**2021**: KA9Q-radio integration expanding SDR support
**2022**: GRAPE system integration for scientific research
**2023**: Multi-platform binary distribution
**2024**: Enhanced web interfaces and monitoring

### Community Impact

WsprDaemon has become a cornerstone of the WSPR monitoring community:

- **Network Contribution**: WD-powered sites report approximately 33% of the 7+ million daily spots recorded at wsprnet.org
- **Top Spotters**: Most of the 20+ "top spotting" sites listed at wspr.rocks/topspotters/ run WsprDaemon
- **Scientific Research**: Integration with HamSCI GRAPE system enables ionospheric research
- **Global Coverage**: Installations worldwide provide comprehensive propagation monitoring

### Technical Evolution

The project has evolved from a simple KiwiSDR enhancement to a comprehensive WSPR monitoring platform:

- **Hardware Support**: Expanded from KiwiSDR-only to supporting RX888, RTL-SDR, AirSpy, and other SDRs
- **Processing Power**: Optimized for everything from Raspberry Pi to high-end x86 systems
- **Data Collection**: Beyond basic spots to include noise measurements, Doppler shift, and propagation metrics
- **Reliability**: "Home appliance" reliability with automatic recovery from outages
- **Integration**: APIs and interfaces for external monitoring and research systems

### Acknowledgments

WsprDaemon builds upon the foundational work of:
- **Joe Taylor K1JT** and the WSJT-x development team for the wsprd decoder
- **John Seamons** for the KiwiSDR and kiwirecorder.py utility
- **Phil Karn KA9Q** for the KA9Q-radio software suite
- **The WSPR community** for testing, feedback, and contributions
- **HamSCI** for scientific collaboration and GRAPE integration

The project continues to evolve with contributions from the amateur radio and scientific communities, maintaining its position as a leading platform for WSPR monitoring and propagation research.
