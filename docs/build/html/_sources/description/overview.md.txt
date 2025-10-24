# wsprdaemon Overview

This document provides a comprehensive summary of the `wsprdaemon` project, a sophisticated system for receiving, decoding, and reporting Weak Signal Propagation Reporter (WSPR) and FST4W signals. The analysis is based on the content of the official GitHub repository.

## 1. Project Purpose and Overview

`wsprdaemon` is a Linux-based service designed to operate as a reliable, autonomous appliance for amateur radio operators and researchers. Its primary function is to decode WSPR and FST4W spots from one or more Software-Defined Radios (SDRs) and reliably upload them to public databases like wsprnet.org. The project emphasizes high reliability, advanced features, and scientific data collection, going far beyond the capabilities of standard tools like WSJT-X.

As stated in the project's `README.md`:

> Wsprdaemon (WD) runs as a Linux service to decode WSPR and FST4W spots from one or more [Kiwis] and/or RX888 SDRs and *reliably* post them to [wsprnet.org]. It includes many features not found in WSJT-x, including multiple band and/or multiple receiver support. WD also records additional information about spots like doppler shift and background noise level which permit much deeper understanding of propagation conditions. [1]

The system is notable for its robustness, with features to automatically recover from power and internet outages, caching all gathered data until successful delivery is confirmed. It is a significant contributor to the WSPR network, with the documentation noting that top spotting sites running `wsprdaemon` account for approximately 33% of the millions of spots reported daily.

## 2. Core Functionality

`wsprdaemon` offers a rich feature set tailored for advanced and large-scale WSPR monitoring operations.

| Feature | Description |
| :--- | :--- |
| **Multi-Receiver Support** | Can simultaneously process signals from multiple SDRs, such as KiwiSDRs and RX888s. |
| **Spot Merging** | For a given band, it can merge spots from multiple receivers (e.g., different antennas) and report only the one with the best Signal-to-Noise Ratio (SNR). |
| **Advanced Scheduling** | Allows users to create complex schedules to switch between different bands at specific times of the day or at times relative to sunrise and sunset. This is particularly useful for receivers with a limited number of channels. |
| **Reliable Uploading** | Caches all decoded spots and associated data locally. It ensures data is delivered to upstream servers (like wsprnet.org) by retrying uploads after network or power interruptions. |
| **Noise Measurement** | Records background noise levels, allowing for the creation of noise graphs and deeper analysis of band conditions. This data can be uploaded to services like graphs.wsprdaemon.org. |
| **Scientific Data Collection** | Integrates with the HamSCI GRAPE (Great American Radio Propagation Experiment) project by recording and uploading I/Q data of WWV and CHU time-signal broadcasts for ionospheric research. |
| **Multiple Decode Modes** | Supports various WSPR and FST4W modes, including deep search options (`wsprd -d`) for enhanced sensitivity. |
| **Daemon-based Operation** | Runs as a collection of background daemons, managed by a central watchdog process, ensuring continuous, unattended operation. |

## 3. System Architecture

The architecture of `wsprdaemon` is modular and heavily based on shell scripting to coordinate a pipeline of tasks. The system is designed as a series of daemons that handle specific stages of the process, from data acquisition to final reporting.

The high-level data flow is as follows:

1.  **Audio Capture (`recording.sh`):** The process begins with capturing audio (or I/Q data) from the configured SDRs. For KiwiSDRs, it uses `kiwirecorder.py`. For RX888 receivers, it leverages the `ka9q-radio` software suite. The system records audio into precisely timed 2-minute WAV files, synchronized with the global WSPR transmission schedule.

2.  **Signal Decoding (`decoding.sh`):** Once a WAV file is created, a decoding daemon processes it. The core decoding is performed by `wsprd`, a command-line utility from the WSJT-X software suite. `wsprdaemon` can utilize the deep search mode of `wsprd` to maximize the number of decoded spots.

