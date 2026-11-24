import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import type { ReactNode, SVGProps } from 'react';
import * as session from '../session/session.ts';
import type { TraceRecord } from '../session/session.ts';
import { AppIcon, Close, Gauge, LinkIcon, Memory, Pulse, Scale, Warn } from './icons.tsx';

export const useSession = (): session.State => useSyncExternalStore(session.subscribe, session.getState);

interface SegmentedProps<V extends string> {
  label?: string;
  /** '' selects nothing. */
  value: V | '';
  options: [value: V, text: string][];
  onChange(v: V): void;
}

function Segmented<V extends string>({ label, value, options, onChange }: SegmentedProps<V>) {
  return (
    <div className="flex items-center gap-2">
      {label && <span className="hidden text-[12px] text-subtle lg:inline">{label}</span>}
      <div className="flex rounded-md border border-line p-0.5">
        {options.map(([v, text]) => (
          <button
            key={String(v)}
            onClick={() => onChange(v)}
            className={`rounded-[5px] px-2 py-0.5 text-[12px] transition-colors ${
              value === v ? 'bg-fg text-bg' : 'text-muted hover:text-fg'
            }`}
          >
            {text}
          </button>
        ))}
      </div>
    </div>
  );
}

const DOCK_CLASS = 'absolute bottom-3 left-1/2 z-10 flex -translate-x-1/2 items-end gap-1.5 rounded-2xl border border-line bg-bg/70 p-1.5 shadow-[0_8px_30px_var(--shadow)] backdrop-blur-xl';

/** The Host source's dock (dev only): one-click launchers for the known apps
 *  found on the host, and a command line for anything else. */
function HostDock() {
  const s = useSession();
  const [cmd, setCmd] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const run = async (c: string) => {
    if (!c.trim()) return;
    setBusy(true);
    setErr('');
    try { await session.runHost(c); setCmd(''); } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };
  const minimized = s.windows.filter((w) => w.minimized);
  return (
    <nav aria-label="Host apps" className={`${DOCK_CLASS} w-max max-w-[calc(100%-24px)] flex-col items-stretch`}>
      {err && <p className="px-1.5 pt-0.5 text-[12px] text-bad">{err}</p>}
      {minimized.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5" aria-label="Minimized windows">
          {minimized.map((w) => (
            <button
              key={w.key}
              onClick={() => session.restoreWindow(w.key)}
              title="Restore this minimized window"
              className="max-w-48 truncate rounded-lg border border-dashed border-line-strong px-2.5 py-1 text-[12px] text-muted transition-colors hover:bg-hover hover:text-fg"
            >
              {w.title}
            </button>
          ))}
        </div>
      )}
      <div className="flex flex-wrap items-center gap-1.5">
        {s.host?.apps.map((a) => (
          <button
            key={a}
            onClick={() => run(a)}
            disabled={!s.ready || busy}
            className="rounded-lg border border-line bg-panel px-2.5 py-1.5 font-mono text-[12px] text-fg transition-colors hover:bg-hover disabled:opacity-40"
          >
            {a}
          </button>
        ))}
        <form onSubmit={(e) => { e.preventDefault(); run(cmd); }} className="flex items-center gap-1">
          <input
            value={cmd}
            onChange={(e) => setCmd(e.target.value)}
            placeholder="command…"
            aria-label="Run a host command"
            title={s.host ? `Runs via tools/wland-run on ${s.host.socket}` : ''}
            className="w-40 rounded-lg border border-line bg-bg px-2 py-1.5 font-mono text-[12px] text-fg outline-none placeholder:text-subtle focus:border-line-strong"
          />
          <button type="submit" disabled={!s.ready || busy || !cmd.trim()} className="rounded-lg border border-line px-2.5 py-1.5 text-[12px] text-muted hover:text-fg disabled:opacity-40">
            Run
          </button>
        </form>
      </div>
    </nav>
  );
}

/** A macOS-style dock floating over the desktop: one tile per app, a dot
 *  under the running ones. Clicking focuses the app's window, or opens it. */
