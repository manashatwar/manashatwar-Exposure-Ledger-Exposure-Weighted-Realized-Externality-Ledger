import { createPublicClient, http, formatEther } from 'viem';
import { sepolia } from 'viem/chains';

const HOOK = '0x30D4F958F727518e4E5949538877065aBF924a40';
const LP = '0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4';
const ABI = [
  { name: 'getEpisode', type: 'function', stateMutability: 'view', inputs: [{ name: 'episodeId', type: 'uint256' }], outputs: [{ type: 'tuple', components: [{ name: 'episodeId', type: 'uint64' }, { name: 'blockNumber', type: 'uint64' }, { name: 'tick', type: 'int24' }, { name: 'sqrtPriceX96', type: 'uint160' }, { name: 'activeLiquidity', type: 'uint128' }, { name: 'amount0', type: 'int256' }, { name: 'amount1', type: 'int256' }, { name: 'tradeDirection', type: 'uint8' }, { name: 'externality', type: 'uint256' }, { name: 'resolved', type: 'bool' }, { name: 'createdTimestamp', type: 'uint256' }] }] },
  { name: 'getLPEpisodeAttribution', type: 'function', stateMutability: 'view', inputs: [{ name: 'lp', type: 'address' }, { name: 'episodeId', type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { name: 'getLPTotalExternality', type: 'function', stateMutability: 'view', inputs: [{ name: 'lp', type: 'address' }], outputs: [{ type: 'uint256' }] },
];

const client = createPublicClient({ chain: sepolia, transport: http('https://ethereum-sepolia-rpc.publicnode.com') });

async function main() {
  console.log('=== ATTRIBUTION CHECK ===\n');

  const totalExt = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getLPTotalExternality', args: [LP] });
  console.log(`LP Total Externality: ${formatEther(totalExt)} ETH (raw: ${totalExt})`);

  console.log('\n--- Checking ALL 20 episodes ---');
  for (let i = 0; i < 20; i++) {
    const ep = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getEpisode', args: [BigInt(i)] });
    const attr = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getLPEpisodeAttribution', args: [LP, BigInt(i)] });
    console.log(`Episode #${i}: resolved=${ep.resolved}, externality=${formatEther(ep.externality)}, LP_attribution=${formatEther(attr)}`);
  }
}

main().catch(console.error);
