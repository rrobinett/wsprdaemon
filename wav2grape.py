#!/usr/bin/python3 -u
# convert a directory tree containing wav files into a Digital RF dataset
# for the grape system
#
# directory layout:
#   <basedir>/<YYYYMMDD>/<site>_<grid_square>/<receiver_name>/<subchannel_name>/<I/Q sample>.wav
#
# Copyright 2024 Franco Venturi K4VZ
#
# Version: 1.0 - Mon 22 Jan 2024 10:58:05 PM UTC

from collections import defaultdict
from configparser import ConfigParser
from datetime import datetime, timezone
import digital_rf as drf
import getopt
import numpy as np
import os
import re
import soundfile as sf
import sys
import uuid

# global variables
verbose = 0


def maidenhead_to_long_lat(x):
    long = (ord(x[0]) - ord('A')) * 20 + (ord(x[2]) - ord('0')) * 2 - 180
    lat  = (ord(x[1]) - ord('A')) * 10 + (ord(x[3]) - ord('0'))     -  90
    if len(x) >= 6:
        long += (ord(x[4].upper()) - ord('A')) * 5.0 / 60.0
        lat  += (ord(x[5].upper()) - ord('A')) * 2.5 / 60.0
        if len(x) == 8:
            long += (ord(x[6]) - ord('0')) * 30.0 / 3600.0
            lat  += (ord(x[7]) - ord('0')) * 15.0 / 3600.0
    return long, lat


def get_subchannels(inputdir, subdir2freq):
    # create list of subchannels and make sure that each has one wav file in it
    subchannels = []
    for subdir in os.listdir(inputdir):
        if subdir not in subdir2freq:
            print('Subdir', subdir, 'not found in subchannels list. Skipping it.', file=sys.stderr)
            continue
        subdir_content = [x for x in os.listdir(os.path.join(inputdir, subdir))
                          if x.endswith('.wav')]
        if len(subdir_content) != 1:
            print('Subdir', subdir, 'does not contain a single wav file. Skipping it.', f'(content: {subdir_content})', file=sys.stderr)
            continue
        subchannels.append((subdir, subdir_content[0], float(subdir2freq[subdir])))
    # return subchannels in ascending frequency order
    subchannels.sort(key=lambda x: x[2])
    return subchannels