function Dock() {
  const s = useSession();
  // a fullscreen window covers the desktop: no dock over it
  if (s.windows.some((w) => w.fullscreen && !w.minimized)) return null;
  if (s.opts.source === 'host') return <HostDock />;
  return (
    <nav aria-label="Apps" className={DOCK_CLASS}>
      {session.APPS.map((app) => {
        const running = s.clients.some((c) => c.appId === app.id);
        // all its windows minimized: a hollow dot (a click restores one)
        const wins = s.windows.filter((w) => w.app === app.id);
        const hidden = wins.length > 0 && wins.every((w) => w.minimized);
        return (
          <button
            key={app.id}
            onClick={() => session.openApp(app.id)}
            disabled={!s.ready}
            aria-label={`Open ${app.name}`}
            className="group relative flex flex-col items-center disabled:opacity-40"
          >
            <span className="pointer-events-none absolute -top-9 rounded-md border border-line bg-bg px-2 py-0.5 text-[12px] whitespace-nowrap text-fg opacity-0 shadow-sm transition-opacity group-hover:opacity-100">
              {app.name}
            </span>
            <span className="grid size-11 origin-bottom place-items-center rounded-xl border border-line bg-panel text-fg transition-transform duration-150 ease-out group-hover:-translate-y-1 group-hover:scale-[1.18] group-active:scale-105">
              <AppIcon id={app.id} className="size-[22px]" />
            </span>
            <span className={`mt-1 size-1 rounded-full ${hidden ? 'ring-1 ring-fg/70' : running ? 'bg-fg/70' : 'bg-transparent'}`} />
          </button>
        );
      })}
    </nav>
  );
}

/** Session options: the renderer and the link restart it, Damage repaints. */
export function Controls() {
  const s = useSession();
  // the renderer in use, not the option: the session starts on 'auto' (GL
  // only on a hardware GPU) and this shows what that picked
  const renderer = !s.ready ? '' : s.presenter === 'WebGL' ? 'always' : 'never';
  return (
    <div className="flex items-center gap-3">
      {s.host && (
        <Segmented
          value={s.opts.source}
          options={[['page', 'In-page'], ['host', 'Host']]}
          onChange={(v) => session.setOption('source', v)}
        />
      )}
      <Segmented
        value={renderer}
        options={[['never', '2D'], ['always', 'WebGL']]}
        onChange={(v) => v !== renderer && session.setOption('webgl', v)}
      />
      <label className="flex cursor-pointer items-center gap-2 text-[12px] text-muted select-none" title="Outline what each frame repaints">
        <span
          role="switch"
          aria-checked={s.opts.damage}
          className={`relative h-[18px] w-8 rounded-full border transition-colors ${
            s.opts.damage ? 'border-transparent bg-[#ff3d8b]' : 'border-line-strong bg-hover'
          }`}
        >
          <span
            className={`absolute top-[2px] size-3 rounded-full bg-white shadow transition-[left] ${
              s.opts.damage ? 'left-[16px]' : 'left-[2px]'
            }`}
          />
        </span>
        <input
          type="checkbox"
          className="sr-only"
          checked={s.opts.damage}
          onChange={(e) => session.setOption('damage', e.target.checked)}
        />
        Damage
      </label>
    </div>
  );
}

/** The compositor's output: fills its parent. */
export function Desktop() {
  const desktop = useRef<HTMLDivElement>(null);
  const s = useSession();
  useEffect(() => { session.boot(desktop.current!); }, []);
  const empty = s.ready && s.windows.length === 0;
  return (
    <div className="relative min-w-0 flex-1">
      {/* the lib owns every child of #desktop; React never renders into it */}
      <div id="desktop" ref={desktop} />
      <Dock />
      {empty && (
        <div className="pointer-events-none absolute inset-0 grid place-items-center">
          <div className="text-center">
            <p className="text-[14px] text-fg">No windows</p>
            <p className="mt-1 text-[13px] text-muted">
              {s.opts.source === 'host' ? 'Run a host app from the bar below.' : 'Open an app from the dock.'}
            </p>
          </div>
        </div>
      )}
      {!s.ready && !s.error && (
        <div className="pointer-events-none absolute inset-0 grid place-items-center text-[13px] text-muted">
          Starting compositor…
        </div>
      )}
      {s.error && (
        <div className="absolute inset-0 grid place-items-center p-6 text-center text-[13px] text-bad">
          Could not start the compositor: {s.error}
        </div>
      )}
    </div>
  );
}

