// Line icons, 16px grid, currentColor.
import type { SVGProps } from 'react';

type IconProps = SVGProps<SVGSVGElement>;

const base: IconProps = { width: 16, height: 16, viewBox: '0 0 16 16', fill: 'none', stroke: 'currentColor', strokeWidth: 1.3, strokeLinecap: 'round', strokeLinejoin: 'round' };

export const Logo = (p: IconProps) => (
  <svg viewBox="0 0 24 24" fill="none" {...p}>
    <rect x="2.5" y="5.5" width="13" height="13" rx="2.5" stroke="currentColor" strokeWidth="1.6" />
    <rect x="8.5" y="2.5" width="13" height="13" rx="2.5" fill="currentColor" />
  </svg>
);

export const AppIcon = ({ id, ...p }: IconProps & { id: string }) => {
  switch (id) {
    case 'welcome': return <svg {...base} {...p}><rect x="2" y="5" width="8.5" height="8.5" rx="1.8" /><path d="M6 5V4.3A1.8 1.8 0 0 1 7.8 2.5h4.4A1.8 1.8 0 0 1 14 4.3v4.4a1.8 1.8 0 0 1-1.8 1.8h-1.7" /></svg>;
    case 'code': return <svg {...base} {...p}><path d="M5.5 4.5L2 8l3.5 3.5M10.5 4.5L14 8l-3.5 3.5M9 3l-2 10" /></svg>;
    case 'pulse': return <svg {...base} {...p}><path d="M1.5 8.5h3l1.5-4 2.5 8 2-5.5 1 1.5h3" /></svg>;
    case 'sketch': return <svg {...base} {...p}><path d="M10.5 2.5l3 3-7.5 7.5H3v-3z" /><path d="M9 4l3 3" /></svg>;
    case 'clock': return <svg {...base} {...p}><circle cx="8" cy="8" r="6" /><path d="M8 4.5V8l2.5 1.5" /></svg>;
    case 'lab': return <svg {...base} {...p}><path d="M6 2.5h4M6.8 2.5v4L3 12.6a.9.9 0 0 0 .8 1.4h8.4a.9.9 0 0 0 .8-1.4L9.2 6.5v-4M4.6 10h6.8" /></svg>;
    default: return <svg {...base} {...p}><rect x="2.5" y="2.5" width="11" height="11" rx="2" /></svg>;
  }
};

export const Github = (p: IconProps) => (
  <svg viewBox="0 0 16 16" fill="currentColor" {...p}>
    <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z" />
  </svg>
);

export const Sun = (p: IconProps) => <svg {...base} {...p}><circle cx="8" cy="8" r="3" /><path d="M8 1v1.5M8 13.5V15M1 8h1.5M13.5 8H15M3 3l1 1M12 12l1 1M3 13l1-1M12 4l1-1" /></svg>;
export const Moon = (p: IconProps) => <svg {...base} {...p}><path d="M13.5 9.5A5.5 5.5 0 016.5 2.5a5.5 5.5 0 107 7z" /></svg>;
export const Arrow = (p: IconProps) => <svg {...base} {...p}><path d="M3 8h10M9 4l4 4-4 4" /></svg>;
export const Close = (p: IconProps) => <svg {...base} {...p}><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" /></svg>;
export const Plus = (p: IconProps) => <svg {...base} {...p}><path d="M8 3v10M3 8h10" /></svg>;
export const LinkIcon = (p: IconProps) => <svg {...base} {...p}><path d="M7 9a2.5 2.5 0 003.5 0l2-2A2.5 2.5 0 009 3.5L8 4.5M9 7a2.5 2.5 0 00-3.5 0l-2 2A2.5 2.5 0 007 12.5l1-1" /></svg>;
export const Gauge = (p: IconProps) => <svg {...base} {...p}><path d="M2.5 12a6 6 0 1111 0" /><path d="M8 10l2.5-3.5" /></svg>;
export const Pulse = (p: IconProps) => <svg {...base} {...p}><path d="M1.5 8.5h3l1.5-4 2.5 8 2-5.5 1 1.5h3" /></svg>;
export const Memory = (p: IconProps) => <svg {...base} {...p}><rect x="2" y="4.5" width="12" height="7" rx="1" /><path d="M5 4.5V3M8 4.5V3M11 4.5V3M5 13v-1.5M8 13v-1.5M11 13v-1.5" /></svg>;
export const Scale =(p: IconProps) => <svg {...base} {...p}><path d="M9.5 2.5h4v4M13.5 2.5L9 7M6.5 13.5h-4v-4M2.5 13.5L7 9" /></svg>;
export const Warn =(p: IconProps) => <svg {...base} {...p}><path d="M8 2L1.5 13.5h13z" /><path d="M8 6.5v3M8 11.5v.01" /></svg>;
export const Panel =(p: IconProps) => <svg {...base} {...p}><rect x="2" y="2.5" width="12" height="11" rx="2" /><path d="M10 2.5v11" /></svg>;
