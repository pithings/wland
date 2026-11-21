// weston-presentation-shm (weston-demo), the canonical wp_presentation test
// client, read off its stdout: one line per presented frame (c2p = commit
// to presentation, the commit's time being the client's own
// clock_gettime(clock_id) — so a sane c2p says the stamped time is on the
// client's clock), `discarded N` per discarded one, and at exit (SIGINT) a
// `clean up feedback N` for each feedback object it still holds: those
// still outstanding, and the last presented one (kept for the next p2p).
// Used by the E2E tools on both link types.

export interface PresentationRun {
  /** per presented frame: commit → presentation (ms; printed unsigned, so
   *  a presentation dated before its commit shows as a huge number) and
   *  the time since the previous presentation (µs) */
  presented: { frame: number; c2p: number; p2p: number }[];
  discarded: number;
  /** feedbacks outstanding when the client exited */
  outstanding: number;
  /** the highest frame number seen (feedbacks are requested one per frame) */
  frames: number;
}

export function parsePresentationShm(out: string): PresentationRun {
  const run: PresentationRun = { presented: [], discarded: 0, outstanding: 0, frames: 0 };
  const cleanedUp: number[] = [];
  for (const line of out.split('\n')) {
    let m = /^\s*(\d+): (?:f2c\s+\d+ ms, )?c2p\s+(\d+) ms, (?:f2p\s+\d+ ms, )?p2p\s+(-?\d+) us/.exec(line);
    if (m) {
      const frame = Number(m[1]);
      run.presented.push({ frame, c2p: Number(m[2]), p2p: Number(m[3]) });
      run.frames = Math.max(run.frames, frame);
    } else if ((m = /^discarded (\d+)/.exec(line))) {
      run.discarded++;
      run.frames = Math.max(run.frames, Number(m[1]));
    } else if ((m = /^clean up feedback (\d+)/.exec(line))) {
      cleanedUp.push(Number(m[1]));
      run.frames = Math.max(run.frames, Number(m[1]));
    }
  }
  const shown = new Set(run.presented.map((p) => p.frame));
  run.outstanding = cleanedUp.filter((f) => !shown.has(f)).length;
  return run;
}

/** What the E2Es assert, as [ok, description] pairs: frames presented,
 *  every presentation within 0…500 ms after its commit on the client's
 *  clock, a frame cadence, every feedback answered but the last few. */
export function presentationChecks(r: PresentationRun, minFrames: number): [boolean, string][] {
  const c2p = r.presented.map((p) => p.c2p);
  const p2p = r.presented.slice(1).map((p) => p.p2p).sort((a, b) => a - b);
  const median = p2p.length ? p2p[p2p.length >> 1]! : 0;
  return [
    [r.presented.length >= minFrames, `${r.presented.length} frames presented (≥ ${minFrames})`],
    [c2p.every((v) => v < 500), `commit → presented ${Math.min(...c2p)}…${Math.max(...c2p)} ms on the client's own CLOCK_MONOTONIC`],
    [median > 5000 && median < 100000, `presentations ${(median / 1000).toFixed(1)} ms apart (median)`],
    [r.outstanding <= 2 && r.presented.length + r.discarded + r.outstanding === r.frames,
      `every feedback answered: ${r.presented.length} presented + ${r.discarded} discarded + ${r.outstanding} outstanding at exit = ${r.frames} frames`],
  ];
}
