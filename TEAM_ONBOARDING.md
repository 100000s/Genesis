# Genesis Ecosystem — AppTeamDAO Founding Developer Onboarding Guide

Welcome to the **Genesis Ecosystem** founding developer collective. The **AppTeamDAO** oversees all protocol-level logic, UI/UX components, wallet applications, mobile integrations, and cross-platform token tooling.

Prior to the Genesis Block, all core architecture across the 10 canonical smart contracts is actively iterated peer-to-peer without invoking locked governance voting. Once the Genesis Block is initiated, the immutable `GenesisGovernance` GIP process takes effect.

---

## 1. Governance & Contribution Framework (`AppTeamDAO.sol`)

Contributions and voting power in the AppTeamDAO are governed by **soulbound, quarterly-reset voting credits** (`MAX_CREDITS_PER_CYCLE = 150` per contributor):

### Contribution Tracks & Credit Limits
* **Core Developers (Max 100 credits/quarter):** 5 credits per audited commit, 10 credits per approved core feature. Focus: EVM contracts, TWAP oracles, issuance algorithms, and state machines.
* **UI/UX Designers (Max 40 credits/quarter):** 10 credits per approved redesign. Focus: Web dashboards, 3D/VR storefronts, and mobile interfaces.
* **Mobile Maintainers (Max 45 credits/quarter):** 15 credits per official release. Focus: Android, iOS, Expo, Flutter, and local node tooling.
* **Escrow Contributors (Max 45 credits/quarter):** 15 credits per validated workflow. Focus: Multi-sig arbitration, dispute flows, and `GenesisEscrow.sol`.
* **Community Integrators (Max 50 credits/quarter):** 10 credits per onboarded merchant, ATM, or node. Focus: Physical bearer notes, satellite/radio integrations, and local verifiers.

---

## 2. Token Allocation Categories (30% WorkerSplit Allocation)

The AppTeamDAO routes 30% of minted worker tokens across 10 defined categories:

### ⅓ Note Technology (10% Total)
0. **`NOTE_RND` (0.5%):** R&D, anti-counterfeit features, thermal paper specifications, livery auctions.
1. **`MERCHANT` (0.5%):** Physical merchant onboarding, local mapping, ad integration.

### ⅓ Digital Integration (10% Total)
2. **`ANDROID_IOS` (0.2%):** Mobile wallet & node management apps.
3. **`OLD_PC` (0.2%):** Hardware support for legacy PCs and lightweight validator nodes.
4. **`OLD_PHONE` (0.2%):** Legacy cellphone & verifier node integrations.
5. **`SATELLITE` (0.2%):** Satellite data links (Iridium, Kenéis).
6. **`RADIO` (0.2%):** Packet radio & shortwave/HF data layers.

### ⅓ Virtual World Shopping (10% Total)
7. **`GENESIS_MALL` (0.6%):** Native 3D/AR/VR virtual shopping mall.
8. **`SECOND_LIFE` (0.2%):** Second Life virtual ATM and storefront.
9. **`DECENTRALAND` (0.2%):** Decentraland virtual ATM and storefront.

---

## 3. Developer Workflow: Sovereign Peer-to-Peer via Radicle

We do not use central push/pull models on centralized hosts. All development happens via Radicle on our self-hosted seed nodes.

### Step 1: Install & Authenticate Radicle
curl -sSLf [https://radicle.xyz/install](https://radicle.xyz/install) | sh
rad auth

### Step 2: Clone the Genesis Repository
Clone the repository directly from our primary seed node using the Repository Identifier (RID):

rad clone <YOUR_REPOSITORY_RID>
cd Genesis

### Step 3: Local Testing & Validation
Verify smart contracts compile and pass test suites locally:

npx hardhat compile
npx hardhat test

### Step 4: Submit a Patch
Create your feature branch, commit your code, and publish your patch to the peer-to-peer network:

git checkout -b feature/your-feature-name
git add .
git commit -m "Implement feature description"
rad patch create

Your patch will be picked up by maintainer nodes, reviewed, and merged directly into the main repository state.
