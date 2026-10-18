import React from 'react';
import {Img, OffthreadVideo, Sequence, staticFile} from 'remotion';
import clipsJson from './clips.json';
import {bar, COLORS, FONT, FPS, mix, Rect, rectStyle} from './lib';

// --- The app icon ------------------------------------------------------------------
// Geometry from Resources/AppIcon.icon (a 1024 canvas): three cards and the filament on the top one.

const ICON_CARDS = {
  back: {x: 276, y: 258, w: 560, h: 420},
  mid: {x: 232, y: 302, w: 560, h: 420},
  top: {x: 188, y: 346, w: 560, h: 420},
};
export type CardName = keyof typeof ICON_CARDS;

/** Screen rects of the icon's tile and cards for an icon of `size` px centred on (cx, cy). */
export const iconRects = (cx: number, cy: number, size: number) => {
  const s = size / 1024;
  const o = {x: cx - size / 2, y: cy - size / 2};
  const card = (c: (typeof ICON_CARDS)[CardName]): Rect => ({x: o.x + c.x * s, y: o.y + c.y * s, w: c.w * s, h: c.h * s, r: 48 * s});
  return {
    tile: {x: o.x, y: o.y, w: size, h: size, r: size * 0.2237} as Rect,
    back: card(ICON_CARDS.back),
    mid: card(ICON_CARDS.mid),
    top: card(ICON_CARDS.top),
  };
};

const FILAMENT =
  'M345.2,562.0 L347.1,556.6 L348.6,551.3 L349.5,546.0 L350.0,541.0 L350.1,536.1 L349.7,531.4 L349.0,527.1 L347.8,523.1 L346.4,519.5 L344.6,516.3 L342.5,513.5 L340.3,511.2 L337.8,509.4 L335.2,508.1 L332.5,507.3 L329.8,507.0 L327.0,507.3 L324.3,508.1 L321.7,509.4 L319.3,511.2 L317.0,513.5 L315.0,516.3 L313.2,519.5 L311.7,523.1 L310.6,527.1 L309.8,531.4 L309.4,536.1 L309.5,541.0 L310.0,546.0 L311.0,551.3 L312.4,556.6 L314.3,562.0 L316.7,567.4 L319.6,572.7 L323.0,578.0 L326.8,583.0 L331.0,587.9 L335.7,592.6 L340.8,596.9 L346.3,600.9 L352.0,604.5 L358.1,607.7 L364.5,610.5 L371.1,612.8 L377.9,614.6 L384.8,615.9 L391.8,616.7 L398.9,617.0 L405.9,616.7 L413.0,615.9 L419.9,614.6 L426.7,612.8 L433.3,610.5 L439.6,607.7 L445.7,604.5 L451.5,600.9 L457.0,596.9 L462.1,592.6 L466.7,587.9 L471.0,583.0 L474.8,578.0 L478.2,572.7 L481.0,567.4 L483.4,562.0 L485.4,556.6 L486.8,551.3 L487.8,546.0 L488.3,541.0 L488.3,536.1 L488.0,531.4 L487.2,527.1 L486.1,523.1 L484.6,519.5 L482.8,516.3 L480.8,513.5 L478.5,511.2 L476.0,509.4 L473.4,508.1 L470.7,507.3 L468.0,507.0 L465.3,507.3 L462.6,508.1 L460.0,509.4 L457.5,511.2 L455.2,513.5 L453.2,516.3 L451.4,519.5 L449.9,523.1 L448.8,527.1 L448.0,531.4 L447.7,536.1 L447.7,541.0 L448.2,546.0 L449.2,551.3 L450.6,556.6 L452.6,562.0 L455.0,567.4 L457.8,572.7 L461.2,578.0 L465.0,583.0 L469.3,587.9 L473.9,592.6 L479.0,596.9 L484.5,600.9 L490.3,604.5 L496.4,607.7 L502.7,610.5 L509.3,612.8 L516.1,614.6 L523.0,615.9 L530.1,616.7 L537.1,617.0 L544.2,616.7 L551.2,615.9 L558.1,614.6 L564.9,612.8 L571.5,610.5 L577.9,607.7 L584.0,604.5 L589.7,600.9 L595.2,596.9 L600.3,592.6 L605.0,587.9 L609.2,583.0 L613.0,578.0 L616.4,572.7 L619.3,567.4 L621.7,562.0 L623.6,556.6 L625.0,551.3 L626.0,546.0 L626.5,541.0 L626.6,536.1 L626.2,531.4 L625.4,527.1 L624.3,523.1 L622.8,519.5 L621.0,516.3 L619.0,513.5 L616.7,511.2 L614.3,509.4 L611.7,508.1 L609.0,507.3 L606.2,507.0 L603.5,507.3 L600.8,508.1 L598.2,509.4 L595.7,511.2 L593.5,513.5 L591.4,516.3 L589.6,519.5 L588.2,523.1 L587.0,527.1 L586.3,531.4 L585.9,536.1 L586.0,541.0 L586.5,546.0 L587.4,551.3 L588.9,556.6 L590.8,562.0';