def create_drf_dataset(inputdir, dataset_dir, subchannels, config_global, start_time, uuid_str=None):
    channel_name = config_global['channel name']
    subdir_cadence_secs = int(config_global['subdir cadence secs'])
    file_cadence_millisecs = int(config_global['file cadence millisecs'])
    compression_level = int(config_global['compression level'])
    dtype = 'i2'  # 16bit shorts
    #dtype = 'float32'

    if uuid_str is None:
        uuid_str = uuid.uuid4().hex

    print('writing Digital RF dataset. This will take a while', file=sys.stderr)

    # build np.array with samples and validate wav files to make sure they
    # are all consistent (same num samples, channels, data type, etc)
    sample_rate = None
    num_samples = None
    num_channels = None
    data_type = None
    samples = [None] * len(subchannels)
    for idx, subchannel in enumerate(subchannels):
        wav_file = os.path.join(inputdir, subchannel[0], subchannel[1])
        samples[idx], wav_sample_rate = sf.read(wav_file, dtype=dtype)

        # sanity checks
        if sample_rate == None:
            sample_rate = wav_sample_rate
        elif wav_sample_rate != sample_rate:
            print('sample rates do not match - file', wav_file, 'has', wav_sample_rate, '- expecting:', sample_rate, file=sys.stderr)
            return False, None, None, None, None
        wav_num_samples = samples[idx].shape[0]
        if num_samples == None:
            num_samples = wav_num_samples
        elif wav_num_samples != num_samples:
            print('number of samples does not match - file', wav_file, 'has', wav_num_samples, '- expecting:', num_samples, file=sys.stderr)
            return False, None, None, None, None
        wav_num_channels = samples[idx].shape[1]
        if num_channels == None:
            num_channels = wav_num_channels
        elif wav_num_channels != num_channels:
            print('number of channels does not match - file', wav_file, 'has', wav_num_channels, '- expecting:', num_channels, file=sys.stderr)
            return False, None, None, None, None
        wav_data_type = samples[idx].dtype
        if data_type == None:
            data_type = wav_data_type
        elif wav_data_type != data_type:
            print('data type does not match - file', wav_file, 'has', wav_data_type, '- expecting:', data_type, file=sys.stderr)
            return False, None, None, None, None

    if verbose >= 1:
        print('sample_rate:', sample_rate)
        print('num_samples:', num_samples)
        print('num_channels:', num_channels)
        print('data_type:', data_type)
        print('len(samples):', len(samples))

    start_global_index = int(start_time * sample_rate)
    if uuid_str is None:
        uuid_str = uuid.uuid4().hex

    # the dataset directory must already exist
    channel_dir = os.path.join(dataset_dir, channel_name)
    os.makedirs(channel_dir)

    with drf.DigitalRFWriter(channel_dir,
                             dtype,
                             subdir_cadence_secs,
                             file_cadence_millisecs,
                             start_global_index,
                             sample_rate,            # sample_rate_numerator
                             1,                      # sample_rate_denominator
                             uuid_str,
                             compression_level,
                             False,                  # checksum
                             num_channels == 2,      # is_complex
                             len(subchannels),       # num_subchannels
                             True,                   # is_continuous
                             False                   # marching_periods
                            ) as do:

        #do.rf_write(np.hstack(samples, casting='no'))
        do.rf_write(np.hstack(samples))

    # hopefully deleting samples will free all the memory
    del samples

    return True, channel_dir, sample_rate, start_global_index, uuid_str


def create_metadata(latitude, longitude, config, site, station, callsign, grid_square, receiver_name, frequencies, uuid_str):
    metadata = dict()
    if site in config:
        metadata.update(config[site])
    if station in config:
        metadata.update(config[station])
    if latitude is not None:
        metadata['lat'] = np.single(latitude)
    elif 'latitude' in metadata:
        metadata['lat'] = np.single(float(metadata['latitude']))
        del metadata['latitude']
    if longitude is not None:
        metadata['long'] = np.single(longitude)
    elif 'longitude' in metadata:
        metadata['long'] = np.single(float(metadata['longitude']))
        del metadata['longitude']
    if callsign is not None:
        metadata['callsign'] = callsign
    if grid_square is not None:
        metadata['grid_square'] = grid_square
    if receiver_name is not None:
        metadata['receiver_name'] = receiver_name
    metadata['center_frequencies'] = np.ascontiguousarray(frequencies)
    metadata['uuid_str'] = uuid_str

    return metadata


def create_drf_metadata(channel_dir, config_global, sample_rate, start_global_index, metadata):
    subdir_cadence_secs = int(config_global['subdir cadence secs'])
    metadatadir = os.path.join(channel_dir, 'metadata')
    os.makedirs(metadatadir)
    do = drf.DigitalMetadataWriter(metadatadir,
                                   subdir_cadence_secs,
                                   subdir_cadence_secs,  # file_cadence_secs
                                   sample_rate,      # sample_rate_numerator 
                                   1,                # sample_rate_denominator
                                   'metadata'        # file_name
                                  )
    sample = start_global_index
    do.write(sample, metadata)
    return True