3.  **Data Aggregation and Merging (`posting.sh`):** Decoded spots are passed to a posting daemon. If multiple receivers are monitoring the same band, this stage is responsible for merging the spots and selecting the best one based on SNR.

4.  **Data Uploading (`upload-client-utils.sh`):** The final stage involves formatting the spot data and uploading it to various external services. The system has dedicated logic for posting to wsprnet.org, pskreporter.info, and the project's own data collection server at wsprdaemon.org, which stores extended information like noise levels.

This entire process is supervised by a `watchdog.sh` script, which periodically checks the health of all running daemons, manages job schedules, and handles process restarts, ensuring the system's resilience.

## 4. Code Organization and Implementation

The repository is a large project, comprising over 24,000 lines of code. The implementation is a mix of shell scripts, Python, and C, with each language used for tasks suited to its strengths.

| Language | Lines of Code (approx.) | Primary Role |
| :--- | :--- | :--- |
| **Shell (Bash)** | 18,000 | **Core Orchestration.** The vast majority of the system's logic, including the main entry point (`wsprdaemon.sh`), daemon management, scheduling, and the overall processing pipeline, is implemented in a series of interconnected shell scripts. |
| **Python** | 4,000 | **Supporting Tools and Server Components.** Python is used for various utility scripts (`noise_plot.py`, `wav2grape.py`) and for the server-side components (`wsprdaemon_server.py`, `wsprdaemon_reflector.py`) that receive data from client installations. |
| **C** | 3,000 | **High-Performance Data Capture.** C is used for performance-critical tasks, specifically for recording audio data from SDRs. Files like `wd-record.c` and `pcmrecord.c` are used to capture data from `ka9q-radio` streams efficiently. |

Key files and directories in the repository include:

-   `wsprdaemon.sh`: The main entry point and command-line interface for the entire system.
-   `*.sh` files: A large collection of modular shell scripts, each handling a specific part of the system (e.g., `decoding.sh`, `recording.sh`, `posting.sh`, `watchdog.sh`).
-   `wsprdaemon.conf` / `wd_template.conf`: The configuration file where users define their station parameters, receivers, and schedules.
-   `docs/`: Contains extensive documentation in Markdown format, which is built into a ReadTheDocs website.
-   `ka9q-radio/`: A git submodule containing the `ka9q-radio` SDR software, which is a key dependency for RX888 support.
-   `*.py` files: Various Python scripts for tasks like noise analysis, data conversion, and server-side logic.
-   `*.c` files: C source code for custom data recording tools.

## 5. Configuration and Usage

`wsprdaemon` is configured via a single file, `wsprdaemon.conf`, which is a shell script that sets various environment variables. The user must define:

-   **Reporter Information:** Callsign and grid square (`WSPRNET_REPORTER_ID`, `REPORTER_GRID`).
-   **Receiver List (`RECEIVER_LIST`):** A list of all SDRs the system will use, including their type, address, and credentials.
-   **Schedule (`WSPR_SCHEDULE`):** A detailed schedule that tells the system which receiver should listen on which band at what time and with which decoding modes.

The system is controlled from the command line using the `wsprdaemon.sh` script, which accepts commands to start (`-a`), stop (`-z`), and check the status (`-s`) of the daemons.

The documentation provides a 

Quick Start Guide to get users up and running quickly.

## 6. Conclusion

`wsprdaemon` is a powerful and feature-rich WSPR decoding and reporting system designed for serious hobbyists and scientific users. Its robust, daemon-based architecture, extensive use of shell scripting for orchestration, and support for multiple receivers and advanced scheduling make it a highly flexible and reliable tool. The project is well-documented and actively maintained, serving a critical role in the global WSPR and amateur radio science communities.

## 7. References

[1] `wsprdaemon` GitHub Repository, README.md. [https://github.com/rrobinett/wsprdaemon](https://github.com/rrobinett/wsprdaemon)

