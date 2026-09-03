import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'
import '@rainbow-me/rainbowkit/styles.css';

import { getDefaultConfig, RainbowKitProvider, darkTheme } from '@rainbow-me/rainbowkit';
import { WagmiProvider } from 'wagmi';
import { sepolia } from 'wagmi/chains';
import { QueryClientProvider, QueryClient } from '@tanstack/react-query';

const config = getDefaultConfig({
  appName: 'Exposure Ledger',
  projectId: 'demo_project_id',
  chains: [sepolia],
  ssr: false,
});

const queryClient = new QueryClient();

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={darkTheme({
          accentColor: 'var(--info-blue)',
          accentColorForeground: 'white',
          borderRadius: 'large',
          fontStack: 'system',
        })}>
          <App />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
)
