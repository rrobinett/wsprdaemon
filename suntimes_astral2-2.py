import datetime, sys, astral
from astral import LocationInfo
from astral.sun import sun
from datetime import date

lat=float(sys.argv[1])
lon=float(sys.argv[2])
zone=sys.argv[3]
l = LocationInfo('wsprep', 'local', zone, lat, lon,)
d = date.today()
sun=sun(l.observer, date=d, tzinfo=zone)
print( str(sun['sunrise'])[11:16] + " " + str(sun['sunset'])[11:16] )
