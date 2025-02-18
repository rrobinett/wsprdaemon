# How wsprdaemon Works

## Basic components

- receiver integration (KiwiSDR, ka9q-radio)
- wspr decoding and reporting to wsprnet
- grape recording, conversion to digital_rf, and reporting to HamSCI
- pskreporter

## A running instance of wsprdaemon performs several tasks:

- configuration and installation checks
- preparation of recording and posting directories
- "listening" functions for KIWI and KA9Q receiver definitions
- monitoring and logging results and errors 

## What will make it not start or then stop working?

- configuration problems
- radiod or kiwi streams not present

