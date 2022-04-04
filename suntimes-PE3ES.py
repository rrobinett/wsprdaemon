import datetime, sys
from astral import LocationInfo
from astral.sun import sun
from datetime import date
lat=float(sys.argv[1])
lon=float(sys.argv[2])
zone=sys.argv[3]
l = LocationInfo(('wsprep', 'local', lat, lon, zone, 0))
d = date.today()
s = sun(l.observer, date=d)
print( str(s['sunrise'])[11:16] + " " + str(s['sunset'])[11:16] )