/** The icon's tile: the purple gradient square, as a rect that can grow, shrink and move. */
export const Tile: React.FC<{rect: Rect; glow?: number}> = ({rect, glow = 0}) => (
  <div
    style={{
      ...rectStyle(rect),
      background: `linear-gradient(160deg, #5B33D6 0%, ${COLORS.purple} 45%, ${COLORS.purpleDeep} 100%)`,
      boxShadow: `0 ${rect.w * 0.04}px ${rect.w * 0.12}px rgba(10, 0, 40, ${0.35 + glow * 0.2}), inset 0 1px 0 rgba(255,255,255,0.18)`,
    }}
  />
);

/** One of the icon's cards: white glass, optionally showing a picture on its face. A card can
 * flip around its vertical axis (`flip` 0 → 1): the face shows `image`, the back is plain white. */
export const IconCard: React.FC<{rect: Rect; opacity?: number; image?: string; flip?: number; rotate?: number; children?: React.ReactNode}> = ({
  rect,
  opacity = 0.92,
  image,
  flip = 0,
  rotate = 0,
  children,
}) => {
  const angle = flip * 180;
  const faceVisible = angle < 90;
  return (
    <div style={{...rectStyle(rect), transform: `rotate(${rotate}deg) perspective(1600px) rotateY(${angle}deg)`}}>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: rect.r,
          overflow: 'hidden',
          background: image && faceVisible ? COLORS.canvas : `rgba(255,255,255,${opacity})`,
          boxShadow: `0 ${rect.h * 0.03}px ${rect.h * 0.09}px rgba(20, 0, 60, 0.28)`,
          transform: faceVisible ? undefined : 'scaleX(-1)',
        }}
      >
        {image && faceVisible ? <Img src={image} style={{width: '100%', height: '100%', objectFit: 'cover'}} /> : null}
        {children}
      </div>
    </div>
  );
};

/** The filament on the top card, drawn on as `draw` goes 0 → 1 (it is a stroke, not a fade). */
export const Filament: React.FC<{tile: Rect; draw: number; width?: number}> = ({tile, draw, width = 26}) => (
  <svg viewBox="0 0 1024 1024" style={{position: 'absolute', left: tile.x, top: tile.y, width: tile.w, height: tile.h, overflow: 'visible'}}>
    <path
      d={FILAMENT}
      pathLength={1}
      fill="none"
      stroke={COLORS.violet}
      strokeWidth={width}
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeDasharray={1}
      strokeDashoffset={1 - draw}
      transform="rotate(-7 468 562)"
      style={{visibility: draw > 0.001 ? 'visible' : 'hidden'}}
    />
  </svg>
);

// --- Footage ------------------------------------------------------------------------

type Clip = {file: string; ranges: number[][]; playFrom: number; playTo: number};
export const CLIPS = clipsJson.clips as Record<string, Clip>;
export const FOOTAGE_ASPECT = clipsJson.size[0] / clipsJson.size[1];

export const still = (id: string, which: 'start' | 'end') => staticFile(`footage/stills/${id}-${which}.jpg`);

/** A clip filling its parent: the first frame until its turn, then the ranges back to back,
 * sped up to fit, then the last frame. Times are global frames (render at the top level). */
