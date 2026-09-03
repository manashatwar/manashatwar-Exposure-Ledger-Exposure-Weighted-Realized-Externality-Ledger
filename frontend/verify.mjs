import { createPublicClient, http } from 'viem';
import { sepolia } from 'viem/chains';

const HOOK = '0x30D4F958F727518e4E5949538877065aBF924a40';
const ABI = [
  { name: 'getActiveLPList', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address[]' }] },
  { name: 'nextEpisodeId', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'getLPSegments', type: 'function', stateMutability: 'view', inputs: [{ name: 'lp', type: 'address' }], outputs: [{ type: 'tuple[]', components: [{ name: 'lp', type: 'address' }, { name: 'tickLower', type: 'int24' }, { name: 'tickUpper', type: 'int24' }, { name: 'liquidity', type: 'uint128' }, { name: 'firstEpisodeId', type: 'uint64' }, { name: 'lastEpisodeId', type: 'uint64' }] }] },
  { name: 'getLPTotalExternality', type: 'function', stateMutability: 'view', inputs: [{ name: 'lp', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'getEpisode', type: 'function', stateMutability: 'view', inputs: [{ name: 'episodeId', type: 'uint256' }], outputs: [{ type: 'tuple', components: [{ name: 'episodeId', type: 'uint64' }, { name: 'blockNumber', type: 'uint64' }, { name: 'tick', type: 'int24' }, { name: 'sqrtPriceX96', type: 'uint160' }, { name: 'activeLiquidity', type: 'uint128' }, { name: 'amount0', type: 'int256' }, { name: 'amount1', type: 'int256' }, { name: 'tradeDirection', type: 'uint8' }, { name: 'externality', type: 'uint256' }, { name: 'resolved', type: 'bool' }, { name: 'createdTimestamp', type: 'uint256' }] }] },
];

const client = createPublicClient({ chain: sepolia, transport: http('https://ethereum-sepolia-rpc.publicnode.com') });

async function main() {
  console.log('=== ON-CHAIN DATA VERIFICATION ===\n');

  const nextId = await client.readContract({ address: HOOK, abi: ABI, functionName: 'nextEpisodeId' });
  console.log('nextEpisodeId:', Number(nextId));

  const lpList = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getActiveLPList' });
  console.log('Active LP List:', lpList);

  for (const lp of lpList) {
    console.log(`\n--- LP: ${lp} ---`);
    const ext = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getLPTotalExternality', args: [lp] });
    console.log('  Total Externality:', ext.toString(), '=', Number(ext) / 1e18, 'ETH');

    const segments = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getLPSegments', args: [lp] });
    console.log('  Segments count:', segments.length);
    segments.forEach((seg, i) => {
      console.log(`  Segment ${i}: tick=[${seg.tickLower}, ${seg.tickUpper}], liquidity=${seg.liquidity}, episodes=[${seg.firstEpisodeId}→${Number(seg.lastEpisodeId) === 18446744073709551615 ? 'active' : seg.lastEpisodeId}]`);
    });
  }

  // Check first and last episode
  for (const id of [0, Number(nextId) - 1]) {
    const ep = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getEpisode', args: [BigInt(id)] });
    console.log(`\nEpisode #${id}:`, {
      block: Number(ep.blockNumber),
      tick: Number(ep.tick),
      direction: Number(ep.tradeDirection),
      externality: Number(ep.externality) / 1e18,
      resolved: ep.resolved,
      timestamp: new Date(Number(ep.createdTimestamp) * 1000).toISOString(),
    });
  }

  // Also check user wallet
  const userWallet = '0x1d2207f52782aaF69649a8c23EB9b9D83C2066ED';
  const userExt = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getLPTotalExternality', args: [userWallet] });
  const userSegs = await client.readContract({ address: HOOK, abi: ABI, functionName: 'getLPSegments', args: [userWallet] });
  console.log(`\n--- User Wallet: ${userWallet} ---`);
  console.log('  Total Externality:', userExt.toString());
  console.log('  Segments:', userSegs.length);
}

main().catch(console.error);
