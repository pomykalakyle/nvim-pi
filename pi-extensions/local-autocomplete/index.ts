// Provides lightweight local completions for Pi's prompt editor.
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import {
  CustomEditor,
  type ExtensionAPI,
  type ExtensionContext,
  type KeybindingsManager,
} from "@earendil-works/pi-coding-agent";
import {
  CURSOR_MARKER,
  matchesKey,
  truncateToWidth,
  visibleWidth,
  type EditorTheme,
  type TUI,
} from "@earendil-works/pi-tui";

const OLLAMA_URL = "http://127.0.0.1:11434/v1/chat/completions";
const LOCAL_MODEL = "gemma4:e4b";
const INCEPTION_URL = "https://api.inceptionlabs.ai/v1/chat/completions";
const REMOTE_MODEL = "mercury-2";
const DEBOUNCE_MS = 200;
const SYSTEM_PROMPT = `Autocomplete the unfinished message the user is typing to a coding agent. Output only the exact continuation, never an answer or reaction. Use two to four words. Four words is an absolute maximum. The draft plus your output must form one logical, grammatical thought. Match the user's casual style and current topic. If the final word is partial, output only the characters that finish it. Otherwise start a new word. Do not repeat the draft, invent details, use markdown, or explain.

Examples:
<draft>Could you upd</draft> -> ate the settings
<draft>We should inspect the</draft> -> request handling
<draft>the problem appeared</draft> -> after the reload
<draft>Can you tell me how</draft> -> the cache works
<draft>Everything works now.</draft> ->

Never copy the arrow or draft tags into your output.`;
const BACKGROUND_INTRO =
  "Background, for reference only — never reply to it:";
const DRAFT_INTRO =
  "The user's unfinished draft is between <draft> and </draft>. The cursor is at the very end of it.";
const DRAFT_INSTRUCTION =
  "Write only the characters that come next, continuing the draft from the cursor. Do not answer or react to anything inside <draft>.";
const MAX_CONTEXT_MESSAGES = 2;
const MAX_CONTEXT_CHARS = 280;
const LOCAL_GHOST_STYLE = "\x1b[2m";
// NERV magenta (#8a5a8a), dimmed but distinct from the local gray ghost.
const REMOTE_GHOST_STYLE = "\x1b[2;38;2;138;90;138m";
const GHOST_STYLE_RESET = "\x1b[22;39m";

type CompletionProvider = "local" | "remote";
type CompletionOutcome =
  | "accepted"
  | "keypress"
  | "replaced"
  | "disposed";

type CompletionRequest = {
  id: string;
  text: string;
  keypressAt: number;
  local: AbortController;
  remote: AbortController;
  remoteApplied: boolean;
};

type VisibleSuggestion = {
  requestId: string;
  input: string;
  provider: CompletionProvider;
  suggestion: string;
  shownAt: number;
};

let requestSequence = 0;

/** Append ordered events to an ignored, project-local JSONL file. */
class EventLogger {
  private readonly path: string | undefined;

  /** Reviewed: false. */
  constructor(filename: string) {
    try {
      const directory = join(process.cwd(), ".pi", "local-autocomplete");
      mkdirSync(directory, { recursive: true });
      this.path = join(directory, filename);
    } catch {
      this.path = undefined;
    }
  }

  /** Reviewed: false. */
  log(event: Record<string, unknown>): void {
    if (!this.path) return;

    try {
      appendFileSync(this.path, `${JSON.stringify(event)}\n`, "utf8");
    } catch {
      // Logging must never interrupt prompt editing.
    }
  }
}

/** Extract plain text from one Pi user or assistant message.  * Reviewed: false.
 */
function messageText(message: unknown): string {
  if (!message || typeof message !== "object" || !("content" in message)) {
    return "";
  }

  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";

  return content
    .filter(
      /** Reviewed: false. */ (part): part is { type: "text"; text: string } =>
        !!part &&
        typeof part === "object" &&
        "type" in part &&
        part.type === "text" &&
        "text" in part &&
        typeof part.text === "string",
    )
    .map(/** Reviewed: false. */ (part) => part.text)
    .join("");
}

/**
 * Build a small background block from the latest conversation messages.
 * Reviewed: false.
 */
