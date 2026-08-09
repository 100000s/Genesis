pragma circom 2.1.6;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";

template ResidencyProof() {
    // --- PRIVATE INPUTS ---
    signal input ssnHash;         // Hashed SSN/Government ID number
    signal input stateFips;       // FIPS code of state residency
    signal input userSecret;      // Private seed key from Genesis wallet

    // --- PUBLIC INPUTS ---
    signal input targetStateFips; // State FIPS code claimed for balance allocation

    // --- PUBLIC OUTPUTS ---
    signal output nullifierHash;  // Prevents duplicate claims per citizen

    // Enforce State Residency Match
    component stateEq = IsEqual();
    stateEq.in[0] <== stateFips;
    stateEq.in[1] <== targetStateFips;
    stateEq.out === 1;

    // Compute Nullifier Hash = Poseidon(ssnHash, userSecret)
    component hasher = Poseidon(2);
    hasher.inputs[0] <== ssnHash;
    hasher.inputs[1] <== userSecret;
    
    nullifierHash <== hasher.out;
}

component main {public [targetStateFips]} = ResidencyProof();