export const Footage: React.FC<{id: string}> = ({id}) => {
  const clip = CLIPS[id];
  const from = bar(clip.playFrom);
  const to = bar(clip.playTo);
  const total = clip.ranges.reduce((s, [a, b]) => s + (b - a), 0);
  const rate = total / ((to - from) / FPS);
  let t = from;
  const parts = clip.ranges.map(([a, b], i) => {
    const frames = Math.round(((b - a) / rate) * FPS);
    const seq = (
      <Sequence key={i} from={t} durationInFrames={frames} layout="none">
        <OffthreadVideo
          src={staticFile(`footage/${clip.file}.mp4`)}
          trimBefore={Math.round(a * FPS)}
          playbackRate={rate}
          muted
          style={{position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover'}}
        />
      </Sequence>
    );
    t += frames;
    return seq;
  });
  const imgStyle: React.CSSProperties = {position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover'};
  return (
    <>
      <Sequence durationInFrames={from} layout="none">
        <Img src={still(id, 'start')} style={imgStyle} />
      </Sequence>
      {parts}
      <Sequence from={t} layout="none">
        <Img src={still(id, 'end')} style={imgStyle} />
      </Sequence>
    </>
  );
};

/** A window-like card that holds footage: rounded, with a soft shadow, positioned by `rect`. */
export const ScreenCard: React.FC<{rect: Rect; rotate?: number; children: React.ReactNode; shadow?: number}> = ({rect, rotate = 0, children, shadow = 1}) => (
  <div
    style={{
      ...rectStyle(rect),
      overflow: 'hidden',
      background: COLORS.canvas,
      transform: `rotate(${rotate}deg)`,
      boxShadow: `0 ${18 * shadow}px ${60 * shadow}px rgba(30, 10, 70, ${0.22 * shadow}), 0 2px 6px rgba(30, 10, 70, ${0.12 * shadow})`,
    }}
  >
    {children}
  </div>
);

// --- Type and keys ------------------------------------------------------------------------

/** A line of text that rises into place from below a mask (`t` 0 → 1) and leaves upward (`out` 0 → 1). */
export const Rise: React.FC<{t: number; out?: number; children: React.ReactNode; style?: React.CSSProperties; lineHeight?: number}> = ({
  t,
  out = 0,
  children,
  style,
  lineHeight = 1.12,
}) => (
  <div style={{overflow: 'hidden', lineHeight, paddingBottom: '0.08em', ...style}}>
    <div style={{transform: `translateY(${(1 - t) * 110 - out * 110}%)`}}>{children}</div>
  </div>
);

export const Keycap: React.FC<{label: string; press?: number; scale?: number; dark?: boolean}> = ({label, press = 0, scale = 1, dark = false}) => (
  <div
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      minWidth: 64 * scale,
      height: 64 * scale,
      padding: `0 ${18 * scale}px`,
      borderRadius: 16 * scale,
      fontFamily: FONT,
      fontWeight: 600,
      fontSize: 30 * scale,
      color: dark ? COLORS.white : COLORS.ink,
      background: dark ? 'rgba(255,255,255,0.14)' : COLORS.white,
      boxShadow: dark
        ? `inset 0 1px 0 rgba(255,255,255,0.25), 0 ${(1 - press) * 6 * scale}px 0 rgba(0,0,0,0.35)`
        : `0 ${(1 - press) * 6 * scale}px 0 #CFCBD6, 0 ${(1 - press) * 10 * scale}px 24px rgba(40,20,80,0.15)`,
      transform: `translateY(${press * 6 * scale}px)`,
      letterSpacing: 0.5,
    }}
  >
    {label}
  </div>
);

/** Small pill: what was typed, a list name, a date. */
export const Chip: React.FC<{children: React.ReactNode; t: number; tone?: 'light' | 'violet' | 'dark'}> = ({children, t, tone = 'light'}) => {
  const bg = tone === 'violet' ? COLORS.violet : tone === 'dark' ? 'rgba(255,255,255,0.12)' : COLORS.white;
  const fg = tone === 'light' ? COLORS.ink : COLORS.white;
  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        height: 56,
        padding: '0 22px',
        borderRadius: 28,
        background: bg,
        color: fg,
        fontFamily: FONT,
        fontSize: 26,
        fontWeight: 600,
        boxShadow: tone === 'light' ? '0 6px 18px rgba(40,20,80,0.12)' : undefined,
        transform: `translateY(${(1 - t) * 30}px) scale(${mix(0.6, 1, t)})`,
        transformOrigin: 'left center',
        visibility: t > 0.01 ? 'visible' : 'hidden',
        whiteSpace: 'nowrap',
      }}
    >
      {children}
    </div>
  );
};