function FootItem({ icon: Icon, className = '', title, children }: { icon: (p: SVGProps<SVGSVGElement>) => ReactNode; className?: string; title?: string; children: ReactNode }) {
  return (
    <span title={title} className={`flex items-center gap-1 font-mono text-[11px] ${className}`}>
      <Icon className="size-3 opacity-70" aria-hidden />
      {children}
    </span>
  );
}

/** 1536 → "1.5K", compact for the bar. */
function bytes(n: number): string {
  if (n < 1024) return `${n}B`;
  const [v, u] = n < 1048576 ? [n / 1024, 'K'] : n < 1073741824 ? [n / 1048576, 'M'] : [n / 1073741824, 'G'];
  return `${v < 10 ? v.toFixed(1) : Math.round(v)}${u}`;
}

/** The page's one bar: `start` (the brand), session status and metrics,
 *  then `children` (controls, page buttons) at the end. */
export function StatusBar({ start, children }: { start?: ReactNode; children?: ReactNode }) {
  const s = useSession();
  const st = s.stats;
  return (
    <footer className="flex h-10 shrink-0 items-center gap-x-4 overflow-hidden border-t border-line px-3 whitespace-nowrap text-muted">
      {start}
      <span className="flex items-center gap-1.5 font-mono text-[11px]">
        <span className={`size-1.5 rounded-full ${s.ready ? 'bg-ok' : 'bg-subtle'}`} />
        {s.ready ? 'running' : 'starting'}
      </span>
      {s.windows.some((w) => w.fullscreen && !w.minimized) && (
        <span className="font-mono text-[11px] text-fg" title="A window is fullscreen (the app asked, or Alt+F11)">
          fullscreen · Alt+F11 to leave
        </span>
      )}
      {s.pointerLocked && (
        <span className="font-mono text-[11px] text-fg" title="An app locked the pointer (pointer constraints); Esc gives it back">
          pointer locked · Esc to release
        </span>
      )}
      <FootItem icon={LinkIcon} className="max-lg:hidden" title="Where the clients run, and how the relay talks to the compositor">{s.kind}</FootItem>
      <span className="ml-auto" />
      {s.metrics.scale > 0 && (
        <FootItem icon={Scale} className="max-sm:hidden" title={`Buffer scale: clients render at ${s.metrics.scale}× (device pixel ratio ${+devicePixelRatio.toFixed(2)})`}>
          {s.metrics.scale}×
        </FootItem>
      )}
      {s.ready && (
        <FootItem
          icon={Memory}
          className="max-md:hidden"
          title={[
            'Shared memory',
            `${s.metrics.readKibPerSec} KiB/s read by handle: pixels the compositor read straight from client buffers`,
            `${s.metrics.kibPerSec} KiB/s damage: pixels clients marked as changed`,
            `total read: ${bytes(st.bytesRead ?? 0)} in ${st.reads ?? 0} reads`,
            `handles: ${st.handles ?? 0} relay · ${st.tokens ?? 0} engine · ${st.exports ?? 0} exports`,
          ].join('\n')}
        >
          read {bytes(s.metrics.readKibPerSec * 1024)}/s · dmg {bytes(s.metrics.kibPerSec * 1024)}/s
        </FootItem>
      )}
      <FootItem icon={Gauge} title="Page frame rate (requestAnimationFrame ticks per second)">{s.metrics.fps} fps</FootItem>
      <FootItem icon={Pulse} className="max-sm:hidden" title="Surface commits presented per second, across all clients">
        {s.metrics.commitsPerSec} commits/s
      </FootItem>
      {s.violations.length > 0 && (
        <FootItem icon={Warn} className="text-bad" title={`Protocol violations caught by the relay or shared memory (details in the inspector):\n${s.violations.slice(-5).join('\n')}`}>
          {s.violations.length} violations
        </FootItem>
      )}
      {children}
    </footer>
  );
}

// --- inspector -----------------------------------------------------------------

function Row({ k, v, hint }: { k: string; v: ReactNode; hint?: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-[5px]">
      <span className="text-[12.5px] text-muted">{k}</span>
      <span className="text-right font-mono text-[12px] text-fg tabular-nums">
        {v}
        {hint && <span className="text-subtle"> {hint}</span>}
      </span>
    </div>
  );
}

function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="border-b border-line px-4 py-3 last:border-b-0">
      <h4 className="mb-1 font-mono text-[10.5px] tracking-wider text-subtle uppercase">{title}</h4>
      {children}
    </div>
  );
}

