import { useState, useEffect } from 'react';
import { AlertTriangle, Search, Microscope, Inbox, CheckCircle, Clock, RotateCw, ArrowUpRight, ArrowDownRight } from 'lucide-react';
import { getNextEpisodeId, getEpisodes, getActiveLPCount, getActiveLPList, getLPTotalExternality, formatTimestamp, shortenAddress } from '../hooks';

export default function Dashboard({ onNavigate }) {
  const [stats, setStats] = useState({ totalEpisodes: 0, activeLPs: 0, totalRSPE: '0' });
  const [recentEpisodes, setRecentEpisodes] = useState([]);
  const [lpList, setLpList] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    loadData();
  }, []);

  async function loadData() {
    setLoading(true);
    setError(null);
    try {
      const [nextId, lpCount] = await Promise.all([
        getNextEpisodeId(),
        getActiveLPCount(),
      ]);

      // Load recent episodes
      const episodes = await getEpisodes(10);
      setRecentEpisodes(episodes);

      // Load LP data
      let lps = [];
      let totalRSPE = BigInt(0);
      try {
        const lpAddresses = await getActiveLPList();
        for (const addr of lpAddresses) {
          const ext = await getLPTotalExternality(addr);
          totalRSPE += BigInt(ext.raw);
          lps.push({ address: addr, externality: ext });
        }
      } catch { /* LP list may be empty */ }

      setLpList(lps);
      setStats({
        totalEpisodes: nextId,
        activeLPs: lpCount,
        totalRSPE: (Number(totalRSPE) / 1e18).toFixed(6),
      });
    } catch (err) {
      setError(err.message);
    }
    setLoading(false);
  }

  if (loading) {
    return (
      <div className="loading-wave">
        <span /><span /><span /><span /><span />
      </div>
    );
  }

  if (error) {
    return (
      <div className="glass-card" style={{ textAlign: 'center', padding: '48px' }}>
        <div style={{ display: 'flex', justifyContent: 'center', marginBottom: '16px' }}><AlertTriangle size={48} color="var(--mev-red)" /></div>
        <h3 style={{ color: 'var(--mev-red)', marginBottom: '8px' }}>Connection Error</h3>
        <p style={{ color: 'var(--text-secondary)', marginBottom: '16px' }}>{error}</p>
        <button className="btn-primary" onClick={loadData}>Retry</button>
      </div>
    );
  }

  const resolvedCount = recentEpisodes.filter(e => e.resolved).length;
  const pendingCount = recentEpisodes.filter(e => !e.resolved).length;

  return (
    <div>
      {/* Hero */}
      <div style={{ textAlign: 'center', marginBottom: '48px', paddingTop: '24px' }}>
        <h1 style={{ fontSize: '42px', fontWeight: 900, marginBottom: '12px' }}>
          <span style={{ background: 'linear-gradient(135deg, #e8e8f0, #a0a0ff)', WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent' }}>
            MEV-Ray Vision
          </span>
        </h1>
        <p style={{ fontSize: '16px', color: 'var(--text-secondary)', maxWidth: '600px', margin: '0 auto' }}>
          Position-level MEV attribution for Uniswap v4. See exactly how much adverse selection YOUR position bears.
        </p>
      </div>

      {/* Stats Grid */}
      <div className="stats-grid">
        <div className="glass-card stat-card heartbeat">
          <div className="stat-label">Total Episodes</div>
          <div className="stat-value">{stats.totalEpisodes}</div>
          <div className="stat-unit">Swap snapshots recorded</div>
        </div>

        <div className="glass-card stat-card glow-green">
          <div className="stat-label">Active LPs</div>
          <div className="stat-value" style={{ color: 'var(--safe-green)' }}>{stats.activeLPs}</div>
          <div className="stat-unit">Positions being tracked</div>
        </div>

        <div className="glass-card stat-card glow-red">
          <div className="stat-label">Total RSPE Attributed</div>
          <div className="stat-value" style={{ color: 'var(--mev-red)' }}>{stats.totalRSPE}</div>
          <div className="stat-unit">Realized adverse selection (ETH)</div>
        </div>

        <div className="glass-card stat-card">
          <div className="stat-label">Resolution Rate</div>
          <div className="stat-value">{recentEpisodes.length > 0 ? Math.round(resolvedCount / recentEpisodes.length * 100) : 0}%</div>
          <div className="stat-unit">{resolvedCount} resolved / {pendingCount} pending</div>
        </div>
      </div>

      {/* Quick Actions */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px', marginBottom: '32px' }}>
        <button
          className="glass-card"
          style={{ cursor: 'pointer', textAlign: 'left', border: '1px solid rgba(100,100,255,0.15)' }}
          onClick={() => onNavigate('explorer')}
        >
          <div style={{ marginBottom: '8px', color: 'var(--info-blue)' }}><Search size={28} /></div>
          <h3 style={{ fontSize: '16px', marginBottom: '4px' }}>Position Explorer</h3>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)' }}>
            Query any LP's MEV exposure, segments, and attribution history
          </p>
        </button>
        <button
          className="glass-card"
          style={{ cursor: 'pointer', textAlign: 'left', border: '1px solid rgba(100,100,255,0.15)' }}
          onClick={() => onNavigate('rayvision')}
        >
          <div style={{ marginBottom: '8px', color: 'var(--safe-green)' }}><Microscope size={28} /></div>
          <h3 style={{ fontSize: '16px', marginBottom: '4px' }}>MEV-Ray Vision</h3>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)' }}>
            Visualize LP ranges colored by MEV intensity — see who's most exposed
          </p>
        </button>
      </div>

      {/* Recent Episodes */}
      <div className="glass-card">
        <div className="section-header">
          <div>
            <h2 className="section-title">Recent Episodes</h2>
            <div className="section-subtitle">Latest swap snapshots and their resolution status</div>
          </div>
          <button className="btn-secondary" style={{ display: 'flex', alignItems: 'center', gap: '6px' }} onClick={loadData}>
            <RotateCw size={14} /> Refresh
          </button>
        </div>

        {recentEpisodes.length === 0 ? (
          <div className="empty-state">
            <div className="empty-state-icon" style={{ display: 'flex', justifyContent: 'center', marginBottom: '16px' }}><Inbox size={48} color="var(--text-muted)" /></div>
            <div className="empty-state-title">No episodes yet</div>
            <p>Execute a swap on the pool to create the first episode.</p>
          </div>
        ) : (
          <table className="episode-table">
            <thead>
              <tr>
                <th>ID</th>
                <th>Block</th>
                <th>Tick</th>
                <th>Direction</th>
                <th>RSPE</th>
                <th>Status</th>
                <th>Time</th>
              </tr>
            </thead>
            <tbody>
              {recentEpisodes.map((ep) => (
                <tr key={ep.episodeId}>
                  <td style={{ color: 'var(--info-blue)' }}>#{ep.episodeId}</td>
                  <td>{ep.blockNumber}</td>
                  <td>{ep.tick}</td>
                  <td style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                    {ep.tradeDirection === 0 
                      ? <><ArrowDownRight size={14} color="var(--mev-red)" /> Sell</> 
                      : <><ArrowUpRight size={14} color="var(--safe-green)" /> Buy</>}
                  </td>
                  <td style={{ color: ep.externality !== '0' ? 'var(--mev-red)' : 'var(--text-muted)' }}>
                    {ep.externalityFormatted}
                  </td>
                  <td>
                    <span className={`badge ${ep.resolved ? 'badge-resolved' : 'badge-pending'}`} style={{ display: 'inline-flex', alignItems: 'center', gap: '4px' }}>
                      {ep.resolved ? <><CheckCircle size={10} /> Resolved</> : <><Clock size={10} /> Pending</>}
                    </span>
                  </td>
                  <td style={{ fontSize: '11px' }}>{formatTimestamp(ep.createdTimestamp)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* LP Leaderboard */}
      {lpList.length > 0 && (
        <div className="glass-card" style={{ marginTop: '24px' }}>
          <div className="section-header">
            <div>
              <h2 className="section-title">LP MEV Leaderboard</h2>
              <div className="section-subtitle">Ranked by total adverse selection exposure</div>
            </div>
          </div>
          <table className="episode-table">
            <thead>
              <tr>
                <th>Rank</th>
                <th>LP Address</th>
                <th>Total RSPE</th>
              </tr>
            </thead>
            <tbody>
              {lpList
                .sort((a, b) => Number(BigInt(b.externality.raw) - BigInt(a.externality.raw)))
                .map((lp, i) => (
                  <tr key={lp.address}>
                    <td style={{ color: 'var(--warning-amber)' }}>#{i + 1}</td>
                    <td>
                      <span className="mono" style={{ color: 'var(--info-blue)' }}>
                        {shortenAddress(lp.address)}
                      </span>
                    </td>
                    <td style={{ color: 'var(--mev-red)' }}>{lp.externality.formatted} ETH</td>
                  </tr>
                ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
