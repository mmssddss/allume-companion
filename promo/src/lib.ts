import {interpolate, spring} from 'remotion';
import timeline from './timeline.json';

export const FPS = timeline.fps;
export const BEAT = (60 / timeline.bpm) * FPS; // 30 frames
export const BAR = BEAT * timeline.beatsPerBar; // 120 frames
export const W = 1920;
export const H = 1080;

/** Frame where bar `bars` starts (fractions allowed: 4.5 is the third beat of bar 4). */
export const bar = (bars: number) => Math.round(bars * BAR);

/** Springs: `snappy` lands in ~0.35 s without overshoot to speak of, `bouncy` overshoots a little. */
export const SNAPPY = {damping: 26, stiffness: 260, mass: 0.7};
export const BOUNCY = {damping: 14, stiffness: 180, mass: 0.8};
export const SOFT = {damping: 30, stiffness: 120, mass: 1};

/** 0 → 1 spring that starts at frame `start`. */
export const sp = (frame: number, start: number, config = SNAPPY) =>
  spring({frame: frame - start, fps: FPS, config});

/** Linear 0 → 1 between two frames, clamped. */
export const lin = (frame: number, a: number, b: number) =>
  interpolate(frame, [a, b], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

export const mix = (a: number, b: number, t: number) => a + (b - a) * t;

export type Rect = {x: number; y: number; w: number; h: number; r: number};

export const mixRect = (a: Rect, b: Rect, t: number): Rect => ({
  x: mix(a.x, b.x, t),
  y: mix(a.y, b.y, t),
  w: mix(a.w, b.w, t),
  h: mix(a.h, b.h, t),
  r: mix(a.r, b.r, t),
});

export const rectStyle = (r: Rect): React.CSSProperties => ({
  position: 'absolute',
  left: r.x,
  top: r.y,
  width: r.w,
  height: r.h,
  borderRadius: r.r,
});

/** A rect of size w×h centred on (cx, cy). */
export const centred = (cx: number, cy: number, w: number, h: number, r: number): Rect => ({
  x: cx - w / 2,
  y: cy - h / 2,
  w,
  h,
  r,
});

export const COLORS = {
  purple: '#3D1AA6',
  purpleDeep: '#1E0D57',
  violet: '#6329F5',
  lavender: '#C9BCFF',
  canvas: '#E4E2DF', // Allume's canvas grey
  ink: '#1D1B22',
  inkSoft: '#5D5866',
  white: '#FFFFFF',
};

export const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif';
