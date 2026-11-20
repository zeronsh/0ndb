import { createRoot } from 'react-dom/client';
import { watchFonts } from '@wingleeio/mugen';
import { App } from './App.jsx';
import './styles.css';

// Re-measure rows once Geist arrives (mugen measures text analytically).
watchFonts();

createRoot(document.getElementById('root')).render(<App />);
