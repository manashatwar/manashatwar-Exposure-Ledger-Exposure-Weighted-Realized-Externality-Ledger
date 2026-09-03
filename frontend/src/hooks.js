import { createPublicClient, http, formatEther } from 'viem';
import { sepolia } from 'viem/chains';
import { HOOK_ADDRESS, HOOK_ABI } from './contracts';

const client = createPublicClient({
  chain: sepolia,
  transport: http('https://ethereum-sepolia-rpc.publicnode.com'),
});

export async function getNextEpisodeId() {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'nextEpisodeId',
  });
  return Number(result);
}

export async function getEpisode(episodeId) {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'getEpisode',
    args: [BigInt(episodeId)],
  });
  return {
    episodeId: Number(result.episodeId),
    blockNumber: Number(result.blockNumber),
    tick: Number(result.tick),
    sqrtPriceX96: result.sqrtPriceX96.toString(),
    activeLiquidity: result.activeLiquidity.toString(),
    amount0: result.amount0.toString(),
    amount1: result.amount1.toString(),
    tradeDirection: Number(result.tradeDirection),
    externality: result.externality.toString(),
    externalityFormatted: formatEther(result.externality),
    resolved: result.resolved,
    createdTimestamp: Number(result.createdTimestamp),
  };
}

export async function getEpisodes(count = 20) {
  const nextId = await getNextEpisodeId();
  const start = Math.max(0, nextId - count);
  const episodes = [];
  for (let i = nextId - 1; i >= start; i--) {
    try {
      const ep = await getEpisode(i);
      episodes.push(ep);
    } catch {
      break;
    }
  }
  return episodes;
}

export async function getLPTotalExternality(lpAddress) {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'getLPTotalExternality',
    args: [lpAddress],
  });
  return {
    raw: result.toString(),
    formatted: formatEther(result),
  };
}

export async function getLPSegments(lpAddress) {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'getLPSegments',
    args: [lpAddress],
  });
  return result.map((seg) => ({
    lp: seg.lp,
    tickLower: Number(seg.tickLower),
    tickUpper: Number(seg.tickUpper),
    liquidity: seg.liquidity.toString(),
    firstEpisodeId: Number(seg.firstEpisodeId),
    lastEpisodeId: Number(seg.lastEpisodeId),
    isActive: Number(seg.lastEpisodeId) === 0 || Number(seg.lastEpisodeId) === 18446744073709551615,
  }));
}

export async function getLPEpisodeAttribution(lpAddress, episodeId) {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'getLPEpisodeAttribution',
    args: [lpAddress, BigInt(episodeId)],
  });
  return {
    raw: result.toString(),
    formatted: formatEther(result),
  };
}

export async function getActiveLPCount() {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'activeLPCount',
  });
  return Number(result);
}

export async function getActiveLPList() {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'getActiveLPList',
  });
  return [...result];
}

export async function getEpisodeExposedLPs(episodeId) {
  const result = await client.readContract({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'getEpisodeExposedLPs',
    args: [BigInt(episodeId)],
  });
  return [...result];
}

export function sqrtPriceX96ToPrice(sqrtPriceX96Str) {
  const sqrtPrice = BigInt(sqrtPriceX96Str);
  const Q96 = BigInt(2) ** BigInt(96);
  const sq = sqrtPrice * sqrtPrice;
  const precision = BigInt(10) ** BigInt(18);
  const price = (sq * precision) / (Q96 * Q96);
  return Number(price) / 1e18;
}

export function shortenAddress(addr) {
  if (!addr) return '';
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function formatTimestamp(ts) {
  if (!ts) return '—';
  return new Date(ts * 1000).toLocaleString();
}

export function tickToPrice(tick) {
  return Math.pow(1.0001, tick);
}
