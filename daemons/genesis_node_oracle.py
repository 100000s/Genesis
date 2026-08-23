import time
import requests
from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_defunct

# --- GENESIS NATIVE CONFIGURATION ---
GENESIS_NODE_RPC = "http://127.0.0.1:8545"  # Local Genesis Node RPC
ORACLE_PRIVATE_KEY = "0x0000000000000000000000000000000000000000000000000000000000000001" # Oracle Node Key
GENESIS_ISSUANCE_ADDRESS = "0x1234567890123456789012345678901234567890"

node_client = Web3(Web3.HTTPProvider(GENESIS_NODE_RPC))
oracle_signer = Account.from_key(ORACLE_PRIVATE_KEY)

CONTRACT_ABI = [
    {
        "inputs": [
            {"internalType": "uint256", "name": "priceInFiatWad", "type": "uint256"},
            {"internalType": "uint256", "name": "timestamp", "type": "uint256"},
            {"internalType": "bytes", "name": "signature", "type": "bytes"}
        ],
        "name": "updateGoldPriceDirect",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    }
]

def fetch_gold_price_wad():
    """Fetches spot gold price per troy oz in USD and converts to WAD (18 decimals)."""
    try:
        response = requests.get("https://api.gold-api.com/price/XAU", timeout=10)
        data = response.json()
        price_usd = float(data["price"])
        return int(price_usd * 10**18)
    except Exception as e:
        print(f"[!] Data Fetch Error: {e}")
        return None

def sign_payload(price_wad, timestamp, chain_id):
    """Signs price payload using the Oracle's native ECDSA private key."""
    msg_hash = Web3.solidity_keccak(
        ['uint256', 'uint256', 'uint256'],
        [price_wad, timestamp, chain_id]
    )
    signable_msg = encode_defunct(hexstr=msg_hash.hex())
    return oracle_signer.sign_message(signable_msg).signature

def push_oracle_update():
    price_wad = fetch_gold_price_wad()
    if not price_wad:
        return

    timestamp = int(time.time())
    chain_id = node_client.eth.chain_id  # Reads Genesis sovereign Chain ID
    signature = sign_payload(price_wad, timestamp, chain_id)

    contract = node_client.eth.contract(address=GENESIS_ISSUANCE_ADDRESS, abi=CONTRACT_ABI)
    
    tx = contract.functions.updateGoldPriceDirect(
        price_wad,
        timestamp,
        signature
    ).build_transaction({
        'from': oracle_signer.address,
        'nonce': node_client.eth.get_transaction_count(oracle_signer.address),
        'gas': 150000,
        'gasPrice': node_client.eth.gas_price
    })

    signed_tx = Account.sign_transaction(tx, private_key=ORACLE_PRIVATE_KEY)
    tx_hash = node_client.eth.send_raw_transaction(signed_tx.raw_transaction)
    print(f"[+] Genesis Gold Oracle Updated: ${price_wad / 10**18:.2f} | Tx: {tx_hash.hex()}")

if __name__ == "__main__":
    print(f"Starting Genesis Native Oracle Daemon (Signer: {oracle_signer.address})...")
    while True:
        push_oracle_update()
        time.sleep(86400) # Run daily
