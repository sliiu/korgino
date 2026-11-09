import React from 'react';
import {Split, reveal} from '../kit/text.jsx';
import {shot} from '../engine.js';
import {PopupPanel, PluginBar, VoiceCapsule, CaptionLane} from './ui.jsx';

const q = (id, sel) => document.querySelector(`section[data-shot="${id}"] ${sel}`);
// A set() placed at time 0 does not apply when the film is seeked to 0, so the
// opening shot is shown just before the start. Later shots are fine at their start.
const show = (tl, id) => {
  const at = shot(id).start === 0 ? -0.05 : shot(id).start;
  tl.set(document.querySelector(`section[data-shot="${id}"]`), {opacity: 1}, at);
};

function Paper({children}) { return <div className="paper" style={{position: 'absolute', inset: 0}}>{children}</div>; }

function Caption({s}) {
  return (
    <div className="caption">
      <div className="en"><Split text={s.headlineEn || ''} lang="en" /></div>
      <div className="zh"><Split text={s.headline} lang="zh-CN" /></div>
    </div>
  );
}

export function HookView({shot: s}) {
  return (
    <Paper>
      <div className="hook-stage">
        <div className="hook-src"><Split text="明天下午三点，我们在会议室见。" by="ch" /></div>
        <div className="hook-rule" data-el="rule" />
        <div className="hook-dst"><Split text="See you at the meeting room tomorrow at 3." by="word" lang="en" /></div>
      </div>
    </Paper>
  );
}

// The first frames are the finished frame: platforms grab frame 0 as the thumbnail.
export const buildHook = id => tl => {
  const s = shot(id);
  show(tl, id);
  const src = q(id, '.hook-src');
  const dst = q(id, '.hook-dst');
  const stage = q(id, '.hook-stage'), rule = q(id, '[data-el="rule"]');
  // GSAP renders the instant before a tween at time 0, so the shot's tweens start
  // at 0.1s and the opening frames fall in the held state before them.
  const hold = 0.1;
  tl.set(rule, {width: 180}, s.start + hold);
  // Keyframes pin the from-state to its own time. A fromTo would plant it at the
  // previous tween on the same target, which here would blank the opening frame.
  tl.to(stage, {keyframes: [{opacity: 1, duration: 0.55}, {opacity: 0, duration: 0.4, ease: 'power1.in'}, {opacity: 1, duration: 0.1}], ease: 'none'}, s.start + hold);
  tl.to(src, {keyframes: [{opacity: 1, y: 0, duration: 0.8}, {opacity: 0, y: 30, duration: 0.001}, {opacity: 1, y: 0, duration: 0.6, ease: 'expo.out'}], ease: 'none'}, s.start + hold);
  tl.to(rule, {keyframes: [{width: 180, duration: 1.6}, {width: 0, duration: 0.001}, {width: 180, duration: 0.5, ease: 'power2.out'}], ease: 'none'}, s.start + hold);
  tl.to(dst, {keyframes: [{opacity: 1, y: 0, duration: 1.9}, {opacity: 0, y: 16, duration: 0.001}, {opacity: 1, y: 0, duration: 0.5, ease: 'expo.out'}], ease: 'none'}, s.start + hold);
};

function feature(View) {
  return function FeatureView({shot: s}) {
    return (
      <Paper>
        <Caption s={s} />
        <div className="stage"><View /></div>
      </Paper>
    );
  };
}
export const PopupView = feature(PopupPanel);
export const PluginsView = feature(PluginBar);
export const VoiceView = feature(VoiceCapsule);
export const CaptionsView = feature(CaptionLane);

const captionIn = (tl, id, s) => {
  reveal(tl, q(id, '.en'), s.start + 0.1, {from: {opacity: 0, y: 14}, dur: 0.5, stagger: 0.02});
  reveal(tl, q(id, '.zh'), s.start + 0.2, {from: {opacity: 0, y: 18}, dur: 0.6, stagger: 0.035});
};

export const buildPopup = id => tl => {
  const s = shot(id);
  show(tl, id);
  captionIn(tl, id, s);
  tl.fromTo(q(id, '.panel'), {opacity: 0, y: 40}, {opacity: 1, y: 0, duration: 0.7, ease: 'expo.out'}, s.start + 0.5);
  tl.fromTo(q(id, '.panel-card'), {opacity: 0, y: 12}, {opacity: 1, y: 0, duration: 0.5, ease: 'expo.out'}, s.start + 1.4);
  tl.fromTo(q(id, '.panel-head .arrow'), {opacity: 0.3}, {opacity: 1, duration: 0.3}, s.start + 3.4);
};

