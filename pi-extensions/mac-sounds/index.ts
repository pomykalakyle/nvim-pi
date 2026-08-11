import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const TINK_SOUND = "/System/Library/Sounds/Tink.aiff";

/**
 * Play one non-blocking Tink and suppress overlapping playback.
 * Reviewed: false.
 */
function createTinkPlayer(pi: ExtensionAPI): () => void {
  let playback: Promise<unknown> | undefined;

  return /** Reviewed: false. */ () => {
    if (playback) return;
    playback = pi
      .exec("/usr/bin/afplay", [TINK_SOUND])
      .catch(/** Reviewed: false. */ () => undefined)
      .finally(/** Reviewed: false. */ () => {
        playback = undefined;
      });
  };
}

/**
 * Play Tink when Pi finishes or presents a permission prompt.
 * Reviewed: false.
 */
export default function macSounds(pi: ExtensionAPI): void {
  const playTink = createTinkPlayer(pi);
  const stopPermissionListener = pi.events.on(
    "permissions:ui_prompt",
    playTink,
  );

  pi.on("agent_settled", playTink);
  pi.on("session_shutdown", stopPermissionListener);
}
