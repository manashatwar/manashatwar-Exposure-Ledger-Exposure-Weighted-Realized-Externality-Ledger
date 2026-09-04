# Quickstart & Deployment Guide

This guide contains the exact sequence of commands required to deploy the Reactive Smart Contract (RSC), connect it to the Hook, and execute an End-to-End (E2E) test on the testnets.

## 0. Prerequisite: Top Up Testnet REACT
The Reactive Network servers will drop cross-chain transactions if your wallet/contract lacks sufficient funds to cover the gas limits. To get testnet `lREACT` on the Lasna network, you must send Sepolia ETH to the official cross-chain faucet.

*Note: 1 Sepolia ETH = 100 lREACT. Sending `0.1 ether` gives you 10 lREACT, which is plenty.*

```bash
# Load your environment variables
set -a && source .env && set +a

# Request funds from the Sepolia -> Lasna bridge faucet
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  "request(address)" $CLIENT_WALLET \
  --value 0.1ether
```
*Wait ~30 seconds for the cross-chain bridge to credit your wallet on Lasna.*

---

## 1. Deploy the RSC
Deploy the `ExposureLedgerRSC` to the Lasna Testnet. This contract automatically funds itself with `0.1 REACT` during deployment to ensure it passes the Reactive server financial checks.

```bash
forge script script/DeployRSC.s.sol:DeployRSC \
  --rpc-url $REACTIVE_RPC \
  --private-key $REACTIVE_PRIVATE_KEY \
  --broadcast --legacy
```
*IMPORTANT: Copy the deployed RSC Address from the terminal output and save it in your `.env` file as `RSC_ADDR=`.*

---

## 2. Wire the Hook to the Relayer
You must explicitly grant permission to the Reactive Relayer so that it can securely execute callbacks on your Sepolia Hook.

```bash
set -a && source .env && set +a

cast send $HOOK_ADDR "setReactiveCallbackProxy(address)" $RELAYER_ADDR \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

---

## 3. Activate the RSC Subscription
If a contract ever runs out of gas, the Reactive Network halts it and sets its status to `INACTIVE`. To ensure the engine is fully booted and subscribed to the event stream, explicitly pause and resume it.

```bash
cast send $RSC_ADDR "pause()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
cast send $RSC_ADDR "resume()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
```

---

## 4. Run the End-to-End (E2E) Test Swap
Fire the test script which creates a Uniswap V4 Pool, adds liquidity, and executes a swap.

```bash
forge script script/E2ETestFlow.s.sol:E2ETestFlow \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast --via-ir -vvv
```

### Verification
1. Go to your Hook's Etherscan page and look for the `EpisodeCreated` event.
2. **Wait 60 blocks (~2 minutes).**
3. Check the Lasna block explorer for your `RSC_ADDR`. You will see it emit a `Callback` transaction.
4. Go back to your Hook's Etherscan page. You will see the `EpisodeResolved` event successfully relayed by the network!
