# Genesis receipt oracle helper
# Off-chain only: Solidity cannot fetch FRED/ALFRED directly.
import hashlib, json, urllib.request

def fetch(series_id):
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?id={series_id}"
    request = urllib.request.Request(url, headers={"User-Agent": "GenesisOracle/1.0"})
    return urllib.request.urlopen(request, timeout=30).read()

def payload(entity, series_id, fy2024, fy2025):
    ratio = fy2024 / fy2025
    body = {"entity": entity, "series": series_id, "fy2024": fy2024, "fy2025": fy2025, "ratioWad": int(ratio * 10**18)}
    body["sourceHash"] = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return body

# The daemon should validate units, fiscal-year boundaries, and completeness before
# submitting updateFedRatio/updateStateRatio with the sourceHash.
