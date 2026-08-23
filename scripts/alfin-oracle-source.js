/**
 * @title ALFIN Fiscal Asset Ratio Chainlink Functions Script
 * @dev Executed off-chain in the Chainlink Functions DON environment.
 * 
 * Expected Secrets / Config Parameters:
 *  - secrets.ALFIN_API_KEY (optional auth header if querying private/authenticated endpoints)
 * 
 * Expected args array:
 *  - args[0]: Target Year (e.g., "2027")
 *  - args[1]: Jurisdiction Type ("fed" or "state")
 *  - args[2]: State ID ("0" for federal, or "1" through "50" for states)
 *  - args[3]: ALFIN Target API Endpoint URL
 */

// Validate Input Arguments
if (!args || args.length < 4) {
  throw Error("Missing required arguments: [targetYear, jurisdictionType, stateId, apiUrl]");
}

const targetYear = parseInt(args[0], 10);
const jurisdictionType = args[1].toLowerCase(); // "fed" or "state"
const stateId = parseInt(args[2], 10);
const apiUrl = args[3];

// Determine Fiscal Years required for the inverse ratio calculation
// For Target Year 2027: fyPrev2 = FY2024, fyPrev1 = FY2025
const fyPrev2 = targetYear - 3; // e.g., 2024
const fyPrev1 = targetYear - 2; // e.g., 2025

// Build API Request to ALFIN / Treasury API endpoint
const alfinRequest = Functions.makeHttpRequest({
  url: apiUrl,
  method: "GET",
  params: {
    jurisdiction: jurisdictionType,
    stateId: stateId,
    years: `${fyPrev2},${fyPrev1}`
  },
  headers: {
    "Accept": "application/json",
    ...(secrets.ALFIN_API_KEY && { "Authorization": `Bearer ${secrets.ALFIN_API_KEY}` })
  },
  timeout: 9000 // 9-second timeout for DON execution limits
});

// Execute HTTP fetch
const alfinResponse = await alfinRequest;

if (alfinResponse.error) {
  throw Error(`ALFIN API Request Failed: ${alfinResponse.error}`);
}

const responseData = alfinResponse.data;

/**
 * Expected JSON payload schema from ALFIN endpoint:
 * {
 *   "jurisdiction": "state",
 *   "stateId": 37,
 *   "reports": {
 *     "2024": { "totalAssets": "145000000000" },
 *     "2025": { "totalAssets": "152000000000" }
 *   }
 * }
 */

if (!responseData.reports || !responseData.reports[fyPrev2] || !responseData.reports[fyPrev1]) {
  throw Error(`Missing required fiscal asset data for years ${fyPrev2} or ${fyPrev1}`);
}

// Parse Total Assets (using BigInt to handle large dollar figures without precision loss)
const totalAssetsFY2024 = BigInt(responseData.reports[fyPrev2].totalAssets);
const totalAssetsFY2025 = BigInt(responseData.reports[fyPrev1].totalAssets);

if (totalAssetsFY2025 === 0n) {
  throw Error("FY2025 Total Assets cannot be zero");
}

// ------------------------------------------------------------------------
// FISCAL MULTIPLIER CALCULATION:
// Inverse ratio: Total Assets (t-2) / Total Assets (t-1)
// Ratio in WAD (18 decimals precision) = (Assets_2024 * 10^18) / Assets_2025
// ------------------------------------------------------------------------
const WAD = 1000000000000000000n; // 1e18
const wadRatio = (totalAssetsFY2024 * WAD) / totalAssetsFY2025;

// Format output payload for smart contract consumption
// Encode output depending on jurisdiction type
if (jurisdictionType === "fed") {
  // Returns tuple (year, ratioWad)
  return Functions.encodeUint256(wadRatio);
} else {
  // Returns ratioWad for state
  return Functions.encodeUint256(wadRatio);
}