export const buildPlugins = id => tl => {
  const s = shot(id);
  show(tl, id);
  captionIn(tl, id, s);
  tl.set(q(id, '[data-el="tip"]'), {opacity: 0}, s.start);
  tl.set(q(id, '[data-el="result"]'), {opacity: 0}, s.start);
  for (let i = 0; i < 3; i++) {
    tl.fromTo(q(id, `[data-el="b${i}"]`), {opacity: 0, scale: 0.6}, {opacity: 1, scale: 1, duration: 0.35, ease: 'expo.out'}, s.start + 0.5 + i * 0.3);
  }
  tl.to(q(id, '[data-el="tip"]'), {opacity: 1, duration: 0.3, ease: 'power2.out'}, s.start + 2.2);
  tl.fromTo(q(id, '[data-el="result"]'), {opacity: 0, y: 10}, {opacity: 1, y: 0, duration: 0.5, ease: 'expo.out'}, s.start + 3.4);
};

export const buildVoice = id => tl => {
  const s = shot(id);
  show(tl, id);
  captionIn(tl, id, s);
  tl.set(q(id, '[data-el="capsule"]'), {opacity: 0}, s.start);
  tl.set([q(id, '[data-el="heard"]'), q(id, '[data-el="said"]')], {opacity: 0}, s.start);
  tl.to(q(id, '[data-el="key"]'), {className: 'keycap down', duration: 0}, s.start + 0.5);
  tl.fromTo(q(id, '[data-el="capsule"]'), {opacity: 0, y: 16}, {opacity: 1, y: 0, duration: 0.4, ease: 'expo.out'}, s.start + 0.6);
  const bars = q(id, '[data-el="bars"]').querySelectorAll('i');
  bars.forEach((bar, i) => {
    tl.fromTo(bar, {scaleY: 0.4}, {scaleY: 1.5, duration: 0.35, yoyo: true, repeat: 5, ease: 'sine.inOut'}, s.start + 0.8 + i * 0.08);
  });
  tl.to(q(id, '[data-el="label"]'), {opacity: 0, duration: 0.3}, s.start + 3.5);
  tl.to(q(id, '[data-el="key"]'), {className: 'keycap', duration: 0}, s.start + 3.6);
  tl.to([q(id, '[data-el="heard"]'), q(id, '[data-el="said"]')], {opacity: 1, duration: 0.4, stagger: 0.15}, s.start + 3.7);
  tl.to(q(id, '[data-el="bars"]'), {opacity: 0, duration: 0.3}, s.start + 3.6);
};

export const buildCaptions = id => tl => {
  const s = shot(id);
  show(tl, id);
  captionIn(tl, id, s);
  tl.fromTo(q(id, '.lane'), {opacity: 0, y: 30}, {opacity: 1, y: 0, duration: 0.6, ease: 'expo.out'}, s.start + 0.4);
  // Each row is out of flow until it is said, so the panel grows instead of
  // showing empty space where the later lines will be.
  for (let i = 0; i < 3; i++) tl.set(q(id, `[data-el="row${i}"]`), {display: 'none'}, s.start);
  tl.set(q(id, '[data-el="count"]'), {opacity: 0}, s.start);
  [1.2, 3.4, 5.8].forEach((at, i) => {
    tl.set(q(id, `[data-el="row${i}"]`), {display: 'flex'}, s.start + at);
    tl.fromTo(q(id, `[data-el="row${i}"]`), {opacity: 0, y: 24}, {opacity: 1, y: 0, duration: 0.45, ease: 'expo.out'}, s.start + at);
    tl.set(q(id, '.row.latest'), {className: 'row'}, s.start + at);
    tl.set(q(id, `[data-el="row${i}"]`), {className: 'row latest'}, s.start + at);
  });
  tl.to(q(id, '[data-el="count"]'), {opacity: 1, duration: 0.3}, s.start + 6.2);
};

export function EndView({shot: s}) {
  return (
    <Paper>
      <div className="end-stage">
        <img src="assets/icon.png" alt="" />
        <div className="name"><Split text="Korgino" by="ch" lang="en" /></div>
        <div className="line"><Split text={s.headline} lang="zh-CN" /></div>
      </div>
    </Paper>
  );
}

export const buildEnd = id => tl => {
  const s = shot(id);
  show(tl, id);
  tl.fromTo(q(id, 'img'), {opacity: 0, scale: 0.8}, {opacity: 1, scale: 1, duration: 0.6, ease: 'expo.out'}, s.start + 0.3);
  reveal(tl, q(id, '.name'), s.start + 0.7, {from: {opacity: 0, y: 20}, dur: 0.5, stagger: 0.05});
  reveal(tl, q(id, '.line'), s.start + 1.3, {from: {opacity: 0, y: 16}, dur: 0.6, stagger: 0.04});
};
