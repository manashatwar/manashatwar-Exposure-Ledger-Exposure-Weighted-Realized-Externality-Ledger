export const HOOK_ADDRESS = '0x30D4F958F727518e4E5949538877065aBF924a40';
export const RELAYER_ADDRESS = '0xd31632A241c76072266cAd1beC48C7F16ede27F7';
export const RSC_ADDRESS = '0xc2822c389635f547e417c52BCd581889dB0553Cf';
export const SEPOLIA_CHAIN_ID = 11155111;

export const HOOK_ABI = [
  {
    name: 'nextEpisodeId',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'getEpisode',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'episodeId', type: 'uint256' }],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'episodeId', type: 'uint64' },
          { name: 'blockNumber', type: 'uint64' },
          { name: 'tick', type: 'int24' },
          { name: 'sqrtPriceX96', type: 'uint160' },
          { name: 'activeLiquidity', type: 'uint128' },
          { name: 'amount0', type: 'int256' },
          { name: 'amount1', type: 'int256' },
          { name: 'tradeDirection', type: 'uint8' },
          { name: 'externality', type: 'uint256' },
          { name: 'resolved', type: 'bool' },
          { name: 'createdTimestamp', type: 'uint256' },
        ],
      },
    ],
  },
  {
    name: 'getLPTotalExternality',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'lp', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'getLPSegments',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'lp', type: 'address' }],
    outputs: [
      {
        type: 'tuple[]',
        components: [
          { name: 'lp', type: 'address' },
          { name: 'tickLower', type: 'int24' },
          { name: 'tickUpper', type: 'int24' },
          { name: 'liquidity', type: 'uint128' },
          { name: 'firstEpisodeId', type: 'uint64' },
          { name: 'lastEpisodeId', type: 'uint64' },
        ],
      },
    ],
  },
  {
    name: 'getLPEpisodeAttribution',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'lp', type: 'address' },
      { name: 'episodeId', type: 'uint256' },
    ],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'getLPActiveSegment',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'lp', type: 'address' }],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'lp', type: 'address' },
          { name: 'tickLower', type: 'int24' },
          { name: 'tickUpper', type: 'int24' },
          { name: 'liquidity', type: 'uint128' },
          { name: 'firstEpisodeId', type: 'uint64' },
          { name: 'lastEpisodeId', type: 'uint64' },
        ],
      },
    ],
  },
  {
    name: 'getEpisodeExposedLPs',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'episodeId', type: 'uint256' }],
    outputs: [{ type: 'address[]' }],
  },
  {
    name: 'activeLPCount',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'getActiveLPList',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address[]' }],
  },
  {
    name: 'lpTotalExternality',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'episodes',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'uint256' }],
    outputs: [
      { name: 'episodeId', type: 'uint64' },
      { name: 'blockNumber', type: 'uint64' },
      { name: 'tick', type: 'int24' },
      { name: 'sqrtPriceX96', type: 'uint160' },
      { name: 'activeLiquidity', type: 'uint128' },
      { name: 'amount0', type: 'int256' },
      { name: 'amount1', type: 'int256' },
      { name: 'tradeDirection', type: 'uint8' },
      { name: 'externality', type: 'uint256' },
      { name: 'resolved', type: 'bool' },
      { name: 'createdTimestamp', type: 'uint256' },
    ],
  },
];
