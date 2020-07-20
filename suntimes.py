import datetime, sys
from astral import Astral, Location
from datetime import date
lat=float(sys.argv[1])
lon=float(sys.argv[2])
zone=sys.argv[3]
l = Location(('wsprep', 'local', lat, lon, zone, 0))
l.sun()
d = date.today()
sun = l.sun(local=True, date=d)
print( str(sun['sunrise'])[11:16] + " " + str(sun['sunset'])[11:16] )