// --- A month board in miniature (the year view) ---------------------------------------------

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/** Like the companion's month board: a weekday header row and one tile per day, Monday first. */
export const MiniMonth: React.FC<{year: number; month: number; rect: Rect; reveal: number; highlight?: number}> = ({year, month, rect, reveal, highlight}) => {
  const first = new Date(year, month - 1, 1).getDay(); // 0 = Sunday
  const offset = (first + 6) % 7;
  const days = new Date(year, month, 0).getDate();
  const pad = rect.w * 0.06;
  const cell = (rect.w - pad * 2) / 7;
  const head = rect.h * 0.16;
  return (
    <div style={{...rectStyle(rect), background: '#F4F2EF', boxShadow: '0 10px 30px rgba(20,0,60,0.25)', overflow: 'hidden'}}>
      <div style={{position: 'absolute', left: pad, top: pad * 0.7, fontFamily: FONT, fontWeight: 700, fontSize: rect.w * 0.07, color: COLORS.ink}}>
        {MONTHS[month - 1]}
      </div>
      {Array.from({length: days}, (_, i) => {
        const slot = offset + i;
        const col = slot % 7;
        const row = Math.floor(slot / 7);
        // each day lands on its own beat of the reveal, left to right, top to bottom
        const t = Math.min(1, Math.max(0, reveal * 1.6 - (i / days) * 0.6));
        const isToday = highlight === i + 1;
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: pad + col * cell + cell * 0.08,
              top: head + pad * 0.6 + row * cell * 0.86 + cell * 0.06,
              width: cell * 0.84,
              height: cell * 0.72,
              borderRadius: cell * 0.12,
              background: isToday ? COLORS.violet : '#FFFFFF',
              boxShadow: '0 1px 2px rgba(0,0,0,0.08)',
              transform: `scale(${t})`,
            }}
          />
        );
      })}
    </div>
  );
};

// --- The reminder banner --------------------------------------------------------------------

export const Banner: React.FC<{rect: Rect}> = ({rect}) => {
  const s = rect.h / 110;
  return (
    <div
      style={{
        ...rectStyle(rect),
        background: 'rgba(250, 249, 252, 0.94)',
        boxShadow: '0 20px 60px rgba(10,0,40,0.35)',
        display: 'flex',
        alignItems: 'center',
        gap: 20 * s,
        padding: `0 ${26 * s}px`,
        fontFamily: FONT,
        boxSizing: 'border-box',
      }}
    >
      <div style={{position: 'relative', width: 62 * s, height: 62 * s, flex: 'none'}}>
        <MiniIcon size={62 * s} />
      </div>
      <div style={{display: 'flex', flexDirection: 'column', gap: 4 * s, minWidth: 0}}>
        <div style={{fontSize: 22 * s, fontWeight: 700, color: COLORS.ink}}>Allume Companion</div>
        <div style={{fontSize: 22 * s, color: COLORS.ink}}>Book flights to Osaka</div>
        <div style={{fontSize: 18 * s, color: COLORS.inkSoft}}>Due today · Trip Ideas</div>
      </div>
      <div style={{marginLeft: 'auto', alignSelf: 'flex-start', marginTop: 20 * s, fontSize: 18 * s, color: COLORS.inkSoft}}>now</div>
    </div>
  );
};

/** The icon, static and small (in the banner). */
export const MiniIcon: React.FC<{size: number}> = ({size}) => {
  const r = iconRects(size / 2, size / 2, size);
  return (
    <div style={{position: 'absolute', inset: 0}}>
      <Tile rect={r.tile} />
      <IconCard rect={r.back} opacity={0.5} />
      <IconCard rect={r.mid} opacity={0.7} />
      <IconCard rect={r.top} opacity={0.95} />
      <Filament tile={r.tile} draw={1} />
    </div>
  );
};

/** The global frame at which a clip shows source time `t` (seconds), across its ranges. */
export const clipFrame = (id: string, t: number) => {
  const clip = CLIPS[id];
  const from = bar(clip.playFrom);
  const to = bar(clip.playTo);
  const total = clip.ranges.reduce((s, [a, b]) => s + (b - a), 0);
  const rate = total / ((to - from) / FPS);
  let acc = 0;
  for (const [a, b] of clip.ranges) {
    if (t <= b) return Math.round(from + ((acc + Math.max(0, t - a)) / rate) * FPS);
    acc += b - a;
  }
  return to;
};
