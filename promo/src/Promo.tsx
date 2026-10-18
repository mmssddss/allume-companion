import React from 'react';
import {AbsoluteFill, Html5Audio, Easing, interpolate, staticFile, useCurrentFrame} from 'remotion';
import {BOUNCY, bar, centred, COLORS, FONT, H, lin, mix, mixRect, Rect, rectStyle, SNAPPY, SOFT, sp, W} from './lib';
import {Banner, Chip, clipFrame, Filament, Footage, FOOTAGE_ASPECT, IconCard, iconRects, Keycap, MiniMonth, Rise, ScreenCard, still, Tile} from './parts';

// Everything on screen is computed from the frame. Nothing fades in or out: things grow from a
// point, fly in from an edge, rise out of a mask, flip, or morph from one rect into another.

const FULL: Rect = {x: 0, y: 0, w: W, h: H, r: 0};
const card = (x: number, y: number, w: number, r = 26): Rect => ({x, y, w, h: Math.round(w / FOOTAGE_ASPECT), r});
const FEATURE = card(650, 196, 1150);
const OFF_RIGHT = card(2040, 300, 980);
const OFF_LEFT = card(-1150, 300, 980);
const BIG = card(660, 180, 1170, 30);
const LIGHT = '#EFEDEA';

type Key = {k: string; t: number; key?: boolean; tone?: 'light' | 'violet' | 'dark'};
type Feature = {id: string; from: number; kicker: string; lines: string[]; keys: Key[][]};

// The six simple ones, two bars each. Key times are source seconds of the clip (motion spans).
const FEATURES: Feature[] = [
  {id: 'arrange', from: 4, kicker: 'Arrange', lines: ['Tidy up any mess', 'in one keystroke.'], keys: [[{k: '⌘K', t: 3.55, key: true}, {k: 'grid 3', t: 4.8}, {k: '⏎', t: 5.92, key: true}]]},
  {id: 'sameSize', from: 6, kicker: 'Same size', lines: ['Every card,', 'the same size.'], keys: [[{k: '⌘K', t: 2.43, key: true}, {k: 'medium', t: 3.8}, {k: '⏎', t: 4.82, key: true}]]},
  {id: 'undo', from: 8, kicker: 'Undo', lines: ['Changed your mind?', 'Put them back.'], keys: [[{k: '⌘K', t: 2.42, key: true}, {k: 'undo', t: 3.7}, {k: '⏎', t: 4.77, key: true}]]},
  {id: 'jump', from: 10, kicker: 'Jump', lines: ['Any board,', 'a few letters away.'], keys: [[{k: '⌘K', t: 1.92, key: true}, {k: 'trip', t: 3.22}, {k: '⏎', t: 4.75, key: true}]]},
  {
    id: 'addTodo',
    from: 12,
    kicker: 'Todos',
    lines: ['Write it the way', 'you would say it.'],
    keys: [
      [{k: '⌘K', t: 2.9, key: true}, {k: 'add todo', t: 3.98}, {k: '⏎', t: 5.05, key: true}],
      [{k: 'Book flights to Osaka', t: 6.05}, {k: 'friday → Oct 23', t: 6.6, tone: 'violet'}],
    ],
  },
  {id: 'doneTodo', from: 14, kicker: 'Done', lines: ['Check it off', 'from anywhere.'], keys: [[{k: '⌘K', t: 10.33, key: true}, {k: 'all todos', t: 11.4}, {k: '⌘⏎', t: 14.7, key: true}]]},
];

const kickerStyle = (dark: boolean): React.CSSProperties => ({
  fontFamily: FONT,
  fontSize: 26,
  fontWeight: 700,
  letterSpacing: 2,
  textTransform: 'uppercase',
  color: dark ? COLORS.lavender : COLORS.violet,
});
const headlineStyle = (dark: boolean, size = 64): React.CSSProperties => ({
  fontFamily: FONT,
  fontSize: size,
  fontWeight: 700,
  letterSpacing: -1.6,
  color: dark ? COLORS.white : COLORS.ink,
  whiteSpace: 'nowrap',
});

