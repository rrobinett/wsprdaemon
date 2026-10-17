### derived_calc.awk: derived_calc.py (G3ZIL, April 2020) in awk, writing the same derived_azi.csv and stdout byte for byte.
###
### derived_calc.py ran once per spot, and starting python3 and importing numpy cost ~0.1 s of CPU for ~20 trig calls:
### at ON5KQ-BL (8 receivers) on 2026-10-17 that was 1,207 runs and ~139 s of CPU per two minute cycle, more than a
### whole core, and the biggest consumer once the decoders moved to ubersdr_wsprd.  gawk starts in about a millisecond.
###
### Every quirk of the Python is kept, so the uploaded fields don't change:
###   - Python's float '%' (np.remainder), whose result takes the sign of the divisor, so -1e-15 % 360 == 360.0
###   - on a shared meridian v_lon is set to the meridian and then overwritten by the rx_azi branch anyway
###   - np.arccos of a value outside [-1,1] is nan, and nan fails every comparison after it
###   - max([tx_lat, rx_lat], key=abs) keeps tx_lat on a tie
###   - csv.writer ends the line with \r\n; the caller strips the \r
###   - the output file is created before anything is computed, so a bad locator leaves it empty and exits 1
###
### Usage: LC_ALL=C gawk -v tx_locator=GRID -v rx_locator=GRID -v frequency=MHZ -f derived_calc.awk
###        writes derived_azi.csv in the current directory

### gawk orders NaN above every number and calls NaN == NaN, so 'x != x' can't detect it and a NaN would pass
### 'v_lat > 90'.  Test the printed form instead, and guard every comparison which can see a NaN.
function isnan_(x) { return sprintf("%f", x) ~ /nan/ }
function pymod(x, m,    r) {            ### Python's float x % m for m > 0
    if (isnan_(x)) return x
    r = x - m * int(x / m)              ### fmod(): int() truncates toward zero
    if (r != 0 && r < 0) r += m
    return r
}
function deg(r) { return r * 180.0 / PI }
function rad(d) { return d * PI / 180.0 }
function acos_(x) {                     ### np.arccos: nan outside [-1,1]
    if (isnan_(x) || x > 1 || x < -1) return NAN
    return atan2(sqrt(1 - x * x), x)
}
function tan_(x) { return sin(x) / cos(x) }
function absmax_first(a, b) { return (b < 0 ? -b : b) > (a < 0 ? -a : a) ? b : a }     ### lats: never NaN
function fmt(f, x) {                    ### Python's '%' formatting prints nan as 'nan', where C may print '-nan'
    if (isnan_(x)) return "nan"
    return sprintf(f, x)
}
function loc_to_lat_lon(locator,    c, base) {
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", locator)
    if (length(locator) < 4) return 0
    split(locator, c, "")
    LAT = ((ORD[c[2]] - 65) * 10) + (ORD[c[4]] - 48) + 0.5 - 90
    LON = ((ORD[c[1]] - 65) * 20) + ((ORD[c[3]] - 48) * 2) + 1 - 180
    if (length(locator) == 6) {
        base = (ORD[c[5]] > 88) ? 96 : 64
        LAT = LAT - 0.5 + ((ORD[c[6]] - base) / 24) - (1 / 48)
        LON = LON - 1 + ((ORD[c[5]] - base) / 12) - (1 / 24)
    }
    return 1
}

BEGIN {
    PI = atan2(0, -1)
    NAN = -log(0) - -log(0)             ### inf - inf
    for (i = 0; i < 256; ++i) ORD[sprintf("%c", i)] = i
    absent_data = -999.0
    out = "derived_azi.csv"

    print tx_locator
    print rx_locator
    print tx_locator, rx_locator, frequency
    printf "" > out                     ### created (and truncated) first, as the Python's 'with open()' does

    if (tx_locator != "none") {
        if (!loc_to_lat_lon(tx_locator)) exit 1
        tx_lat = LAT; tx_lon = LON
        if (!loc_to_lat_lon(rx_locator)) exit 1
        rx_lat = LAT; rx_lon = LON
        phi_tx_lat = rad(tx_lat); lambda_tx_lon = rad(tx_lon)
        phi_rx_lat = rad(rx_lat); lambda_rx_lon = rad(rx_lon)
        delta_phi = phi_tx_lat - phi_rx_lat
        delta_lambda = lambda_tx_lon - lambda_rx_lon

        y = sin(delta_lambda) * cos(phi_tx_lat)
        x = cos(phi_rx_lat) * sin(phi_tx_lat) - sin(phi_rx_lat) * cos(phi_tx_lat) * cos(delta_lambda)
        rx_azi = pymod(deg(atan2(y, x)), 360)

        p = sin(-delta_lambda) * cos(phi_rx_lat)
        q = cos(phi_tx_lat) * sin(phi_rx_lat) - sin(phi_tx_lat) * cos(phi_rx_lat) * cos(-delta_lambda)
        tx_azi = pymod(deg(atan2(p, q)), 360)

        if (tx_lon == rx_lon) {
            v_lon = tx_lon
            v_lat = absmax_first(tx_lat, rx_lat)
        } else {
            v_lat = deg(acos_(sin(rad(rx_azi)) * cos(phi_rx_lat)))
        }
        if (!isnan_(v_lat) && v_lat > 90.0) v_lat = 180 - v_lat
        if (rx_azi < 180) {
            v_lon = pymod((rx_lon + deg(acos_(tan_(phi_rx_lat) / tan_(rad(v_lat))))) + 360, 360)
        } else {
            v_lon = pymod((rx_lon - deg(acos_(tan_(phi_rx_lat) / tan_(rad(v_lat))))) + 360, 360)
        }
        if (!isnan_(v_lon) && v_lon > 180) v_lon = -(360 - v_lon)
        lo = (tx_lon < rx_lon) ? tx_lon : rx_lon
        hi = (tx_lon > rx_lon) ? tx_lon : rx_lon
        if (!isnan_(v_lon) && (v_lon < lo || v_lon > hi)) {
            v_lat = absmax_first(tx_lat, rx_lat)
            v_lon = (v_lat == tx_lat) ? tx_lon : rx_lon
        }
        a = sin(delta_phi / 2) * sin(delta_phi / 2) + cos(phi_rx_lat) * cos(phi_tx_lat) * sin(delta_lambda / 2) * sin(delta_lambda / 2)
        c = 2 * atan2(sqrt(a), sqrt(1 - a))
        km = 6371 * c
    } else {
        v_lon = v_lat = tx_lon = tx_lat = rx_lon = rx_lat = rx_azi = tx_azi = km = absent_data
    }

    band = 9999
    freq = int(10 * (frequency + 0))
    if (freq == 1) band = 2200
    if (freq == 4) band = 630
    if (freq == 18) band = 160
    if (freq == 35) band = 80
    if (freq == 52 || freq == 53) band = 60
    if (freq == 70) band = 40
    if (freq == 101) band = 30
    if (freq == 140) band = 20
    if (freq == 181) band = 17
    if (freq == 210) band = 15
    if (freq == 249) band = 12
    if (freq == 281) band = 10
    if (freq == 502) band = 6
    if (freq == 700) band = 4
    if (freq == 1444) band = 2
    if (freq == 4323) band = 70
    if (freq == 12965) band = 23

    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\r\n", band, fmt("%.0f", km), fmt("%.0f", rx_azi), fmt("%.3f", rx_lat), fmt("%.3f", rx_lon), \
        fmt("%.0f", tx_azi), fmt("%.1f", tx_lat), fmt("%.1f", tx_lon), fmt("%.3f", v_lat), fmt("%.3f", v_lon) > out
}