function recentBackground(ctx: ExtensionContext): string {
  let branch: unknown[];
  try {
    branch = ctx.sessionManager.getBranch() as unknown[];
  } catch {
    return "";
  }

  const messages: string[] = [];
  for (let index = branch.length - 1; index >= 0; index -= 1) {
    const entry = branch[index];
    if (!entry || typeof entry !== "object" || !("message" in entry)) continue;

    const message = entry.message;
    if (!message || typeof message !== "object" || !("role" in message)) {
      continue;
    }
    if (message.role !== "user" && message.role !== "assistant") continue;

    // Normalize multiline history so each role occupies one compact prompt line.
    const text = messageText(message).replace(/\s+/g, " ").trim();
    if (!text) continue;
    messages.unshift(`${message.role}: ${text.slice(0, MAX_CONTEXT_CHARS)}`);
    if (messages.length === MAX_CONTEXT_MESSAGES) break;
  }

  return messages.length > 0
    ? `${BACKGROUND_INTRO}\n${messages.join("\n")}\n\n`
    : "";
}

/** Add lightweight local ghost completions to Pi's normal prompt editor. */
class LocalAutocompleteEditor extends CustomEditor {
  private readonly tuiRef: TUI;
  private readonly extensionContext: ExtensionContext;
  private readonly completionLogger = new EventLogger("completions.jsonl");
  private readonly typingLogger = new EventLogger("typing.jsonl");
  private previousTextChangeAt: number | undefined;
  private ghostText: string | undefined;
  private ghostForText = "";
  private ghostSource: CompletionProvider | undefined;
  private visibleSuggestion: VisibleSuggestion | undefined;
  private debounceTimer: ReturnType<typeof setTimeout> | undefined;
  private request: CompletionRequest | undefined;

  /** Reviewed: false. */
  constructor(
    tui: TUI,
    theme: EditorTheme,
    keybindings: KeybindingsManager,
    extensionContext: ExtensionContext,
  ) {
    super(tui, theme, keybindings);
    this.tuiRef = tui;
    this.extensionContext = extensionContext;
  }

  /** Handle Tab acceptance, then let Pi perform ordinary editing. */
  /** Reviewed: false. */
  override handleInput(data: string): void {
    const inputAt = Date.now();

    // Ghost acceptance takes precedence only when Pi's own popup is closed.
    if (
      matchesKey(data, "tab") &&
      this.ghostText &&
      !this.isShowingAutocomplete() &&
      this.cursorAtEnd()
    ) {
      this.acceptNextWord();
      return;
    }

    const before = this.getText();
    this.clearCompletion("keypress");

    // Pi remains responsible for normal editing, submission, and keybindings.
    super.handleInput(data);
    const after = this.getText();

    if (after !== before) {
      this.logTypingChange(before, after, inputAt);
      this.scheduleCompletion(after, inputAt);
    }
  }

  /** Decorate Pi's rendered cursor line with dim completion text. */
  /** Reviewed: false. */
  override render(width: number): string[] {
    const lines = super.render(width);
    if (
      !this.ghostText ||
      this.getText() !== this.ghostForText ||
      this.isShowingAutocomplete() ||
      !this.cursorAtEnd()
    ) {
      return lines;
    }

    const ghost = this.ghostText.split("\n", 1)[0] ?? "";
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      const markerAt = line?.indexOf(CURSOR_MARKER) ?? -1;
      if (!line || markerAt < 0) continue;

      // Pi's zero-width marker is both our insertion point and its cursor anchor.
      const beforeMarker = line.slice(0, markerAt + CURSOR_MARKER.length);
      const afterMarker = line.slice(markerAt + CURSOR_MARKER.length);
      const available = width - visibleWidth(line.slice(0, markerAt)) - 2;
      const visibleGhost = truncateToWidth(ghost, Math.max(0, available), "");
      if (!visibleGhost) return lines;

      // Preserve Pi's normal cursor and padding after the inserted decoration.
      const ghostStyle =
        this.ghostSource === "remote"
          ? REMOTE_GHOST_STYLE
          : LOCAL_GHOST_STYLE;
      lines[index] = truncateToWidth(
        `${beforeMarker}${ghostStyle}${visibleGhost}${GHOST_STYLE_RESET}${afterMarker}`,
        width,
        "",
      );
      break;
    }

