// The demo's imaginary apps. Each one is a Wayland client built on
// ../wayland/toolkit.js; the page launches them through the session.
import type { AppModule } from '../wayland/app-types.ts';
import welcome from './welcome.ts';
import code from './code.ts';
import pulse from './pulse.ts';
import sketch from './sketch.ts';
import clock from './clock.ts';
import lab from './lab.ts';

export const APPS: AppModule[] = [welcome, code, pulse, sketch, clock, lab];
export const appById = (id: string): AppModule | undefined => APPS.find((a) => a.id === id);
