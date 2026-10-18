import React from 'react';
import {Composition} from 'remotion';
import {Promo} from './Promo';
import {BAR, FPS, H, W} from './lib';
import timeline from './timeline.json';

export const Root: React.FC = () => (
  <Composition id="Promo" component={Promo} durationInFrames={timeline.bars * BAR} fps={FPS} width={W} height={H} />
);
