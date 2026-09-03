import { useState, useEffect } from 'react';
import { Search, Lightbulb, Inbox, Download, VolumeX, CheckCircle, Clock, CircleDot, Circle } from 'lucide-react';
import {
  getLPTotalExternality,
  getLPSegments,
  getLPEpisodeAttribution,
  getEpisode,
  getActiveLPList,
  shortenAddress,
  formatTimestamp,
  tickToPrice,
} from '../hooks';

// In Uniswap v4, the Hook sees the PositionManager as the LP caller,
// not the end-user wallet. This is the known active LP from the contract.
const KNOWN_LP_ADDRESSES = [
  {
    address: '0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4',
    label: 'PositionManager (Active LP)',
  },
];

export default function PositionExplorer() {
  const [address, setAddress] = useState('');
  const [loading, setLoading] = useState(false);
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [activeLPs, setActiveLPs] = useState([]);

  useEffect(() => {
    // Auto-load active LPs for suggestions
    getActiveLPList().then(setActiveLPs).catch(() => {});
  }, []);

  async function handleSearch(searchAddr) {
    const addr = searchAddr || address;
    if (!addr || !addr.startsWith('0x') || addr.length !== 42) {
      setError('Please enter a valid Ethereum address (0x...)');
      return;
    }
    setAddress(addr);
    setLoading(true);
    setError(null);
    try {
      const [externality, segments] = await Promise.all([
        getLPTotalExternality(addr),
        getLPSegments(addr),
      ]);

      // Load attributions efficiently without duplicate RPC calls
      const attributions = [];
      if (segments.length > 0) {
        // Find the absolute min and max episode IDs to check
        const minEp = Math.min(...segments.map(s => s.firstEpisodeId));
        // We shouldn't check beyond what actually exists on-chain to avoid reverts
        const { getNextEpisodeId } = await import('../hooks');
        const nextId = await getNextEpisodeId();
        const maxEp = nextId - 1;

        // Fetch sequentially to respect public RPC rate limits
        for (let epId = minEp; epId <= maxEp; epId++) {
          try {
            const [attr, episode] = await Promise.all([
              getLPEpisodeAttribution(addr, epId),
              getEpisode(epId),
            ]);
            // Only show episodes that have some attribution or are successfully resolved
            if (attr.raw !== '0' || episode.resolved) {
              attributions.push({
                episodeId: epId,
                attribution: attr,
                episode,
              });
            }
          } catch (err) {
            console.error(`Error fetching episode ${epId}:`, err);
            // Don't break, just continue to next episode if one fails occasionally
          }
        }
      }

      setData({ externality, segments, attributions });
    } catch (err) {
      setError(err.message);
    }
    setLoading(false);
  }

  function exportCSV() {
    if (!data) return;
    const headers = 'EpisodeID,Block,Tick,Direction,RSPE,Attribution,Resolved,Timestamp\n';
    const rows = data.attributions.map(a =>
      `${a.episodeId},${a.episode.blockNumber},${a.episode.tick},${a.episode.tradeDirection === 0 ? 'Sell' : 'Buy'},${a.episode.externalityFormatted},${a.attribution.formatted},${a.episode.resolved},${new Date(a.episode.createdTimestamp * 1000).toISOString()}`
    ).join('\n');
    const blob = new Blob([headers + rows], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `exposure_${shortenAddress(address)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  // Merge known addresses with any dynamically discovered ones
  const suggestions = [...new Set([
    ...KNOWN_LP_ADDRESSES.map(k => k.address),
    ...activeLPs,
  ])];

  return (
    <div>
      <div style={{ marginBottom: '32px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '8px' }}>
          <Search size={28} />
          <h1 style={{ fontSize: '28px', fontWeight: 800, margin: 0 }}>Position Explorer</h1>
        </div>
        <p style={{ color: 'var(--text-secondary)' }}>
          Query any LP's MEV exposure, segment history, and per-episode attribution.
        </p>
      </div>

      {/* Info Banner about PositionManager */}
      <div className="glass-card" style={{
        marginBottom: '16px',
        padding: '16px 20px',
        borderColor: 'rgba(68, 138, 255, 0.2)',
        background: 'rgba(68, 138, 255, 0.05)',
      }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: '12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', width: '24px', height: '24px', borderRadius: '50%', background: 'rgba(68, 138, 255, 0.1)', color: 'var(--info-blue)' }}>
            <Lightbulb size={16} />
          </div>
          <div>
            <div style={{ fontSize: '13px', fontWeight: 600, color: 'var(--info-blue)', marginBottom: '4px' }}>
              Uniswap v4 Architecture Note
            </div>
            <div style={{ fontSize: '12px', color: 'var(--text-secondary)', lineHeight: 1.5 }}>
              In Uniswap v4, liquidity is added through the <strong>PositionManager</strong> contract.
              The Hook sees the PositionManager as the LP caller, not your wallet directly.
              Search the PositionManager address below to see LP exposure data.
            </div>
          </div>
        </div>
      </div>

      {/* Search */}
      <div className="glass-card" style={{ marginBottom: '24px' }}>
        <div className="input-group">
          <input
            className="input-field"
            placeholder="Enter LP / PositionManager address (0x...)"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && handleSearch()}
          />
          <button className="btn-primary" onClick={() => handleSearch()} disabled={loading}>
            {loading ? 'Querying...' : 'Search Position'}
          </button>
        </div>

        {/* Suggested addresses */}
        <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap', alignItems: 'center' }}>
          <span style={{ fontSize: '12px', color: 'var(--text-muted)' }}>Active LPs:</span>
          {suggestions.map(addr => {
            const known = KNOWN_LP_ADDRESSES.find(k => k.address.toLowerCase() === addr.toLowerCase());
            return (
              <button
                key={addr}
                className="btn-secondary"
                style={{ fontSize: '11px', borderColor: 'rgba(0, 230, 118, 0.2)' }}
                onClick={() => handleSearch(addr)}
              >
                <CircleDot size={12} color="var(--safe-green)" style={{ marginRight: '4px' }} />
                {known ? known.label : shortenAddress(addr)}
              </button>
            );
          })}
        </div>
      </div>

      {error && (
        <div className="glass-card glow-red" style={{ marginBottom: '24px', color: 'var(--mev-red)' }}>
          ⚠️ {error}
        </div>
      )}

      {loading && (
        <div className="loading-wave">
          <span /><span /><span /><span /><span />
        </div>
      )}

      {data && !loading && (
        <>
          {/* Summary Stats */}
          <div className="stats-grid">
            <div className="glass-card stat-card glow-red">
              <div className="stat-label">Total RSPE</div>
              <div className="stat-value" style={{ fontSize: '24px', color: data.externality.formatted !== '0' ? 'var(--mev-red)' : 'var(--text-primary)' }}>
                {data.externality.formatted}
              </div>
              <div className="stat-unit">Cumulative adverse selection (ETH)</div>
            </div>
            <div className="glass-card stat-card">
              <div className="stat-label">Segments</div>
              <div className="stat-value" style={{ fontSize: '24px' }}>{data.segments.length}</div>
              <div className="stat-unit">Exposure periods tracked</div>
            </div>
            <div className="glass-card stat-card glow-green">
              <div className="stat-label">Active Positions</div>
              <div className="stat-value" style={{ fontSize: '24px', color: 'var(--safe-green)' }}>
                {data.segments.filter(s => s.isActive).length}
              </div>
              <div className="stat-unit">Currently providing liquidity</div>
            </div>
            <div className="glass-card stat-card">
              <div className="stat-label">Episodes Attributed</div>
              <div className="stat-value" style={{ fontSize: '24px' }}>{data.attributions.length}</div>
              <div className="stat-unit">Swaps that affected this LP</div>
            </div>
          </div>

          {/* Segments */}
          <div className="glass-card" style={{ marginBottom: '24px' }}>
            <div className="section-header">
              <div>
                <h2 className="section-title">Exposure Segments</h2>
                <div className="section-subtitle">
                  Each segment = one addLiquidity call. {data.segments.length} positions tracked across ticks [{data.segments[0]?.tickLower}, {data.segments[0]?.tickUpper}]
                </div>
              </div>
            </div>

            {data.segments.length === 0 ? (
              <div className="empty-state">
                <div className="empty-state-icon" style={{ display: 'flex', justifyContent: 'center', marginBottom: '16px' }}><Inbox size={48} color="var(--text-muted)" /></div>
                <div className="empty-state-title">No segments found</div>
                <p>This address hasn't provided liquidity to the tracked pool.</p>
              </div>
            ) : (
              <>
                <table className="episode-table">
                  <thead>
                    <tr>
                      <th>#</th>
                      <th>Range (Ticks)</th>
                      <th>Liquidity</th>
                      <th>Episodes</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.segments.map((seg, i) => (
                      <tr key={i}>
                        <td>{i + 1}</td>
                        <td className="mono">
                          [{seg.tickLower}, {seg.tickUpper}]
                        </td>
                        <td className="mono" style={{ fontSize: '12px' }}>
                          {(Number(BigInt(seg.liquidity)) / 1e18).toFixed(2)} × 10¹⁸
                        </td>
                        <td className="mono">
                          {seg.firstEpisodeId} → {seg.isActive ? '∞ (now)' : seg.lastEpisodeId}
                        </td>
                        <td>
                          <span className={`badge ${seg.isActive ? 'badge-active' : 'badge-closed'}`} style={{ display: 'inline-flex', alignItems: 'center', gap: '4px' }}>
                            {seg.isActive ? <><CircleDot size={10} /> Active</> : <><Circle size={10} /> Closed</>}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                <div style={{ marginTop: '12px', fontSize: '12px', color: 'var(--text-muted)' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                    <Lightbulb size={14} color="var(--info-blue)" />
                    <span>Each segment represents a separate <code style={{ color: 'var(--info-blue)' }}>addLiquidity</code> transaction.</span>
                  </div>
                  20 segments = 20 liquidity additions via the PositionManager.
                </div>
              </>
            )}
          </div>

          {/* Attribution History */}
          <div className="glass-card">
            <div className="section-header">
              <div>
                <h2 className="section-title">Attribution History</h2>
                <div className="section-subtitle">Per-episode RSPE breakdown for this LP</div>
              </div>
              {data.attributions.length > 0 && (
                <button className="btn-secondary" style={{ display: 'flex', alignItems: 'center', gap: '6px' }} onClick={exportCSV}>
                  <Download size={14} /> Export CSV
                </button>
              )}
            </div>

            {data.attributions.length === 0 ? (
              <div className="empty-state">
                <div className="empty-state-icon" style={{ display: 'flex', justifyContent: 'center', marginBottom: '16px' }}><VolumeX size={48} color="var(--text-muted)" /></div>
                <div className="empty-state-title">No attributions yet</div>
                <p style={{ maxWidth: '400px', margin: '0 auto' }}>
                  {data.segments.length > 0
                    ? 'Segments exist but no episodes have been resolved with non-zero RSPE yet. Only Episode #19 is resolved so far.'
                    : 'No adverse selection has been attributed to this position.'
                  }
                </p>
              </div>
            ) : (
              <table className="episode-table">
                <thead>
                  <tr>
                    <th>Episode</th>
                    <th>Block</th>
                    <th>Episode RSPE</th>
                    <th>Your Share</th>
                    <th>Status</th>
                    <th>Time</th>
                  </tr>
                </thead>
                <tbody>
                  {data.attributions.map((a) => (
                    <tr key={a.episodeId}>
                      <td style={{ color: 'var(--info-blue)' }}>#{a.episodeId}</td>
                      <td>{a.episode.blockNumber}</td>
                      <td className="mono" style={{ color: 'var(--warning-amber)' }}>
                        {a.episode.externalityFormatted}
                      </td>
                      <td className="mono" style={{ color: 'var(--mev-red)', fontWeight: 600 }}>
                        {a.attribution.formatted}
                      </td>
                      <td>
                        <span className={`badge ${a.episode.resolved ? 'badge-resolved' : 'badge-pending'}`} style={{ display: 'inline-flex', alignItems: 'center', gap: '4px' }}>
                          {a.episode.resolved ? <><CheckCircle size={10} /> Resolved</> : <><Clock size={10} /> Pending</>}
                        </span>
                      </td>
                      <td style={{ fontSize: '11px' }}>{formatTimestamp(a.episode.createdTimestamp)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </>
      )}
    </div>
  );
}
