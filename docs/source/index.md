
# WSPRDAEMON Documentation

Welcome to the comprehensive documentation for WsprDaemon v3.3.2, a robust Linux service for decoding WSPR and FST4W spots from KiwiSDR and RX888 SDRs.

## Getting Started

New to WsprDaemon? Start here for a quick overview and rapid deployment.

```{toctree}
:maxdepth: 2
:caption: Getting Started

getting_started/quick_start.md
description/how_it_works.md
description/history.md
description/validity.md
```

## Installation & Setup

Complete guides for installing and configuring WsprDaemon on your system.

```{toctree}
:maxdepth: 2
:caption: Installation & Setup

requirements/os.md
requirements/radios.md
requirements/network.md
installation/preparation.md
installation/security_considerations.md
installation/git.md
```

## Configuration Reference

Detailed configuration options and examples for all WsprDaemon features.

```{toctree}
:maxdepth: 2
:caption: Configuration Reference

configuration/wd_conf.md
configuration/radiod_conf.md
configuration/ka9q-web.md
```

## Operation & Monitoring

Day-to-day operation, monitoring, and maintenance of your WsprDaemon installation.

```{toctree}
:maxdepth: 2
:caption: Operation & Monitoring

operation/service_management.md
operation/monitoring.md
maintenance/operating.md
maintenance/monitoring.md
maintenance/aliases.md
```

## Features & Results

Understanding WsprDaemon's capabilities and the data it produces.

```{toctree}
:maxdepth: 2
:caption: Features & Results

results/wspr.md
results/grape.md
results/psk.md
```

## Troubleshooting & Support

Diagnostic tools and solutions for common issues.

```{toctree}
:maxdepth: 2
:caption: Troubleshooting & Support

troubleshooting/overview.md
troubleshooting/typicals.md
troubleshooting/diagnostic_tools.md
FAQ.md
```

## Examples & Advanced Topics

Real-world configurations and advanced architectural information.

```{toctree}
:maxdepth: 2
:caption: Examples & Advanced Topics

examples/common_configurations.md
architecture/data_flow.md
architecture/network_security.md
```

## Developer Documentation

Resources for contributors and developers working on WsprDaemon.

```{toctree}
:maxdepth: 2
:caption: Developer Documentation

developers/getting_started.md
developers/remote_development.md
```

## Reference & Resources

Additional resources and external links.

```{toctree}
:maxdepth: 1
:caption: Reference & Resources

appendices/command_reference.md
external_links.md
contributors.md
```

---

## Quick Links

- **[15-Minute Quick Start](getting_started/quick_start.md)** - Get running fast
- **[FAQ](FAQ.md)** - Common questions and answers
- **[Troubleshooting](troubleshooting/diagnostic_tools.md)** - Problem diagnosis
- **[Configuration Examples](examples/common_configurations.md)** - Real-world setups

## About WsprDaemon

WsprDaemon runs as a Linux service to decode WSPR and FST4W spots from one or more receivers and reliably posts them to wsprnet.org. Key features include:

- **Multi-receiver Support**: Merge spots from multiple receivers for best SNR
- **Advanced Scheduling**: Time-based and sunrise/sunset relative band switching  
- **Noise Measurement**: Background noise level recording and graphing
- **Scientific Integration**: GRAPE system support for ionospheric research
- **High Reliability**: Automatic recovery from outages with local caching
- **Broad Hardware Support**: KiwiSDR, RX888, RTL-SDR, and other SDR platforms

Most of the top 20+ spotting sites at [wspr.rocks/topspotters](http://wspr.rocks/topspotters/) run WsprDaemon, collectively reporting about 33% of the 7+ million daily spots at wsprnet.org.