def main():
    configfile = sys.argv[0].replace('.py', '.conf')
    inputdir = None
    outputdir = None
    start_time = None
    latitude = None
    longitude = None
    uuid_str = None
    try:
        opts, args = getopt.getopt(sys.argv[1:], 'c:i:o:s:l:u:v')
    except getopt.GetoptError as ex:
        print(ex, file=sys.stderr)
        sys.exit(1)
    for o, a in opts:
        if o == '-c':
            configfile = a
        elif o == '-i':
            inputdir = a
        elif o == '-o':
            outputdir = a
        elif o == '-s':
            # allow for time zone (default is local TZ)
            #start_time = datetime.fromisoformat(a).timestamp()
            # always UTC
            start_datetime = datetime.fromisoformat(a).replace(tzinfo=timezone.utc)
            start_time = start_datetime.timestamp()
        elif o == '-l':
            latitude, longitude = [float(x) for x in split(a, ',')]
        elif o == '-u':
            uuid_str = a
        elif o == '-v':
            global verbose
            verbose += 1

    if inputdir is None:
        print('missing input dir (-i) option', file=sys.stderr)
        sys.exit(1)

    if outputdir is None:
        print('missing output dir (-o) option', file=sys.stderr)
        sys.exit(1)

    if start_time is None:
        for path_element in inputdir.split(os.path.sep):
            try:
                start_datetime = datetime.strptime(path_element, '%Y%m%d').replace(tzinfo=timezone.utc)
                start_time = start_datetime.timestamp()
                break
            except ValueError:
                pass

    station_path = None
    station = None
    site = None
    callsign = None
    grid_square = None
    receiver_name = None

    inputdir_regex = re.compile('(?:.+/|^)(?P<date>\d{8})/(?P<station>(?P<site>(?P<callsign>[a-zA-Z0-9=]+)_(?P<grid_square>[a-zA-Z0-9]+))/(?P<receiver_info>((?P<receiver_name>\w+)@(?P<psws_station_id>[a-zA-Z0-9]+)_(?P<psws_instrument_id>\d+))))$')
    m = inputdir_regex.match(inputdir)
    if m:
        if start_time is None:
            start_time = datetime.strptime(m.group('date'), '%Y%m%d').timestamp()
        station_path = m.group('station')
        station = station_path.replace('/', ' ').replace('=', '/')
        site = m.group('site').replace('=', '/')
        callsign = m.group('callsign').replace('=', '/')
        grid_square = m.group('grid_square')
        if latitude is None and longitude is None:
            longitude, latitude = maidenhead_to_long_lat(grid_square)
        receiver_info = m.group('receiver_info')
        receiver_name = m.group('receiver_name')
        psws_station_id = m.group('psws_station_id')
        psws_instrument_id = m.group('psws_instrument_id')
    else:
        print('unable to extract station information from input directory', file=sys.stderr)

    config = ConfigParser(interpolation=None)
    config.optionxform = str
    config.read(configfile)

    subchannels = get_subchannels(inputdir, config['subchannels'])
    if len(subchannels) == 0:
        print("No subchannels (i.e. no wav files) found. Nothing to do.", file=sys.stderr)
        sys.exit(0)
    print('N subchannels:', len(subchannels), file=sys.stderr)
    if verbose >= 1:
        print('subchannels:', subchannels)

    if station_path is not None:
        start_datetime = datetime.fromtimestamp(start_time, tz=timezone.utc)
        grape_toplevel = start_datetime.strftime('OBS%Y-%m-%dT%H-%M')
        dataset_dir = os.path.join(outputdir, station_path, grape_toplevel)
    else:
        dataset_dir = outputdir

    ok, channel_dir, sample_rate, start_global_index, uuid_str = create_drf_dataset(inputdir, dataset_dir, subchannels, config['global'], start_time, uuid_str)
    print('create_drf_dataset returned', ok, file=sys.stderr)
    if not ok:
        sys.exit(1)

    frequencies = [float(x[2]) for x in subchannels]
    metadata = create_metadata(latitude, longitude, config, site, station, callsign, grid_square, receiver_name, frequencies, uuid_str)

    ok = create_drf_metadata(channel_dir, config['global'], sample_rate, start_global_index, metadata)
    print('create_drf_metadata returned', ok, file=sys.stderr)
    if not ok:
        sys.exit(1)

    print(dataset_dir)


if __name__ == '__main__':
    main()
