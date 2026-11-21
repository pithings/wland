// The page is the demo: the compositor's output filling the screen, an
// optional inspector, and one bottom bar (brand, status, controls). The introduction lives in
// the Welcome app and the SDK snippets in the Code app, both Wayland clients.
import { useEffect, useState } from 'react';
import type { ComponentProps } from 'react';
import { Controls, Desktop, Inspector, StatusBar } from './components/Demo.tsx';
import { Logo, Github, Sun, Moon, Panel } from './components/icons.tsx';
import * as session from './session/session.ts';

const REPO = 'https://github.com/pithings/wland';

function useTheme(): [theme: string, toggle: () => void] {
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme || 'dark');
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem('wland-theme', theme); } catch { /* private mode */ }
    session.repaintAll();
  }, [theme]);
  return [theme, () => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))];
}

const IconButton = ({ label, active, ...p }: { label: string; active?: boolean } & ComponentProps<'button'>) => (
  <button
    aria-label={label}
    title={label}
    className={`grid size-7 place-items-center rounded-md transition-colors hover:bg-hover hover:text-fg ${active ? 'text-fg' : 'text-muted'}`}
    {...p}
  />
);

export default function App() {
  const [theme, toggleTheme] = useTheme();
  const [inspector, setInspector] = useState(() => window.innerWidth >= 1600);
  return (
    <div className="flex h-dvh flex-col overflow-hidden">
      <main className="relative flex min-h-0 flex-1">
        <Desktop />
        {inspector && <Inspector onClose={() => setInspector(false)} />}
      </main>
      <StatusBar
        start={
          <a href={REPO} className="flex items-center gap-1.5 text-fg">
            <Logo className="size-4" />
            <span className="text-[13px] font-semibold tracking-tight">wland</span>
          </a>
        }
      >
        <span className="hidden h-4 w-px bg-line md:block" />
        <div className="hidden md:block">
          <Controls />
        </div>
        <span className="h-4 w-px bg-line" />
        <div className="-mr-1.5 flex items-center">
          <IconButton label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`} onClick={toggleTheme}>
            {theme === 'dark' ? <Sun className="size-4" /> : <Moon className="size-4" />}
          </IconButton>
          <a href={REPO} aria-label="GitHub" title="GitHub" className="hidden size-7 place-items-center rounded-md text-muted transition-colors hover:bg-hover hover:text-fg sm:grid">
            <Github className="size-4" />
          </a>
          <IconButton label={inspector ? 'Hide the inspector' : 'Show the inspector'} active={inspector} onClick={() => setInspector((v) => !v)}>
            <Panel className="size-4" />
          </IconButton>
        </div>
      </StatusBar>
    </div>
  );
}