function Stats() {
  const s = useSession();
  const st = s.stats;
  const mib = ((st.bytesRead || 0) / 1048576).toFixed(1);
  return (
    <div className="overflow-y-auto">
      <Group title="Clients">
        {s.clients.length === 0 && <p className="py-1 text-[12.5px] text-subtle">none</p>}
        {s.clients.map((c) => {
          const w = s.windows.find((x) => x.conn === c.conn);
          return (
            <div key={c.conn} className="group flex items-center gap-2 py-[3px]">
              <button
                onClick={() => session.focusApp(c.conn)}
                className="flex min-w-0 flex-1 items-center gap-2 text-left text-[12.5px] text-fg"
              >
                <AppIcon id={c.appId} className="size-3.5 shrink-0 text-muted" />
                <span className="truncate">{c.title}</span>
                <span className="font-mono text-[11px] text-subtle">conn {c.conn}</span>
                {w?.focused && <span className="rounded bg-hover px-1 font-mono text-[10px] text-muted">focus</span>}
                {w?.minimized && <span className="rounded bg-hover px-1 font-mono text-[10px] text-muted">min</span>}
              </button>
              {s.opts.source === 'page' && <button
                onClick={() => session.closeApp(c.conn)}
                className="rounded p-0.5 text-subtle opacity-0 transition-opacity group-hover:opacity-100 hover:text-fg"
                aria-label={`Close ${c.title}`}
              >
                <Close className="size-3.5" />
              </button>}
            </div>
          );
        })}
      </Group>
      <Group title="Link · relay ⇄ compositor">
        {s.opts.source === 'host' ? (
          <p className="pb-2 text-[11.5px] leading-snug text-subtle">
            Real apps on {s.host?.socket ?? 'the host'}, relayed by wlandr over a WebSocket; pixels are copied into the stream. The
            counters below are the in-page relay's.
          </p>
        ) : <>
        <div className="flex items-center justify-between gap-3 py-[5px]">
          <span className="text-[12.5px] text-muted">transport</span>
          <Segmented
            value={s.opts.link}
            options={[['stream', 'Byte stream'], ['memory', 'Direct']]}
            onChange={(v) => session.setOption('link', v)}
          />
        </div>
        <p className="pb-2 text-[11.5px] leading-snug text-subtle">
          {s.opts.link === 'stream'
            ? 'STREAM v2 frames as raw bytes, cut at random points and reassembled by the compositor, as over a socket or vsock. The production path.'
            : 'Whole messages handed over in memory: no framing, no reassembly. Same protocol, less work.'}{' '}
          Switching relaunches the apps.
        </p>
        </>}
        <Row k="COMMIT sent" v={st.commits ?? 0} />
        <Row k="ACK received" v={st.acks ?? 0} />
        <Row k="wl_buffer.release" v={st.releases ?? 0} />
        <Row k="presented" v={st.presented ?? 0} hint={`${s.metrics.commitsPerSec}/s`} />
      </Group>
      <Group title="Shared memory">
        <Row k="handles" v={`${st.handles ?? 0} · ${st.tokens ?? 0} · ${st.exports ?? 0}`} hint="relay · engine · exports" />
        <Row k="read by handle" v={`${mib} MiB`} hint={`${st.reads ?? 0} reads`} />
        <Row k="damage" v={`${s.metrics.kibPerSec} KiB/s`} />
      </Group>
      <Group title="Output">
        <Row k="presenter" v={s.presenter || '—'} />
        <Row k="buffer scale" v={`${s.metrics.scale}×`} />
        <Row k="frame clock" v={`${s.metrics.fps} Hz`} />
      </Group>
      {s.violations.length > 0 && (
        <Group title="Violations">
          {s.violations.map((v, i) => <p key={i} className="py-0.5 font-mono text-[11px] text-bad">{v}</p>)}
        </Group>
      )}
    </div>
  );
}

// the per-frame cycle (frame → attach → damage → commit → done → release)
// and pointer/touch motion; what's left is configure, focus, keys, buttons,
// touch down/up, popups
const NOISY = /wl_pointer@\d+\.(motion|frame)|wl_touch@\d+\.(motion|frame)|wl_callback@\d+\.done|wl_surface@\d+\.(frame|attach|damage_buffer|commit)|wl_buffer@\d+\.release|wl_display@1\.delete_id/;

