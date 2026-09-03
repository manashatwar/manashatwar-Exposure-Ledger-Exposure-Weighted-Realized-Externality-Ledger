import { useState, useEffect } from 'react';
import { Microscope, Search, RotateCw, CircleDot, Circle } from 'lucide-react';
import {
  getActiveLPList,
  getLPSegments,
  getLPTotalExternality,
  getEpisodes,
  shortenAddress,
  sqrtPriceX96ToPrice,
} from '../hooks';

export default function MevRayVision() {
  const [lpData, setLpData] = useState([]);
  const [episodes, setEpisodes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [currentPrice, setCurrentPrice] = useState(null);

  useEffect(() => {
    loadData();
  }, []);

  async function loadData() {
    setLoading(true);
    try {
      const [lpAddresses, recentEpisodes] = await Promise.all([
        getActiveLPList(),
        getEpisodes(20),
      ]);

      // Get current price from latest episode
      if (recentEpisodes.length > 0) {
        setCurrentPrice(sqrtPriceX96ToPrice(recentEpisodes[0].sqrtPriceX96));
      }

      setEpisodes(recentEpisodes);

      // Load LP data with segments and externality
      const data = [];
      for (const addr of lpAddresses) {
        try {
          const [segments, ext] = await Promise.all([
            getLPSegments(addr),
            getLPTotalExternality(addr),
          ]);
          data.push({
            address: addr,
            segments,
            externality: ext,
            externalityNum: Number(ext.raw) / 1e18,
          });
        } catch { /* skip */ }
      }

      setLpData(data);
    } catch (err) {
      console.error('MevRayVision load error:', err);
    }
    setLoading(false);
  }

  // Get the max externality for color normalization
  const maxExternality = Math.max(...lpData.map(lp => lp.externalityNum), 0.000001);

  // Get tick range for visualization
  const allTicks = lpData.flatMap(lp => lp.segments.flatMap(s => [s.tickLower, s.tickUpper]));
  const minTick = allTicks.length > 0 ? Math.min(...allTicks) : -100;
  const maxTick = allTicks.length > 0 ? Math.max(...allTicks) : 100;
  const tickRange = maxTick - minTick || 200;

  function getMevColor(intensity) {
    // 0 = green, 0.5 = amber, 1 = red
    const clamped = Math.min(Math.max(intensity, 0), 1);
    if (clamped < 0.5) {
      const t = clamped * 2;
      const r = Math.round(0 + t * 255);
      const g = Math.round(230 - t * 60);
      const b = Math.round(118 - t * 78);
      return `rgb(${r}, ${g}, ${b})`;
    }
    const t = (clamped - 0.5) * 2;
    const r = Math.round(255);
    const g = Math.round(170 - t * 102);
    const b = Math.round(40 + t * 28);
    return `rgb(${r}, ${g}, ${b})`;
  }

  if (loading) {
    return (
      <div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '8px' }}>
          <Microscope size={28} />
          <h1 style={{ fontSize: '28px', fontWeight: 800, margin: 0 }}>MEV-Ray Vision</h1>
        </div>
        <div className="loading-wave">
          <span /><span /><span /><span /><span />
        </div>
      </div>
    );
  }

  return (
    <div>
      <div style={{ marginBottom: '32px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '8px' }}>
          <Microscope size={28} />
          <h1 style={{ fontSize: '28px', fontWeight: 800, margin: 0 }}>MEV-Ray Vision</h1>
        </div>
        <p style={{ color: 'var(--text-secondary)' }}>
          LP ranges visualized as beams — color intensity represents MEV exposure (green = low, red = high).
        </p>
      </div>

      {/* MEV Gradient Legend */}
      <div className="glass-card" style={{ marginBottom: '24px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <span style={{ fontSize: '12px', color: 'var(--text-muted)' }}>MEV Intensity:</span>
          <div style={{
            flex: 1,
            height: '8px',
            borderRadius: '4px',
            background: 'var(--gradient-mev)',
          }} />
          <div style={{ display: 'flex', gap: '24px', fontSize: '11px', color: 'var(--text-muted)' }}>
            <span style={{ color: 'var(--safe-green)' }}>Low RSPE</span>
            <span style={{ color: 'var(--warning-amber)' }}>Medium</span>
            <span style={{ color: 'var(--mev-red)' }}>High RSPE</span>
          </div>
        </div>
        {currentPrice && (
          <div style={{ marginTop: '12px', fontSize: '13px', color: 'var(--text-secondary)' }}>
            Current Pool Price: <span className="mono" style={{ color: 'var(--info-blue)' }}>
              {currentPrice.toFixed(8)}
            </span> token1/token0
          </div>
        )}
      </div>

      {/* Ray Vision Bars */}
      {lpData.length === 0 ? (
        <div className="glass-card">
          <div className="empty-state">
            <div className="empty-state-icon" style={{ display: 'flex', justifyContent: 'center', marginBottom: '16px' }}><Search size={48} color="var(--text-muted)" /></div>
            <div className="empty-state-title">No LP positions to visualize</div>
            <p>Add liquidity to the pool to see MEV-Ray Vision in action.</p>
          </div>
        </div>
      ) : (
        <div className="glass-card">
          <div className="section-header">
            <div>
              <h2 className="section-title">LP Range Exposure Map</h2>
              <div className="section-subtitle">
                Each bar represents an LP position — width shows range, color shows MEV exposure
              </div>
            </div>
            <button className="btn-secondary" style={{ display: 'flex', alignItems: 'center', gap: '6px' }} onClick={loadData}>
              <RotateCw size={14} /> Refresh
            </button>
          </div>

          {/* Tick axis */}
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '0 16px', marginBottom: '8px' }}>
            <span className="mono" style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
              Tick {minTick}
            </span>
            <span className="mono" style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
              Tick {maxTick}
            </span>
          </div>

          {lpData.map((lp, lpIdx) =>
            lp.segments.map((seg, segIdx) => {
              const intensity = lp.externalityNum / maxExternality;
              const color = getMevColor(intensity);
              const left = ((seg.tickLower - minTick) / tickRange) * 100;
              const width = ((seg.tickUpper - seg.tickLower) / tickRange) * 100;

              return (
                <div className="ray-bar" key={`${lpIdx}-${segIdx}`}>
                  <div style={{ minWidth: '100px' }}>
                    <div className="mono" style={{ fontSize: '12px', color: 'var(--info-blue)' }}>
                      {shortenAddress(lp.address)}
                    </div>
                    <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
                      RSPE: {lp.externalityNum.toFixed(6)}
                    </div>
                  </div>

                  <div className="ray-range" style={{ background: 'rgba(15,15,35,0.5)' }}>
                    <div
                      className="ray-fill"
                      style={{
                        background: color,
                        boxShadow: `0 0 12px ${color}40`,
                        width: `${Math.max(width, 2)}%`,
                        marginLeft: `${Math.max(left, 0)}%`,
                      }}
                    />
                  </div>

                  <div style={{ minWidth: '80px', textAlign: 'right' }}>
                    <span className={`badge ${seg.isActive ? 'badge-active' : 'badge-closed'}`} style={{ display: 'inline-flex', alignItems: 'center', gap: '4px' }}>
                      {seg.isActive ? <><CircleDot size={10} /> Active</> : <><Circle size={10} /> Closed</>}
                    </span>
                  </div>
                </div>
              );
            })
          )}
        </div>
      )}

      {/* Episode RSPE Timeline */}
      {episodes.length > 0 && (
        <div className="glass-card" style={{ marginTop: '24px' }}>
          <div className="section-header">
            <div>
              <h2 className="section-title">MEV Heartbeat</h2>
              <div className="section-subtitle">RSPE values over recent episodes — pulsing with each resolution</div>
            </div>
          </div>

          <div style={{ display: 'flex', alignItems: 'stretch', gap: '4px', height: '140px', padding: '0 8px' }}>
            {episodes.slice().reverse().map((ep, i) => {
              const maxRSPE = Math.max(...episodes.map(e => Number(e.externalityFormatted) || 0.001), 0.001);
              const val = Number(ep.externalityFormatted) || 0;
              const height = Math.max((val / maxRSPE) * 100, 4);
              const color = ep.resolved
                ? (val > 0 ? 'var(--mev-red)' : 'var(--safe-green)')
                : 'var(--warning-amber)';

              return (
                <div
                  key={ep.episodeId}
                  style={{
                    flex: 1,
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'center',
                    justifyContent: 'flex-end',
                    gap: '4px',
                  }}
                >
                  <div style={{ fontSize: '9px', color: 'var(--text-muted)' }}>
                    {val > 0 ? val.toFixed(4) : ''}
                  </div>
                  {/* Wrapper to give percentage heights a rigid container */}
                  <div style={{ flex: 1, width: '100%', display: 'flex', alignItems: 'flex-end' }}>
                    <div
                      className={ep.resolved && val > 0 ? 'heartbeat' : ''}
                      style={{
                        width: '100%',
                        height: `${height}%`,
                        borderRadius: '4px 4px 0 0',
                        background: color,
                        boxShadow: val > 0 ? `0 0 8px ${color}60` : 'none',
                        transition: 'height 0.5s ease',
                      }}
                    />
                  </div>
                  <div className="mono" style={{ fontSize: '9px', color: 'var(--text-muted)' }}>
                    #{ep.episodeId}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
