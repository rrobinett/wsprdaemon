from math import cos,sin,acos,asin,tan, floor  
from math import degrees as deg, radians as rad  , pi as pi
from datetime import date,datetime,time,timezone,timedelta
import calendar
import sys
from numpy import deg2rad
import subprocess

# Gwyn Griffiths G3ZIL 2 September 2023  V2
# Basic principles sunrise and sunset calculator  needs lat and lon as the two input arguments
# Extracts timezone for the local computer using timedatectl as an operating system command
# Equations from NOAA at https://gml.noaa.gov/grad/solcalc/solareqns.PDF
# Watch out here - the trig functions have mix of degrees and radian inputs so explicit conversion used where needed
# Error check for perpetual day or night and times are outputin the 'except' block  
# V2 has no timezone argument, calculates from call to operating system executable timedatectl
# G3ZIL checking code 30 April 2025 for any numerical error

lat=float(sys.argv[1])
lon=float(sys.argv[2])

date_offset=0

# calculate day of year
today=datetime.now(timezone.utc)+timedelta(days=date_offset)  # get today's date UTC timezone
day_of_year=int(today.strftime('%j'))                   # day of year as integer
year=int(today.strftime('%Y'))                          # year as integer

# get number of days in year
if(calendar.isleap(year)):
 n_days=366
else:
 n_days=365

# get hour
hour=int(today.strftime('%H'))              # hour as zero padded integer

# calculate fractional year gamma where whole year is two pi, so gamma is in radians, fine for trig functions below
gamma=((2*pi)/n_days)*(day_of_year-1+(hour-12)/24)
# calculate equation of time in minutes
eqtime=229.18*(0.000075+0.001868*cos(gamma)-0.032077*sin(gamma)-0.014615*cos(2*gamma)-0.040849*sin(2*gamma))

# calculate solar declination angle in radians
decl=0.006918-0.399912*cos(gamma)+0.070257*sin(gamma)-0.006758*cos(2*gamma)+0.000907*sin(2*gamma)-0.002697*cos(3*gamma)+0.00148*sin(3*gamma)

# calculate timezone offset in integer hours from longitude
tz_offset = float(subprocess.check_output("timedatectl | awk '/Time/{print substr($5,1,3)}'", shell=True, universal_newlines=True))

#print ("time zone offset from timedatectl ", tz_offset)

# use the try feature as error trap for polar night and day
try:
# Sunrise/Sunset Calculations
# For the special case of sunrise or sunset, the zenith is set to 90.833 (the approximate correction for
# atmospheric refraction at sunrise and sunset, and the size of the solar disk), and the hour angle
# becomes:
  deg2rad=360/(2*pi)
  ha_sunrise=acos((cos(90.833/deg2rad)/(cos(lat/deg2rad)*cos(decl)))-tan(lat/deg2rad)*tan(decl))*deg2rad
  ha_sunset=-acos((cos(90.833/deg2rad)/(cos(lat/deg2rad)*cos(decl)))-tan(lat/deg2rad)*tan(decl))*deg2rad

#Then the UTC time of sunrise (or sunset) in minutes is:
  sunrise = 720-4*(lon+ha_sunrise)-eqtime
  sunset = 720-4*(lon+ha_sunset)-eqtime    # was +, an error, corrected 30 April 2025, the error was about 2 minutes, but see major  bug below
  hour_sunrise=int((floor(sunrise/60)+tz_offset) % 24)
  hour_sunset=int((floor(sunset/60)+tz_offset) % 24)
  min_sunrise=int(sunrise % 60)
  min_sunset=int(sunset % 60)
  print("{:02d}".format(hour_sunrise),":", "{:02d}".format(min_sunrise)," ", "{:02d}".format(hour_sunset),":", "{:02d}".format(min_sunset), sep='')
# above print line had an error in that the  print for min_sunset was printing the variable min_sunrise. Corrected 30 April 2025 G3ZIL

except ValueError as e:
  if (('math domain error') in str (e)):                # exception raised
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
