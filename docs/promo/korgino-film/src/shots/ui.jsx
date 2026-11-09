import React from 'react';

// Rebuilt from Sources/Popup.swift: header with the language pair, the source well,
// one provider card. Drawn at 2x so 15px body text lands at 30px in the 1080p frame.
export function PopupPanel() {
  return (
    <div className="panel">
      <div className="panel-head">
        <span>中文</span><span className="arrow">→</span><span>English</span>
      </div>
      <div className="panel-src">明天下午三点，我们在会议室见。</div>
      <div className="panel-card">
        <div className="who"><span className="dot" />Apple</div>
        <div className="out">See you at the meeting room tomorrow at 3.</div>
      </div>
    </div>
  );
}

// Rebuilt from Sources/SelectionPlugins.swift: frosted capsule, one round button per
// plugin, a hairline, a dismiss mark, and the name drawn outside the bar.
// Filled shapes, not strokes: the headless renderer drops thin stroked paths.
const ICONS = {
  translate: 'M3 4.2h8.2v1.8H3zM6.2 4.2h1.8V15h3.4v1.8H4.4V4.2zM12.2 8.6h5v1.8h-5zM14.6 6.8l3.6 3.6-1.3 1.3-3.6-3.6z',
  polish: 'M13.6 3.2l3.2 3.2-9.4 9.4H4.2v-3.2z',
  explain: 'M10 3.2a4 4 0 0 1 2.2 7.3V12H8.6v-1.5A4 4 0 0 1 10 3.2zM8.8 14.2h2.4V16.6H8.8z',
};
function Glyph({d}) {
  return (
    <svg width="28" height="28" viewBox="0 0 20 20">
      <path d={d} fill="currentColor" />
    </svg>
  );
}
export function PluginBar() {
  return (
    <div>
      <div className="tip" data-el="tip">润色</div>
      <div className="bar">
        <div className="btn" data-el="b0"><Glyph d={ICONS.translate} /></div>
        <div className="btn on" data-el="b1"><Glyph d={ICONS.polish} /></div>
        <div className="btn" data-el="b2"><Glyph d={ICONS.explain} /></div>
        <div className="sep" />
        <div className="x"><Glyph d="M5.4 3.9l1.7-1.7L16.1 11.2l1.7 1.7-1.7 1.7L7.1 5.6zM16.1 3.9l1.7 1.7L7.1 16.3l-1.7-1.7L14.4 5.6z" /></div>
      </div>
      <div className="plugin-result" data-el="result">明天下午三点，我们在会议室见面。</div>
    </div>
  );
}

// Rebuilt from Sources/QuickOverlay.swift: a key cap, then the frosted capsule with
// level bars and the heard line.
export function VoiceCapsule() {
  return (
    <div>
      <div className="keycap" data-el="key">Fn</div>
      <div className="capsule" data-el="capsule">
        <span className="bars" data-el="bars">{[10, 18, 26, 16, 22].map((h, i) => <i key={i} style={{height: h}} />)}</span>
        <div className="col">
          <span data-el="label">在听 · 语音翻译</span>
          <span className="src" data-el="heard">See you tomorrow at three.</span>
          <span data-el="said">明天三点见。</span>
        </div>
      </div>
    </div>
  );
}

// Rebuilt from Sources/SystemAudioTranslate.swift laneTranscriptCard: a lane header and
// rows of stamp / speaker chip / source / translation. The latest row carries the tint.
const ROWS = [
  {stamp: '00:00:01,240', who: '说话人 1', src: "Let's start with the numbers.", dst: '我们先看数字。'},
  {stamp: '00:00:04,080', who: '说话人 2', src: 'Revenue is up twelve percent.', dst: '收入涨了百分之十二。'},
  {stamp: '00:00:07,960', who: '说话人 1', src: 'Good. What about next quarter?', dst: '很好。下个季度呢？'},
];
export function CaptionLane() {
  return (
    <div className="lane">
      <div className="lane-head">
        <span className="name">系统声音</span>
        <span className="sum">英语 → 中文</span>
        <span className="count" data-el="count">3 段</span>
      </div>
      {ROWS.map((r, i) => (
        <div className="row" data-el={'row' + i} key={i}>
          <div className="stamp">{r.stamp}</div>
          <div>
            <div className="who">{r.who}</div>
            <div className="src">{r.src}</div>
            <div className="dst">{r.dst}</div>
          </div>
        </div>
      ))}
    </div>
  );
}