/** Kicker, two headline lines and rows of keys, rising in at `start` and up out at `end`. */
const Caption: React.FC<{
  f: number;
  start: number;
  end?: number;
  kicker: string;
  lines: string[];
  keys?: {k: string; at: number; key?: boolean; tone?: 'light' | 'violet' | 'dark'}[][];
  dark?: boolean;
  x?: number;
  y?: number;
  size?: number;
  extra?: React.ReactNode;
}> = ({f, start, end, kicker, lines, keys = [], dark = false, x = 120, y = 330, size = 64, extra}) => {
  if (f < start - 2 || (end !== undefined && f > end + 45)) return null;
  const out = end !== undefined ? sp(f, end, SNAPPY) : 0;
  return (
    <div style={{position: 'absolute', left: x, top: y, width: 600}}>
      <Rise t={sp(f, start)} out={out} style={kickerStyle(dark)}>
        {kicker}
      </Rise>
      <div style={{height: 14}} />
      {lines.map((l, i) => (
        <Rise key={i} t={sp(f, start + 4 + i * 4)} out={out} style={headlineStyle(dark, size)}>
          {l}
        </Rise>
      ))}
      <div style={{overflow: 'hidden', marginTop: 28, paddingBottom: 18}}>
        <div style={{display: 'flex', flexDirection: 'column', gap: 14}}>
          {keys.map((row, ri) => (
            <div key={ri} style={{display: 'flex', gap: 12, alignItems: 'center', height: 64}}>
              {row.map((k, i) => {
                const t = sp(f, k.at, BOUNCY) * (1 - out);
                if (k.key) {
                  const press = interpolate(f, [k.at + 2, k.at + 6, k.at + 14], [0, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
                  return (
                    <div key={i} style={{transform: `translateY(${(1 - t) * 30}px) scale(${mix(0.5, 1, t)})`, visibility: t > 0.01 ? 'visible' : 'hidden'}}>
                      <Keycap label={k.k} press={press} scale={0.85} dark={dark} />
                    </div>
                  );
                }
                return (
                  <Chip key={i} t={t} tone={k.tone ?? (dark ? 'dark' : 'light')}>
                    {k.k}
                  </Chip>
                );
              })}
            </div>
          ))}
          {extra}
        </div>
      </div>
    </div>
  );
};

// --- Year view ----------------------------------------------------------------------
const YEAR = {x: 560, y: 196, cols: 4, w: 300, h: 214, gap: 26};
const yearSlot = (m: number): Rect => {
  const i = m - 1;
  return {x: YEAR.x + (i % YEAR.cols) * (YEAR.w + YEAR.gap), y: YEAR.y + Math.floor(i / YEAR.cols) * (YEAR.h + YEAR.gap), w: YEAR.w, h: YEAR.h, r: 18};
};
// where each month flies in from: around the screen edge, as if dealt from the deck
const yearOrigin = (m: number): Rect => {
  const a = (m * 137.5 * Math.PI) / 180;
  return centred(960 + Math.cos(a) * 1500, 540 + Math.sin(a) * 1000, 300, 214, 18);
};

// --- The wall of everything, and where each card comes from -------------------------
const WALL_IDS = ['arrange', 'sameSize', 'undo', 'jump', 'addTodo', 'doneTodo', 'daily', 'projects'];
const WALL = {x: 118, y: 330, w: 400, gap: 28};
const wallSlot = (i: number): Rect => {
  const h = Math.round(WALL.w / FOOTAGE_ASPECT);
  return {x: WALL.x + (i % 4) * (WALL.w + WALL.gap), y: WALL.y + Math.floor(i / 4) * (h + WALL.gap), w: WALL.w, h, r: 16};
};

/** The month name on the real October board once it sits among the miniature months. */
const OctoberLabel: React.FC<{t: number; w: number}> = ({t, w}) => (
  <div
    style={{
      position: 'absolute',
      left: w * 0.06,
      top: w * 0.04,
      padding: `${w * 0.008}px ${w * 0.02}px`,
      borderRadius: w * 0.02,
      background: '#F4F2EF',
      fontFamily: FONT,
      fontWeight: 700,
      fontSize: w * 0.07,
      color: COLORS.ink,
      transform: `scale(${t})`,
      transformOrigin: 'left top',
    }}
  >
    October
  </div>
);

export const Promo: React.FC = () => {
  const f = useCurrentFrame();

  // ---------------- Opening (bars 0–4) ----------------
  const iconCentre = {x: 960, y: mix(500, 360, sp(f, bar(1.5), SOFT))};
  const iconSize = mix(400, 300, sp(f, bar(1.5), SOFT));
  const ic = iconRects(iconCentre.x, iconCentre.y, iconSize);
  const tileIn = sp(f, 8, BOUNCY);
  const openOut = sp(f, bar(3) + 4, SOFT); // ⌘K pressed: the top card becomes the canvas
  const tileRect = mixRect(centred(ic.tile.x + ic.tile.w / 2, ic.tile.y + ic.tile.h / 2, 0, 0, 0), ic.tile, tileIn * (1 - openOut));
  const land = (start: number, from: Rect, to: Rect) => mixRect(from, to, sp(f, start, BOUNCY));
  const backFly = mixRect(land(42, centred(2300, -400, 560, 420, 40), ic.back), centred(2400, -600, 700, 520, 40), openOut);
  const midFly = mixRect(land(72, centred(-500, 900, 560, 420, 40), ic.mid), centred(-700, 1500, 700, 520, 40), openOut);
  const topLanded = land(102, centred(960, 1500, 560, 420, 40), ic.top);
  const canvasRect = mixRect(topLanded, FULL, openOut);
  const filamentDraw = Easing.inOut(Easing.cubic)(lin(f, 126, 172)) * (1 - lin(f, bar(3) - 14, bar(3) + 2));
  const keyIn = sp(f, bar(2.5), BOUNCY);
  const keyPress = interpolate(f, [bar(3) - 2, bar(3) + 3, bar(3) + 12], [0, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const keyOut = sp(f, bar(3) + 10, SNAPPY);

  // ---------------- Features carousel (bars 4–16) ----------------
  const featureRect = (i: number): Rect => {
    const s = FEATURES[i].from;
    const enter = sp(f, i === 0 ? bar(3.3) : bar(s) - 18, SNAPPY);
    const exit = i === FEATURES.length - 1 ? 0 : sp(f, bar(s + 2) - 18, SNAPPY);
    return mixRect(mixRect(OFF_RIGHT, FEATURE, enter), OFF_LEFT, exit);
  };
  const featureTilt = (i: number) => {
    const s = FEATURES[i].from;
    return mix(6, 0, sp(f, i === 0 ? bar(3.3) : bar(s) - 18, SNAPPY)) - (i === FEATURES.length - 1 ? 0 : mix(0, 6, sp(f, bar(s + 2) - 18, SNAPPY)));
  };

  // ---------------- Fake ending (bars 16–18) ----------------
  const fe = iconRects(960, 540, 380);
  const gather = sp(f, bar(15.875) - 6, SOFT);
  const ghostBack = sp(f, bar(15.875) + 6, SOFT);
  const ghostMid = sp(f, bar(15.875) + 12, SOFT);
  const iris = sp(f, bar(16.25), SOFT);
  const feTileIn = sp(f, bar(16.5), BOUNCY);
  const feFilament = Easing.inOut(Easing.cubic)(lin(f, bar(16.75), bar(17.1)));
  const tension = lin(f, bar(17), bar(17.75)) * 0.05;
  const squash = interpolate(f, [bar(17.75), bar(17.75) + 8, bar(18)], [0, -0.07, -0.07], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const burst = sp(f, bar(18), BOUNCY); // the drop
  const feScale = 1 + tension + squash;
  const scaleAbout = (r: Rect, s: number): Rect => centred(960 + (r.x + r.w / 2 - 960) * s, 540 + (r.y + r.h / 2 - 540) * s, r.w * s, r.h * s, r.r * s);

  // ---------------- Big section (bars 18–26) ----------------
  const yearIn = sp(f, bar(21) - 10, SOFT); // daily card shrinks into October
  const yearOut = sp(f, bar(23) - 16, SNAPPY);
  const projectsIn = sp(f, bar(23) - 10, SNAPPY);
  const bannerIn = sp(f, bar(25) - 8, BOUNCY);
  const wallIn = sp(f, bar(26) - 14, SOFT);
  const bannerOut = sp(f, bar(26) - 14, SNAPPY);

  // ---------------- Closing (bars 27–32) ----------------
  const stack = sp(f, bar(27) - 10, SOFT);
  const cl = iconRects(mix(960, 640, sp(f, bar(28), SOFT)), 540, mix(380, 300, sp(f, bar(28), SOFT)));
  const clTileIn = sp(f, bar(27) + 4, BOUNCY);
  const clFilament = Easing.inOut(Easing.cubic)(lin(f, bar(27.4), bar(27.8)));
  const finalPulse = interpolate(f, [bar(30), bar(30) + 5, bar(30) + 22], [0, 0.06, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  const daily = f >= bar(18) && f < bar(23);

  return (
    <AbsoluteFill style={{background: `radial-gradient(ellipse at 50% 45%, #4B25C2 0%, ${COLORS.purple} 38%, ${COLORS.purpleDeep} 100%)`, overflow: 'hidden', fontFamily: FONT}}>
      <Html5Audio src={staticFile('audio/music.wav')} />

      {/* ===== Opening ===== */}
      {f < bar(4) && (
        <>
          {tileRect.w > 1 && <Tile rect={tileRect} />}
          <IconCard rect={backFly} opacity={0.55} rotate={mix(-25, 0, sp(f, 42, BOUNCY)) + openOut * 30} />
          <IconCard rect={midFly} opacity={0.72} rotate={mix(20, 0, sp(f, 72, BOUNCY)) - openOut * 25} />
          <Rise
            t={sp(f, bar(1.5) + 10)}
            out={openOut}
            style={{position: 'absolute', left: 0, right: 0, top: 560, textAlign: 'center', ...headlineStyle(true, 104), letterSpacing: -3}}
          >
            Allume Companion
          </Rise>
          <Rise
            t={sp(f, bar(1.5) + 20)}
            out={openOut}
            style={{position: 'absolute', left: 0, right: 0, top: 690, textAlign: 'center', fontSize: 40, fontWeight: 500, color: COLORS.lavender}}
          >
            The ⌘K command palette for Allume
          </Rise>
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              top: 800,
              display: 'flex',
              justifyContent: 'center',
              transform: `translateY(${(1 - keyIn) * 60 + keyOut * 420}px) scale(${mix(0.4, 1, keyIn)})`,
              visibility: keyIn > 0.01 ? 'visible' : 'hidden',
            }}
          >
            <Keycap label="⌘ K" press={keyPress} scale={1.3} dark />
          </div>
        </>
      )}

      {/* ===== The light canvas: the icon's top card, grown to fill the screen ===== */}
      {f < bar(16.9) && (
        <div
          style={{
            ...rectStyle(f < bar(3) ? topLanded : canvasRect),
            background: f < bar(3) ? 'rgba(255,255,255,0.95)' : LIGHT,
            boxShadow: f < bar(3) + 30 ? '0 12px 40px rgba(20,0,60,0.3)' : undefined,
            transform: f < bar(3) ? `rotate(${mix(-12, 0, sp(f, 102, BOUNCY))}deg)` : undefined,
          }}
        />
      )}
      {f < bar(3) + 2 && <Filament tile={ic.tile} draw={filamentDraw} />}

      {/* ===== Features ===== */}
      {f >= bar(3.3) &&
        f < bar(16.6) &&
        FEATURES.map((ft, i) => {
          const s = ft.from;
          if (f < (i === 0 ? bar(3.3) : bar(s) - 20) || (i < FEATURES.length - 1 && f > bar(s + 2) + 30)) return null;
          // the last one does not leave left: it becomes the icon's top card (fake ending)
          const r = i === FEATURES.length - 1 ? mixRect(featureRect(i), fe.top, gather) : featureRect(i);
          const flip = i === FEATURES.length - 1 ? lin(f, bar(15.875) + 6, bar(15.875) + 26) : 0;
          if (flip >= 0.5) return null;
          return (
            <ScreenCard key={ft.id} rect={r} rotate={featureTilt(i)} shadow={1 - gather * 0.5}>
              <Footage id={ft.id} />
            </ScreenCard>
          );
        })}
      {FEATURES.map((ft, i) => (
        <Caption
          key={ft.id}
          f={f}
          start={i === 0 ? bar(3.5) : bar(ft.from) - 8}
          end={bar(ft.from + 2) - 20}
          kicker={`0${i + 1}  ${ft.kicker}`}
          lines={ft.lines}
          keys={ft.keys.map((row) => row.map((k) => ({...k, at: clipFrame(ft.id, k.t) - 4})))}
        />
      ))}

      {/* ===== Fake ending: the cards gather into the icon on a purple iris ===== */}
      {f >= bar(16) && f < bar(17) && (
        <div
          style={{
            position: 'absolute',
            inset: 0,
            background: `radial-gradient(ellipse at 50% 45%, #4B25C2 0%, ${COLORS.purple} 38%, ${COLORS.purpleDeep} 100%)`,
            clipPath: `circle(${iris * 1250}px at 960px 540px)`,
          }}
        />
      )}
      {f >= bar(15.875) - 6 && f < bar(18.6) && (
        <>
          {(() => {
            const out = burst;
            const t = feTileIn * (1 - out);
            const tr = scaleAbout(fe.tile, t * feScale);
            return tr.w > 1 ? <Tile rect={tr} glow={tension * 10} /> : null;
          })()}
          <IconCard
            rect={mixRect(scaleAbout(mixRect(OFF_LEFT, fe.back, ghostBack), feScale), centred(2500, -500, 700, 520, 40), burst)}
            image={still('jump', 'end')}
            flip={lin(f, bar(15.875) + 14, bar(15.875) + 34)}
            opacity={0.55}
            rotate={mix(-14, 0, ghostBack) + burst * 30}
          />
          <IconCard
            rect={mixRect(scaleAbout(mixRect(OFF_LEFT, fe.mid, ghostMid), feScale), centred(-600, 1600, 700, 520, 40), burst)}
            image={still('addTodo', 'end')}
            flip={lin(f, bar(15.875) + 20, bar(15.875) + 40)}
            opacity={0.72}
            rotate={mix(-10, 0, ghostMid) - burst * 25}
          />
          {(() => {
            // the top card: the "done" footage flipped white; on the drop it flips back as the daily board
            const flipIn = lin(f, bar(15.875) + 6, bar(15.875) + 26);
            const flipBack = lin(f, bar(18), bar(18) + 12);
            const r = mixRect(scaleAbout(fe.top, feScale), BIG, burst);
            if (f < bar(18) && flipIn < 0.5) return null;
            if (f >= bar(18) && flipBack >= 0.5) return null; // the daily card takes over
            return <IconCard rect={r} image={f >= bar(18) ? still('daily', 'start') : still('doneTodo', 'end')} flip={f >= bar(18) ? 1 - flipBack : flipIn} opacity={0.95} />;
          })()}
          {f < bar(18) && <Filament tile={scaleAbout(fe.tile, feScale)} draw={feFilament} />}
        </>
      )}

      {/* ===== Daily notes ===== */}
      {daily && f >= bar(18) + 6 && (
        <>
          {(() => {
            const r = mixRect(BIG, yearSlot(10), yearIn);
            return (
              <ScreenCard rect={r}>
                <Footage id="daily" />
                <OctoberLabel t={yearIn} w={r.w} />
              </ScreenCard>
            );
          })()}
        </>
      )}
      <Caption
        f={f}
        start={bar(18) + 8}
        end={bar(21) - 14}
        dark
        kicker="Daily notes"
        lines={['Today.', 'This month.']}
        keys={[
          [{k: '⌘K', at: clipFrame('daily', 2.9) - 4, key: true}, {k: 'today', at: clipFrame('daily', 3.97)}],
          [{k: '⌘K', at: clipFrame('daily', 8.62) - 4, key: true}, {k: 'this month', at: clipFrame('daily', 9.6)}],
        ]}
        x={110}
        y={300}
        size={72}
      />

      {/* ===== A whole year ===== */}
      {f >= bar(21) - 12 && f < bar(23) + 30 && (
        <>
          {Array.from({length: 12}, (_, k) => k + 1)
            .filter((m) => m !== 10)
            .map((m, k) => {
              const t = sp(f, bar(21) - 2 + k * 3, BOUNCY);
              const away = sp(f, bar(23) - 16 + k * 2, SNAPPY);
              const r = mixRect(mixRect(yearOrigin(m), yearSlot(m), t), {...yearSlot(m), y: yearSlot(m).y - 1400}, away);
              const rot = mix((m % 2 ? 1 : -1) * 18, 0, t);
              return (
                <div key={m} style={{position: 'absolute', inset: 0, transform: `rotate(${rot}deg)`, transformOrigin: `${r.x + r.w / 2}px ${r.y + r.h / 2}px`}}>
                  <MiniMonth year={2026} month={m} rect={r} reveal={lin(f, bar(21) + 6 + k * 3, bar(21) + 50 + k * 3)} />
                </div>
              );
            })}
          {f >= bar(23) - 16 && (
            // October (the real board) leaves with the others
            <ScreenCard rect={{...yearSlot(10), y: yearSlot(10).y - 1400 * yearOut}} shadow={0.6}>
              <Footage id="daily" />
              <OctoberLabel t={1} w={YEAR.w} />
            </ScreenCard>
          )}
        </>
      )}
      {(() => {
        const n = Math.round(interpolate(f, [bar(21) + 10, bar(22.5)], [0, 365], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)}));
        return (
          <Caption
            f={f}
            start={bar(21) - 2}
            end={bar(23) - 18}
            dark
            kicker="A whole year"
            lines={['Every day,', 'set up for you.']}
            x={110}
            y={300}
            size={60}
            extra={
              <div style={{display: 'flex', alignItems: 'baseline', gap: 14, fontFamily: FONT, color: COLORS.white}}>
                <span style={{fontSize: 96, fontWeight: 800, letterSpacing: -3, fontVariantNumeric: 'tabular-nums'}}>{n}</span>
                <span style={{fontSize: 30, color: COLORS.lavender, fontWeight: 600}}>daily boards</span>
              </div>
            }
          />
        );
      })()}

      {/* ===== Projects + reminder ===== */}
      {f >= bar(23) - 12 && f < bar(27) && (
        <>
          {(() => {
            const r = mixRect(mixRect({...BIG, y: 1200}, BIG, projectsIn), wallSlot(7), wallIn);
            return (
              <ScreenCard rect={r}>
                <Footage id="projects" />
              </ScreenCard>
            );
          })()}
        </>
      )}
      <Caption
        f={f}
        start={bar(23) - 6}
        end={bar(25) - 14}
        dark
        kicker="Projects"
        lines={['Todo, Doing, Done:', 'one command apart.']}
        keys={[[{k: '⌘K', at: clipFrame('projects', 2.98) - 4, key: true}, {k: 'doing', at: clipFrame('projects', 4.17)}, {k: '⏎', at: clipFrame('projects', 5.33), key: true}]]}
        x={110}
        y={300}
        size={50}
      />
      {f >= bar(25) - 10 && f < bar(26.5) && (
        <Banner rect={mixRect(mixRect({x: 1960, y: 60, w: 560, h: 116, r: 24}, {x: 1300, y: 60, w: 560, h: 116, r: 24}, bannerIn), {x: 1300, y: -220, w: 560, h: 116, r: 24}, bannerOut)} />
      )}
      <Caption f={f} start={bar(25) - 6} end={bar(26) - 18} dark kicker="Reminders" lines={['On the day,', 'right on time.']} x={110} y={300} size={60} />

      {/* ===== The closing tile, under the cards that come home to it ===== */}
      {f >= bar(27) - 10 &&
        (() => {
          const s = 1 + finalPulse;
          const tr = centred(cl.tile.x + cl.tile.w / 2, cl.tile.y + cl.tile.h / 2, cl.tile.w * clTileIn * s, cl.tile.h * clTileIn * s, cl.tile.r * clTileIn * s);
          return tr.w > 1 ? <Tile rect={tr} glow={finalPulse * 10} /> : null;
        })()}

      {/* ===== The wall: everything, from ⌘K ===== */}
      {f >= bar(26) - 14 && f < bar(27.6) &&
        WALL_IDS.slice(0, 7).map((id, i) => {
          // each card returns from the side it left by
          const from = i < 6 ? centred(-700, 300 + i * 120, 400, 238, 16) : centred(960, 1500, 400, 238, 16);
          const t = sp(f, bar(26) - 14 + i * 3, SNAPPY);
          const target = wallSlot(i);
          const slot = Math.min(2, i % 3);
          const toIcon = [cl.back, cl.mid, cl.top][slot];
          const r = mixRect(mixRect(from, target, t), i < 3 ? toIcon : centred(cl.top.x + cl.top.w / 2, cl.top.y + cl.top.h / 2, 0, 0, 0), stack);
          const flip = i < 3 ? lin(f, bar(27) - 4 + i * 3, bar(27) + 14 + i * 3) : 0;
          if (r.w < 2) return null;
          return <IconCard key={id} rect={r} image={still(id, 'end')} flip={flip} opacity={[0.55, 0.72, 0.95][slot]} />;
        })}
      {f >= bar(26) - 14 && f < bar(27.6) && (() => {
        // the projects card is already on screen: it moves into its slot, then becomes nothing behind the stack
        if (f < bar(26) + 20) return null;
        const r = mixRect(wallSlot(7), centred(cl.top.x + cl.top.w / 2, cl.top.y + cl.top.h / 2, 0, 0, 0), stack);
        return r.w > 2 ? <IconCard rect={r} image={still('projects', 'end')} /> : null;
      })()}
      {(() => {
        const t = sp(f, bar(26) - 4);
        const out = sp(f, bar(27) - 12);
        if (f < bar(26) - 6 || f > bar(27) + 30) return null;
        return (
          <Rise t={t} out={out} style={{position: 'absolute', left: 0, right: 0, top: 150, textAlign: 'center', ...headlineStyle(true, 76)}}>
            Everything, one ⌘K away.
          </Rise>
        );
      })()}

      {/* ===== Closing lockup ===== */}
      {f >= bar(27) - 10 && (
        <>
          {f >= bar(27.6) && (
            <>
              <IconCard rect={cl.back} opacity={0.55} />
              <IconCard rect={cl.mid} opacity={0.72} />
              <IconCard rect={cl.top} opacity={0.95} />
            </>
          )}
          <Filament tile={cl.tile} draw={clFilament} />
          <div style={{position: 'absolute', left: 860, top: 372}}>
            <Rise t={sp(f, bar(28) + 6)} style={{...headlineStyle(true, 96), letterSpacing: -3}}>
              Allume Companion
            </Rise>
            <Rise t={sp(f, bar(28) + 14)} style={{fontFamily: FONT, fontSize: 38, fontWeight: 500, color: COLORS.lavender, marginTop: 6}}>
              The ⌘K command palette for Allume
            </Rise>
            <div style={{display: 'flex', gap: 12, marginTop: 34, alignItems: 'center'}}>
              <div style={{transform: `scale(${mix(0.5, 1, sp(f, bar(28.75), BOUNCY))})`, visibility: f >= bar(28.75) ? 'visible' : 'hidden'}}>
                <Keycap
                  label="⌘ K"
                  dark
                  scale={0.9}
                  press={interpolate(f, [bar(29) - 2, bar(29) + 3, bar(29) + 12], [0, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})}
                />
              </div>
              <Chip t={sp(f, bar(29) + 6, BOUNCY)} tone="dark">
                Free · Open source · macOS 14+
              </Chip>
            </div>
            <Rise t={sp(f, bar(30))} style={{fontFamily: FONT, fontSize: 44, fontWeight: 700, color: COLORS.white, marginTop: 40, letterSpacing: -0.5}}>
              companion.maverickli.org
            </Rise>
          </div>
        </>
      )}
    </AbsoluteFill>
  );
};
