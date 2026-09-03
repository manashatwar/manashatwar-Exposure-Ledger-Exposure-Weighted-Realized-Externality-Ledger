import { useState, useEffect } from 'react';
import { Link, RotateCw, Inbox, CircleDot, Circle, CheckCircle, ArrowDownRight, ArrowUpRight, FileText, Eye, Calculator, CheckCircle2 } from 'lucide-react';
import {
  getEpisodes,
  getEpisodeExposedLPs,
  shortenAddress,
  formatTimestamp,
} from '../hooks';
import { HOOK_ADDRESS, RSC_ADDRESS, RELAYER_ADDRESS } from '../contracts';

export default function CrossChainMonitor() {
  const [episodes, setEpisodes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedEpisode, setSelectedEpisode] = useState(null);
  const [exposedLPs, setExposedLPs] = useState([]);

  useEffect(() => {
    loadData();
  }, []);

  async function loadData() {
    setLoading(true);
    try {
      const eps = await getEpisodes(20);
      setEpisodes(eps);
    } catch (err) {
      console.error('CrossChain load error:', err);
    }
    setLoading(false);
  }

  async function selectEpisode(ep) {
    setSelectedEpisode(ep);
    try {
      const lps = await getEpisodeExposedLPs(ep.episodeId);
      setExposedLPs(lps);
    } catch {
      setExposedLPs([]);
    }
  }

  const resolvedEps = episodes.filter(e => e.resolved);
  const pendingEps = episodes.filter(e => !e.resolved);

  if (loading) {
    return (
      <div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '8px' }}>
          <Link size={28} />
          <h1 style={{ fontSize: '28px', fontWeight: 800, margin: 0 }}>Cross-Chain Monitor</h1>
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
          <Link size={28} />
          <h1 style={{ fontSize: '28px', fontWeight: 800, margin: 0 }}>Cross-Chain Monitor</h1>
        </div>
        <p style={{ color: 'var(--text-secondary)' }}>
          Track the Sepolia ↔ Lasna reactive pipeline in real-time. Watch episodes flow from creation to resolution.
        </p>
      </div>

      {/* Network Status */}
      <div className="stats-grid">
        <div className="glass-card stat-card">
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px', marginBottom: '8px' }}>
            <div style={{ width: '10px', height: '10px', borderRadius: '50%', background: 'var(--safe-green)', boxShadow: '0 0 8px var(--safe-green)' }} />
            <span style={{ fontSize: '12px', color: 'var(--safe-green)', fontWeight: 600 }}>SEPOLIA</span>
          </div>
          <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
            Hook: <span className="mono" style={{ color: 'var(--text-secondary)' }}>{shortenAddress(HOOK_ADDRESS)}</span>
          </div>
        </div>

        <div className="glass-card stat-card">
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px', marginBottom: '8px' }}>
            <div style={{ width: '10px', height: '10px', borderRadius: '50%', background: 'var(--info-blue)', boxShadow: '0 0 8px var(--info-blue)' }} />
            <span style={{ fontSize: '12px', color: 'var(--info-blue)', fontWeight: 600 }}>REACTIVE LASNA</span>
          </div>
          <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
            RSC: <span className="mono" style={{ color: 'var(--text-secondary)' }}>{shortenAddress(RSC_ADDRESS)}</span>
          </div>
        </div>

        <div className="glass-card stat-card glow-green">
          <div className="stat-label">Resolved</div>
          <div className="stat-value" style={{ fontSize: '24px', color: 'var(--safe-green)' }}>{resolvedEps.length}</div>
        </div>

        <div className="glass-card stat-card">
          <div className="stat-label">Pending</div>
          <div className="stat-value" style={{ fontSize: '24px', color: 'var(--warning-amber)' }}>{pendingEps.length}</div>
        </div>
      </div>

      {/* Contract Addresses */}
      <div className="glass-card" style={{ marginBottom: '24px' }}>
        <h3 style={{ fontSize: '14px', fontWeight: 600, marginBottom: '16px' }}>Deployed Contracts</h3>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '16px' }}>
          {[
            { label: 'Hook (Sepolia)', addr: HOOK_ADDRESS, color: 'var(--safe-green)', explorer: 'https://sepolia.etherscan.io/address/' },
            { label: 'Relayer (Sepolia)', addr: RELAYER_ADDRESS, color: 'var(--warning-amber)', explorer: 'https://sepolia.etherscan.io/address/' },
            { label: 'RSC (Lasna)', addr: RSC_ADDRESS, color: 'var(--info-blue)', explorer: 'https://lasna-explorer.rnk.dev/address/' },
          ].map(c => (
            <div key={c.label} style={{ padding: '12px', background: 'rgba(15,15,35,0.5)', borderRadius: '8px' }}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>{c.label}</div>
              <a
                href={`${c.explorer}${c.addr}`}
                target="_blank"
                rel="noopener noreferrer"
                className="mono"
                style={{ fontSize: '11px', color: c.color, textDecoration: 'none', wordBreak: 'break-all' }}
              >
                {c.addr}
              </a>
            </div>
          ))}
        </div>
      </div>

      {/* Cross-Chain Timeline for Selected Episode */}
      {selectedEpisode && (
        <div className="glass-card" style={{ marginBottom: '24px' }}>
          <h3 style={{ fontSize: '16px', fontWeight: 600, marginBottom: '16px' }}>
            Episode #{selectedEpisode.episodeId} — Cross-Chain Flow
          </h3>

          <div className="timeline">
            <div className="timeline-step">
              <div className="timeline-dot completed"><FileText size={16} /></div>
              <div className="timeline-label">Created</div>
              <div className="timeline-sublabel">Sepolia</div>
            </div>
            <div className={`timeline-connector ${selectedEpisode.resolved ? 'active' : ''}`} />
            <div className="timeline-step">
              <div className={`timeline-dot ${selectedEpisode.resolved ? 'completed' : 'pending'}`}><Eye size={16} /></div>
              <div className="timeline-label">Detected</div>
              <div className="timeline-sublabel">Lasna RSC</div>
            </div>
            <div className={`timeline-connector ${selectedEpisode.resolved ? 'active' : ''}`} />
            <div className="timeline-step">
              <div className={`timeline-dot ${selectedEpisode.resolved ? 'completed' : 'pending'}`}><Calculator size={16} /></div>
              <div className="timeline-label">RSPE Calculated</div>
              <div className="timeline-sublabel">min(D, A)</div>
            </div>
            <div className={`timeline-connector ${selectedEpisode.resolved ? 'active' : ''}`} />
            <div className="timeline-step">
              <div className={`timeline-dot ${selectedEpisode.resolved ? 'completed' : 'inactive'}`}><CheckCircle2 size={16} /></div>
              <div className="timeline-label">Attributed</div>
              <div className="timeline-sublabel">Sepolia</div>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '12px', marginTop: '16px' }}>
            <div style={{ padding: '12px', background: 'rgba(15,15,35,0.5)', borderRadius: '8px' }}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>RSPE</div>
              <div className="mono" style={{ color: 'var(--mev-red)', fontWeight: 600 }}>
                {selectedEpisode.externalityFormatted} ETH
              </div>
            </div>
            <div style={{ padding: '12px', background: 'rgba(15,15,35,0.5)', borderRadius: '8px' }}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>Exposed LPs</div>
              <div className="mono" style={{ color: 'var(--info-blue)', fontWeight: 600 }}>{exposedLPs.length}</div>
            </div>
            <div style={{ padding: '12px', background: 'rgba(15,15,35,0.5)', borderRadius: '8px' }}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>Block</div>
              <div className="mono" style={{ fontWeight: 600 }}>{selectedEpisode.blockNumber}</div>
            </div>
          </div>

          {exposedLPs.length > 0 && (
            <div style={{ marginTop: '16px' }}>
              <div style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>Exposed LPs:</div>
              <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
                {exposedLPs.map(lp => (
                  <span key={lp} className="badge badge-active mono">{shortenAddress(lp)}</span>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {/* Episode List */}
      <div className="glass-card">
        <div className="section-header">
          <div>
            <h2 className="section-title">Episode Pipeline</h2>
            <div className="section-subtitle">Click an episode to see its cross-chain flow</div>
          </div>
          <button className="btn-secondary" style={{ display: 'flex', alignItems: 'center', gap: '6px' }} onClick={loadData}>
            <RotateCw size={14} /> Refresh
          </button>
        </div>

        {episodes.length === 0 ? (
          <div className="empty-state">
            <div className="empty-state-icon" style={{ display: 'flex', justifyContent: 'center', marginBottom: '16px' }}><Inbox size={48} color="var(--text-muted)" /></div>
            <div className="empty-state-title">No episodes</div>
          </div>
        ) : (
          <table className="episode-table">
            <thead>
              <tr>
                <th>ID</th>
                <th>Block</th>
                <th>Direction</th>
                <th>RSPE</th>
                <th>Pipeline</th>
                <th>Time</th>
              </tr>
            </thead>
            <tbody>
              {episodes.map((ep) => (
                <tr
                  key={ep.episodeId}
                  onClick={() => selectEpisode(ep)}
                  style={{
                    cursor: 'pointer',
                    background: selectedEpisode?.episodeId === ep.episodeId ? 'rgba(100,100,255,0.08)' : 'transparent',
                  }}
                >
                  <td style={{ color: 'var(--info-blue)' }}>#{ep.episodeId}</td>
                  <td>{ep.blockNumber}</td>
                  <td style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                    {ep.tradeDirection === 0 
                      ? <><ArrowDownRight size={14} color="var(--mev-red)" /> Sell</> 
                      : <><ArrowUpRight size={14} color="var(--safe-green)" /> Buy</>}
                  </td>
                  <td className="mono" style={{ color: ep.externality !== '0' ? 'var(--mev-red)' : 'var(--text-muted)' }}>
                    {ep.externalityFormatted}
                  </td>
                  <td>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                      <span style={{ color: 'var(--safe-green)', display: 'flex' }}><CircleDot size={14} /></span>
                      <span style={{ color: ep.resolved ? 'var(--safe-green)' : 'var(--text-muted)' }}>—</span>
                      <span style={{ color: ep.resolved ? 'var(--info-blue)' : 'var(--text-muted)', display: 'flex' }}>
                        {ep.resolved ? <CircleDot size={14} /> : <Circle size={14} />}
                      </span>
                      <span style={{ color: ep.resolved ? 'var(--safe-green)' : 'var(--text-muted)' }}>—</span>
                      <span style={{ color: ep.resolved ? 'var(--safe-green)' : 'var(--text-muted)', display: 'flex' }}>
                        {ep.resolved ? <CircleDot size={14} /> : <Circle size={14} />}
                      </span>
                      <span style={{ color: ep.resolved ? 'var(--safe-green)' : 'var(--text-muted)' }}>—</span>
                      <span style={{ color: ep.resolved ? 'var(--safe-green)' : 'var(--text-muted)', display: 'flex' }}>
                        {ep.resolved ? <CheckCircle size={14} /> : <Circle size={14} />}
                      </span>
                    </div>
                  </td>
                  <td style={{ fontSize: '11px' }}>{formatTimestamp(ep.createdTimestamp)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