function Wire() {
  const host = useSession().opts.source === 'host';
  const list = useRef<HTMLDivElement>(null);
  const [quiet, setQuiet] = useState(true);
  const [paused, setPaused] = useState(false);
  const opts = useRef({ quiet, paused });
  opts.current = { quiet, paused };

  useEffect(() => {
    const el = list.current!;
    const rows: HTMLDivElement[] = [];
    const add = (e: TraceRecord, animate: boolean) => {
      if (opts.current.quiet && NOISY.test(e.msg)) return;
      const row = document.createElement('div');
      row.className = `${animate ? 'trace-row ' : ''}flex gap-2 px-4 py-[2px] font-mono text-[11px] leading-[17px]`;
      const dir = document.createElement('span');
      dir.className = e.dir === 'req' ? 'text-subtle' : 'text-accent';
      dir.textContent = e.dir === 'req' ? '→' : '←';
      const conn = document.createElement('span');
      conn.className = 'w-5 shrink-0 text-subtle';
      conn.textContent = `c${e.conn}`;
      const body = document.createElement('span');
      body.className = 'min-w-0 break-all text-fg';
      body.textContent = e.msg;
      const args = document.createElement('span');
      args.className = 'text-muted';
      args.textContent = `(${e.args || ''})`;
      body.append(args);
      row.append(dir, conn, body);
      const stick = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
      el.append(row);
      rows.push(row);
      if (rows.length > 400) rows.shift()!.remove();
      if (stick) el.scrollTop = el.scrollHeight;
    };
    el.textContent = '';
    for (const e of session.getTrace().slice(-200)) add(e, false);
    el.scrollTop = el.scrollHeight;
    // batch per animation frame: a pointer sweep is hundreds of messages
    let queue: TraceRecord[] = [];
    let raf = 0;
    const off = session.subscribeTrace((e) => {
      if (opts.current.paused) return;
      queue.push(e);
      if (!raf) raf = requestAnimationFrame(() => { raf = 0; const q = queue; queue = []; for (const x of q.slice(-80)) add(x, true); });
    });
    return () => { off(); cancelAnimationFrame(raf); };
  }, [quiet]);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex items-center gap-3 border-b border-line px-4 py-2 text-[12px] text-muted">
        <label className="flex cursor-pointer items-center gap-1.5 select-none">
          <input type="checkbox" checked={quiet} onChange={(e) => setQuiet(e.target.checked)} className="accent-current" />
          Hide frame cycle
        </label>
        <button onClick={() => setPaused((p) => !p)} className="ml-auto rounded border border-line px-1.5 py-0.5 hover:text-fg">
          {paused ? 'Resume' : 'Pause'}
        </button>
      </div>
      {host && (
        <p className="border-b border-line px-4 py-2 text-[11.5px] text-subtle">Host apps aren't traced: the wire trace comes from the in-page toolkit.</p>
      )}
      <div ref={list} className="min-h-0 flex-1 overflow-y-auto py-2" />
      <div className="border-t border-line px-4 py-2 font-mono text-[10.5px] text-subtle">
        <span className="text-subtle">→</span> request (client → compositor) · <span className="text-accent">←</span> event
      </div>
    </div>
  );
}

export function Inspector({ onClose }: { onClose(): void }) {
  const [tab, setTab] = useState('wire');
  return (
    <aside className="absolute inset-y-0 right-0 z-10 flex w-[min(340px,100%)] flex-col border-l border-line bg-bg md:static md:w-[340px] md:shrink-0">
      <div className="flex items-center gap-4 border-b border-line px-4">
        {[['wire', 'Wire'], ['stats', 'Stats']].map(([id, label]) => (
          <button
            key={id}
            onClick={() => setTab(id)}
            className={`-mb-px border-b py-2.5 text-[13px] transition-colors ${
              tab === id ? 'border-fg text-fg' : 'border-transparent text-muted hover:text-fg'
            }`}
          >
            {label}
          </button>
        ))}
        <button onClick={onClose} className="ml-auto rounded p-1 text-subtle hover:text-fg" aria-label="Close the inspector">
          <Close className="size-3.5" />
        </button>
      </div>
      <div className="border-b border-line px-4 py-2.5 md:hidden">
        <Controls />
      </div>
      {tab === 'wire' ? <Wire /> : <Stats />}
    </aside>
  );
}
