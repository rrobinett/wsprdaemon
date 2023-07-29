import datetime, sys, astral
from astral import LocationInfo
from astral.sun import sun
from datetime import date

lat=float(sys.argv[1])
lon=float(sys.argv[2])
zone=sys.argv[3]
l = LocationInfo('wsprep', 'local', zone, lat, lon,)
d = date.today()
#
# Addition of try:  and except * : exception handling for use in high north and south latitudes
# at times when the sun does not dip more than 6 deg below horizon, or rises above 6 deg below 
# Gwyn G3ZIL 26 July 2023
#
# Complication is that the same exception is raised whether the sun never sets or the sun
# rises. So look at day of year and which hemisphere in series of four ifs
#
# calculate day of year
today=datetime.datetime.now()
day_of_year=int(today.strftime('%j'))       # day of year as integer

try:
  sun=sun(l.observer, date=d, tzinfo=zone)
  print( str(sun['sunrise'])[11:16] + " " + str(sun['sunset'])[11:16] )
except ValueError as e:
  if (('Sun never reaches') or ('Sun is always') in str (e)):                # exception raised
    if (lat> 60) and (100 <= day_of_year <=260):                            # Northern hemisphere summer 
      print('00:00 23:59')                                                   # it is light all day
    elif (lat >60) and (1 <= day_of_year <=80 or 280 <= day_of_year <366):  # Northern hemisphere winter
      print('00:00 00:01')                                                   # it is dark all day
    elif (lat< -60) and (100 <= day_of_year <=260):                         # Southern hemisphere winter
      print('00:00 00:01')                                                   # it is dark all day
    elif (lat <-60) and (1 <= day_of_year <=80 or 280 <= day_of_year <366): # Southern hemisphere summer
      print('00:00 23:59')                                                   # it is light all day
    else:
      print ('Should never get here given latitude and day of year')

