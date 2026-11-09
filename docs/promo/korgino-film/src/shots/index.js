// Map every plan.json shot id to a view and a builder. Builders receive the master timeline.
import {HookView, PopupView, PluginsView, VoiceView, CaptionsView, EndView, buildHook, buildPopup, buildPlugins, buildVoice, buildCaptions, buildEnd} from './korgino.jsx';
export const SHOT_VIEWS = {hook: HookView, popup: PopupView, plugins: PluginsView, voice: VoiceView, captions: CaptionsView, end: EndView};
export const SHOT_BUILDERS = {hook: buildHook('hook'), popup: buildPopup('popup'), plugins: buildPlugins('plugins'), voice: buildVoice('voice'), captions: buildCaptions('captions'), end: buildEnd('end')};