    return lines;
  }

  /** Stop timers and network work when Pi replaces this editor. */
  /** Reviewed: false. */
  dispose(): void {
    this.clearCompletion("disposed");
  }

  /** Return whether the cursor is after the final character in the draft. */
  /** Reviewed: false. */
  private cursorAtEnd(): boolean {
    const cursor = this.getCursor();
    const lines = this.getText().split("\n");
    return (
      cursor.line === lines.length - 1 &&
      cursor.col === (lines[cursor.line]?.length ?? 0)
    );
  }

  /** Clear visible, scheduled, and in-flight completion state. */
  /** Reviewed: false. */
  private clearCompletion(
    reason: Exclude<CompletionOutcome, "accepted" | "replaced">,
  ): void {
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = undefined;
    this.finishVisibleSuggestion(false, reason);
    this.cancelRequests();
    this.ghostText = undefined;
    this.ghostForText = "";
    this.ghostSource = undefined;
  }

  /** Record timing and size for one user-authored text change. */
  /** Reviewed: false. */
  private logTypingChange(before: string, after: string, inputAt: number): void {
    let prefixLength = 0;
    const sharedLength = Math.min(before.length, after.length);
    while (
      prefixLength < sharedLength &&
      before[prefixLength] === after[prefixLength]
    ) {
      prefixLength += 1;
    }

    let suffixLength = 0;
    const remainingBefore = before.length - prefixLength;
    const remainingAfter = after.length - prefixLength;
    while (
      suffixLength < remainingBefore &&
      suffixLength < remainingAfter &&
      before[before.length - suffixLength - 1] ===
        after[after.length - suffixLength - 1]
    ) {
      suffixLength += 1;
    }

    const addedChars = after.length - prefixLength - suffixLength;
    const removedChars = before.length - prefixLength - suffixLength;
    const intervalMs =
      this.previousTextChangeAt === undefined
        ? undefined
        : inputAt - this.previousTextChangeAt;
    this.previousTextChangeAt = inputAt;

    this.typingLogger.log({
      ts: inputAt,
      event: "text-change",
      intervalMs,
      editKind:
        addedChars > 0 && removedChars > 0
          ? "replacement"
          : addedChars > 0
            ? "insertion"
            : "deletion",
      addedChars,
      removedChars,
      inputLength: after.length,
      singleCharacterEdit: addedChars + removedChars === 1,
    });
  }

  /** Debounce a completion request for the current draft. */
  /** Reviewed: false. */
  private scheduleCompletion(text: string, keypressAt: number): void {
    // The first version only predicts after meaningful text at the draft's end.
    if (!this.cursorAtEnd() || text.trim().length < 3) return;

    this.debounceTimer = setTimeout(/** Reviewed: false. */ () => {
      this.debounceTimer = undefined;
      this.startCompletion(text, keypressAt);
    }, DEBOUNCE_MS);
  }

  /** Launch local and remote predictions for the same draft snapshot. */
  /** Reviewed: false. */
  private startCompletion(text: string, keypressAt: number): void {
    if (this.getText() !== text || !this.cursorAtEnd()) return;

    const request: CompletionRequest = {
      id: `${Date.now().toString(36)}-${process.pid}-${++requestSequence}`,
      text,
      keypressAt,
      local: new AbortController(),
      remote: new AbortController(),
      remoteApplied: false,
    };
    this.request = request;

    const draftTail = text.slice(-400);
    const background = recentBackground(this.extensionContext);
    const userPrompt = `${background}${DRAFT_INTRO}\n<draft>${draftTail}</draft>\n\n${DRAFT_INSTRUCTION}`;

    void this.fetchLocalCompletion(request, userPrompt);
    void this.fetchRemoteCompletion(request, userPrompt);
  }

  /** Fetch the quick local prediction, which remains provisional until remote finishes. */
  /** Reviewed: false. */
  private async fetchLocalCompletion(
    request: CompletionRequest,
    userPrompt: string,
  ): Promise<void> {
    try {
      const response = await fetch(OLLAMA_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: LOCAL_MODEL,
          stream: false,
          temperature: 0.2,
          max_tokens: 64,
          reasoning_effort: "none",
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: userPrompt },
          ],
        }),
        signal: request.local.signal,
      });
      if (!response.ok) return;

      const result = (await response.json()) as {
        choices?: Array<{ message?: { content?: string } }>;
      };
      this.applyCompletion(
        request,
        "local",
        result.choices?.[0]?.message?.content ?? "",
      );
    } catch {
      // Autocomplete failures are intentionally silent.
    }
  }

  /** Fetch the preferred remote prediction and replace a provisional local ghost. */
  /** Reviewed: false. */
  private async fetchRemoteCompletion(
    request: CompletionRequest,
    userPrompt: string,
  ): Promise<void> {
    const apiKey = process.env.INCEPTION_API_KEY;
    if (!apiKey) return;

    try {
      const response = await fetch(INCEPTION_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: REMOTE_MODEL,
          stream: false,
          temperature: 0.75,
          max_tokens: 1024,
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: userPrompt },
          ],
        }),
        signal: request.remote.signal,
      });
      if (!response.ok) return;

      const result = (await response.json()) as {
        choices?: Array<{ message?: { content?: string | null } }>;
      };
      this.applyCompletion(
        request,
        "remote",
        result.choices?.[0]?.message?.content ?? "",
      );
    } catch {
      // Keep the local completion when the remote provider is unavailable.
    }
  }

  /** Apply a current result while preventing local from overwriting remote. */
  /** Reviewed: false. */
  private applyCompletion(
    request: CompletionRequest,
    source: CompletionProvider,
    rawCompletion: string,
  ): void {
    const completion = this.cleanCompletion(rawCompletion);
    if (!completion) return;

    const receivedAt = Date.now();
    const displayed =
      this.request === request &&
      this.getText() === request.text &&
      this.cursorAtEnd() &&
      !(source === "local" && request.remoteApplied);
    this.completionLogger.log({
      ts: receivedAt,
      event: "suggestion",
      requestId: request.id,
      input: request.text,
      provider: source,
      suggestion: completion,
      latencyMs: receivedAt - request.keypressAt,
      debounceMs: DEBOUNCE_MS,
      displayed,
    });
    if (!displayed) return;

    if (source === "remote") {
      request.remoteApplied = true;
      request.local.abort();
    }
    this.finishVisibleSuggestion(false, "replaced");
    this.ghostText = completion;
    this.ghostForText = request.text;
    this.ghostSource = source;
    this.visibleSuggestion = {
      requestId: request.id,
      input: request.text,
      provider: source,
      suggestion: completion,
      shownAt: receivedAt,
    };

    // Network results arrive outside Pi's automatic keypress render cycle.
    this.tuiRef.requestRender();
  }

  /** Record how the visible suggestion ended before replacing or clearing it. */
  /** Reviewed: false. */
  private finishVisibleSuggestion(
    firstWordAccepted: boolean,
    outcome: CompletionOutcome,
  ): void {
    const suggestion = this.visibleSuggestion;
    if (!suggestion) return;

    const finishedAt = Date.now();
    this.completionLogger.log({
      ts: finishedAt,
      event: "outcome",
      requestId: suggestion.requestId,
      input: suggestion.input,
      provider: suggestion.provider,
      suggestion: suggestion.suggestion,
      firstWordAccepted,
      outcome,
      displayDurationMs: finishedAt - suggestion.shownAt,
    });
    this.visibleSuggestion = undefined;
  }

  /** Cancel both providers without changing an already-rendered ghost. */
  /** Reviewed: false. */
  private cancelRequests(): void {
    this.request?.local.abort();
    this.request?.remote.abort();
    this.request = undefined;
  }

  /** Reduce model output to one short literal suffix. */
  /** Reviewed: false. */
  private cleanCompletion(text: string): string {
    // Keep meaningful boundary whitespace while dropping multiline output.
    let completion = text.replace(/\r/g, "");
    completion = completion.split("\n", 1)[0]?.replace(/\s+$/, "") ?? "";
    const quoted = completion.match(/^(["'`])(.*)\1$/);
    if (quoted) completion = quoted[2] ?? "";
    return completion.slice(0, 160);
  }

  /** Insert the next whitespace-delimited unit and retain the remainder. */
  /** Reviewed: false. */
  private acceptNextWord(): void {
    if (!this.ghostText) return;

    // A response for the pre-acceptance draft must not replace the remainder.
    this.cancelRequests();

    // Include surrounding whitespace so repeated Tab presses remain natural.
    const chunk = this.ghostText.match(/^\s*\S+\s*/)?.[0] ?? this.ghostText;
    const remaining = this.ghostText.slice(chunk.length);

    // Only this insertion changes the real prompt; rendering never does.
    this.insertTextAtCursor(chunk);
    this.finishVisibleSuggestion(true, "accepted");
    if (remaining) {
      this.ghostText = remaining;
      this.ghostForText = this.getText();
    } else {
      this.ghostText = undefined;
      this.ghostForText = "";
      this.ghostSource = undefined;
    }
    this.tuiRef.requestRender();
  }
}

/** Install the local autocomplete editor for interactive Pi sessions.  * Reviewed: false.
 */
export default function localAutocomplete(pi: ExtensionAPI): void {
  let editor: LocalAutocompleteEditor | undefined;

  pi.on("session_start", /** Reviewed: false. */ (_event, ctx) => {
    if (!ctx.hasUI) return;

    // Pi invokes this factory whenever it needs the interactive prompt editor.
    ctx.ui.setEditorComponent(/** Reviewed: false. */ (tui, theme, keybindings) => {
      editor?.dispose();
      editor = new LocalAutocompleteEditor(tui, theme, keybindings, ctx);
      return editor;
    });
  });

  pi.on("session_shutdown", /** Reviewed: false. */ () => {
    editor?.dispose();
    editor = undefined;
  });
}
