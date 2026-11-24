// A client's input as its WAYLAND_DEBUG log shows it — libwayland's lines
// (`[hh:mm:ss.us] {Default Queue} wl_touch#8.down(5, 1, wl_surface#7, 0,
// 100.00000000, 100.00000000)`, weston-simple-touch) and wland-fixture's
// (`[ms.us]  wl_touch#12.down(…, 100.000000, …)`) alike; requests (` -> `)
// are not events. Used by the E2E tools for the `touch` role and for the
// pointer emulation a client without wl_touch gets.

export type TouchLogEvent =
  | { type: 'down'; serial: number; surface: number; id: number; x: number; y: number }
  | { type: 'motion'; id: number; x: number; y: number }
  | { type: 'up'; serial: number; id: number }
  | { type: 'frame' }
  | { type: 'cancel' };

const events = (log: string, iface: string) => {
  const re = new RegExp(`${iface}#\\d+\\.(\\w+)\\(([^)]*)\\)`);
  const out: { name: string; args: string[] }[] = [];
  for (const line of log.split('\n')) {
    if (line.includes(' -> ')) continue;
    const m = re.exec(line);
    if (m) out.push({ name: m[1]!, args: m[2] ? m[2].split(', ') : [] });
  }
  return out;
};
const obj = (s: string) => Number(/#(\d+)$/.exec(s)?.[1] ?? 0);

/** Every wl_touch event in the log, in order (shape/orientation left out:
 *  wland sends none). */
export function touchEvents(log: string): TouchLogEvent[] {
  const out: TouchLogEvent[] = [];
  for (const { name, args: a } of events(log, 'wl_touch')) {
    if (name === 'down') out.push({ type: 'down', serial: +a[0]!, surface: obj(a[2]!), id: +a[3]!, x: +a[4]!, y: +a[5]! });
    else if (name === 'motion') out.push({ type: 'motion', id: +a[1]!, x: +a[2]!, y: +a[3]! });
    else if (name === 'up') out.push({ type: 'up', serial: +a[0]!, id: +a[2]! });
    else if (name === 'frame' || name === 'cancel') out.push({ type: name });
  }
  return out;
}

/** The events one line each, coordinates rounded: `down 0 100,100`,
 *  `motion 0 110,100`, `up 0`, `frame`, `cancel` — what checks compare
 *  and print. */
export function touchLines(evs: TouchLogEvent[]): string[] {
  return evs.map((e) => {
    switch (e.type) {
      case 'down': return `down ${e.id} ${Math.round(e.x)},${Math.round(e.y)}`;
      case 'motion': return `motion ${e.id} ${Math.round(e.x)},${Math.round(e.y)}`;
      case 'up': return `up ${e.id}`;
      default: return e.type;
    }
  });
}

/** The wl_pointer events in the log (enter, leave, motion, button, axis…),
 *  with their args as logged; frame left out. */
export function pointerEvents(log: string): { name: string; args: string[] }[] {
  return events(log, 'wl_pointer').filter((e) => e.name !== 'frame');
}

/** The serials of the client's xdg_toplevel.move requests. */
export function moveRequests(log: string): number[] {
  return [...log.matchAll(/ -> xdg_toplevel#\d+\.move\(wl_seat#\d+, (\d+)\)/g)].map((m) => +m[1]!);
}
