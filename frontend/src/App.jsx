import { useState, useEffect } from 'react';
import './index.css';
import Dashboard from './pages/Dashboard';
import PositionExplorer from './pages/PositionExplorer';
import MevRayVision from './pages/MevRayVision';
import CrossChainMonitor from './pages/CrossChainMonitor';
import logoImg from './assets/logo.jpg';

import { LayoutDashboard, Search, Microscope, Link } from 'lucide-react';
import { useAccount } from 'wagmi';
import { ConnectButton } from '@rainbow-me/rainbowkit';

const PAGES = {
  dashboard: { label: 'Dashboard', icon: <LayoutDashboard size={16} /> },
  explorer: { label: 'Position Explorer', icon: <Search size={16} /> },
  rayvision: { label: 'MEV-Ray Vision', icon: <Microscope size={16} /> },
  crosschain: { label: 'Cross-Chain', icon: <Link size={16} /> },
};

export default function App() {
  const [currentPage, setCurrentPage] = useState('dashboard');
  const { isConnected } = useAccount();

  const renderPage = () => {
    switch (currentPage) {
      case 'dashboard': return <Dashboard onNavigate={setCurrentPage} />;
      case 'explorer': return <PositionExplorer />;
      case 'rayvision': return <MevRayVision />;
      case 'crosschain': return <CrossChainMonitor />;
      default: return <Dashboard onNavigate={setCurrentPage} />;
    }
  };

  if (!isConnected) {
    return (
      <div style={{ height: '100vh', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', background: 'var(--bg-dark)' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', width: '120px', height: '120px', borderRadius: '24px', overflow: 'hidden', boxShadow: '0 8px 32px rgba(0, 200, 255, 0.15)', marginBottom: '32px' }}>
          <img src={logoImg} alt="Exposure Ledger Logo" style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
        </div>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: '12px', marginBottom: '16px', textAlign: 'center' }}>
          <span style={{ fontSize: '48px', fontWeight: 900, letterSpacing: '0.15em', color: '#ffffff', textShadow: '0 0 30px rgba(255,255,255,0.2)' }}>
            EXPOSURE
          </span>
          <span style={{ fontSize: '48px', fontWeight: 300, letterSpacing: '-0.04em', color: 'var(--info-blue)', textShadow: '0 0 30px rgba(68,138,255,0.4)' }}>
            LEDGER
          </span>
        </div>
        <p style={{ fontSize: '18px', color: 'var(--text-secondary)', maxWidth: '500px', textAlign: 'center', marginBottom: '40px', lineHeight: 1.6 }}>
          Position-level MEV attribution for Uniswap v4. Connect your wallet to view real-time adverse selection data.
        </p>
        <ConnectButton />
      </div>
    );
  }

  return (
    <div className="app-container">
      {/* ─── Navbar ─── */}
      <nav className="navbar">
        <div className="navbar-brand">
          <div className="navbar-logo" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden', borderRadius: '6px', padding: 0, background: 'transparent' }}>
            <img src={logoImg} alt="Logo" style={{ width: '32px', height: '32px', objectFit: 'cover', borderRadius: '6px' }} />
          </div>
          <div>
            <div className="navbar-title" style={{ display: 'flex', alignItems: 'baseline', gap: '4px', background: 'none', WebkitTextFillColor: 'initial' }}>
              <span style={{ fontWeight: 900, letterSpacing: '0.1em', color: '#ffffff' }}>EXPOSURE</span>
              <span style={{ fontWeight: 300, letterSpacing: '-0.02em', color: 'var(--info-blue)' }}>LEDGER</span>
            </div>
            <div className="navbar-subtitle">MEV-Ray Vision Dashboard</div>
          </div>
        </div>

        <div className="navbar-nav">
          {Object.entries(PAGES).map(([key, { label, icon }]) => (
            <button
              key={key}
              className={`nav-btn ${currentPage === key ? 'active' : ''}`}
              onClick={() => setCurrentPage(key)}
            >
              {icon} {label}
            </button>
          ))}
        </div>

        <div style={{ display: 'flex', alignItems: 'center' }}>
          <ConnectButton chainStatus="icon" showBalance={false} />
        </div>
      </nav>

      {/* ─── Page Content ─── */}
      <main className="page-content">
        {renderPage()}
      </main>
    </div>
  );
}
