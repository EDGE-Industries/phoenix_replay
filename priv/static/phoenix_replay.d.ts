/**
* What crosses the boundary with the server: the data the browser sends
* to Elixir and the data Elixir sends to the browser, each typed as the
* other side reads or writes it.
*
* Their keys are the server's, snake_case as Elixir has them, and are not
* converted: some payloads are keyed by data, such as the keys app code
* reports state under, form control names and CSS media features, which
* must arrive as written. So snake_case in this code means "on the wire";
* a module that uses such a field throughout takes it into a camelCase
* name where it reads it. The pointer's own track is in `pointer_track`.
*/
/**
* The browser's viewport, as PhoenixReplay records it: its size and pixel
* ratio, the screen's orientation angle, and the media settings the page's
* CSS can see. A setting the browser does not report is left out.
* Read by `PhoenixReplay.Capture.Browser`.
*/
interface ReplayViewport {
	width: number;
	height: number;
	dpr: number;
	/** `screen.orientation.angle`: 0, 90, 180 or 270. */
	angle?: number;
	color_scheme?: "light" | "dark";
	reduced_motion?: boolean;
	contrast?: "more" | "less" | "no-preference";
	pointer?: "coarse" | "fine" | "none";
	hover?: "hover" | "none";
}
/** What the server asks the browser to record; `null` records none. Sent by `PhoenixReplay.Recorder`. */
interface RecordSettings {
	pointer: PointerSettings | null;
	state: StateSettings | null;
}
/** The detail of `phx_replay:start`. */
interface StartDetail {
	state: StateSettings | null;
}
/** The pointer's settings; see the `:pointer` option and `PhoenixReplay.Capture.Pointer`. */
interface PointerSettings {
	/** Milliseconds between recorded positions of a pointer. */
	sample: number;
	/** Milliseconds between recorded scroll offsets. */
	scroll: number;
	/** Milliseconds between batches sent. */
	flush: number;
	/** Positions, presses and scrolls a batch holds before it is sent early. */
	max_points: number;
}
/** Client state's settings; see the `:state` option and `PhoenixReplay.Capture.State`. */
interface StateSettings {
	/** Milliseconds between batches sent. */
	flush: number;
	/** Entries a batch holds before it is sent early. */
	max_entries: number;
	/** Bytes a key may have. */
	max_key: number;
	/** The JSON size an entry's changes may have; larger ones are dropped. */
	max_entry_bytes: number;
	/** The JSON size a batch holds before it is sent early. */
	max_bytes: number;
	/** Whether the values of form controls are recorded. */
	inputs: boolean;
	/** Milliseconds a form control must stay unchanged before its value is recorded. */
	debounce: number;
}
/** Dispatched on `window` when recording starts. */
declare const START_EVENT = "phx_replay:start";
/** Dispatched on `window` when recording stops. */
declare const STOP_EVENT = "phx_replay:stop";
/** Set on `<html>` while recording, to the start detail as JSON. */
declare const RECORDING_ATTRIBUTE = "data-phx-replay";
/** The part of LiveSocket replayRecorder uses. */
interface RecorderSocket {
	execJS(el: Element, encodedJS: string, eventType?: string | null): void;
}
/**
* Records while a LiveView asks for it, and returns a function that stops
* listening altogether.
*/
declare const replayRecorder: (liveSocket: RecorderSocket, target?: Window) => (() => void);
/** The state key form control values are reported under. */
declare const INPUTS_KEY = "phx_replay:inputs";
/** Excludes an element and everything inside it from input capture. */
declare const IGNORE_ATTRIBUTE = "data-phx-replay-ignore";
/** The window event state is reported with. */
declare const STATE_EVENT = "phx_replay:state";
/** What a `phx_replay:state` event carries. */
interface StateReport {
	/** Names the state, such as a component's id. */
	key: string;
	/** A JSON object of fields to merge into the state reported under `key`. */
	changes: Record<string, unknown>;
}
type Changes = Record<string, unknown>;
/** Reports state under `key`: `changes` are merged into what it held. */
declare const replayState: (key: string, changes: Changes, target?: Window) => void;
/**
* Returns an id for this browser tab, kept in sessionStorage so it survives
* navigation and reloads within the tab. Returns an empty string when
* storage is unavailable.
*/
declare const tabId: () => string;
/** Connect params to merge into LiveSocket's `params`. */
declare const replayParams: () => {
	_replay: ReplayViewport & {
		tab: string;
	};
};
/**
* Event metadata for LiveSocket's `metadata` option. The viewport travels
* with each click and key press, so the recording follows resizes. Merge it
* into your own metadata functions if you have some.
*/
declare const replayMetadata: Record<"click" | "keydown" | "keyup", () => {
	_replay: ReplayViewport;
}>;
export { IGNORE_ATTRIBUTE, INPUTS_KEY, PointerSettings, RECORDING_ATTRIBUTE, RecordSettings, RecorderSocket, ReplayViewport, START_EVENT, STATE_EVENT, STOP_EVENT, StartDetail, StateReport, StateSettings, replayMetadata, replayParams, replayRecorder, replayState, tabId };
