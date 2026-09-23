# GeoIPv4.bin attribution

`GeoIPv4.bin` is compiled by `scripts/build_geoip_db.py` from the **DB-IP Lite
City** dataset, distributed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) by
[DB-IP.com](https://db-ip.com/), via the community mirror
[github.com/sapics/ip-location-db](https://github.com/sapics/ip-location-db)
(`dbip-city-ipv4-num.csv.gz`, "Update: Monthly").

CC BY 4.0 requires attribution wherever results from the database are shown
to users — NetBridge does this with an in-app credit line (see
`ConnectionHistoryListView` in `DashboardView.swift`): "IP geolocation ©
DB-IP.com, CC BY 4.0".

## Regenerating

```
curl -L -o /tmp/dbip-city-ipv4-num.csv.gz \
    https://github.com/sapics/ip-location-db/releases/download/latest/dbip-city-ipv4-num.csv.gz
python3 scripts/build_geoip_db.py /tmp/dbip-city-ipv4-num.csv.gz NetBridge/Resources/GeoIPv4.bin
```

Re-add `GeoIPv4.bin` to the Xcode project's Resources build phase if it was
ever removed/re-created outside Xcode.

- Source snapshot date: 2026-09-16
- Source: DB-IP Lite City, IPv4, via ip-location-db `releases/latest`
