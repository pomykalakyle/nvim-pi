import { constants, type Stats } from "node:fs";
import {
  access,
  type FileHandle,
  open,
  readFile,
  realpath,
  stat,
} from "node:fs/promises";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import {
  createEditToolDefinition,
  type ExtensionContext,
  withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import type {
  PreviewEditInput,
  PreviewWriteInput,
  UnfoldedRange,
} from "./tools.js";

export type Proposal = {
  toolCallId: string;
  toolName: "edit" | "write";
  cwd: string;
  inputPath: string;
  filePath: string;
  mutationPath: string;
  existed: boolean;
  device?: number;
  inode?: number;
  parentDevice?: number;
  parentInode?: number;
  oldContent: string;
  newContent: string;
  justification: string;
  unfoldedRanges: UnfoldedRange[];
};

/**
 * Resolve a tool path against Pi's working directory.
 * Provenance: vibed=true, reviewed=false.
 */
export function absolutePath(cwd: string, path: string): string {
  return isAbsolute(path) ? resolve(path) : resolve(cwd, path);
}

/** Provenance: vibed=true, reviewed=false. */
function isMissingFile(error: unknown): boolean {
  return Boolean(
    error &&
      typeof error === "object" &&
      "code" in error &&
      error.code === "ENOENT",
  );
}

/**
 * Resolve existing symlinks while retaining a missing path suffix.
 * Provenance: vibed=true, reviewed=false.
 */
async function canonicalMutationPath(filePath: string): Promise<string> {
  let existing = filePath;
  const suffix: string[] = [];
  while (true) {
    try {
      return resolve(await realpath(existing), ...suffix);
    } catch (error) {
      if (!isMissingFile(error)) throw error;
      const parent = dirname(existing);
      if (parent === existing) throw error;
      suffix.unshift(basename(existing));
      existing = parent;
    }
  }
}

/**
 * Run Pi's real edit implementation while capturing its write in memory.
 * Provenance: vibed=true, reviewed=false.
 */
export async function buildEditProposal(
  toolCallId: string,
  input: PreviewEditInput,
  ctx: ExtensionContext,
): Promise<Proposal> {
  let oldContent: string | undefined;
  let newContent: string | undefined;
  const previewTool = createEditToolDefinition(ctx.cwd, {
    operations: {
      access: /** Provenance: vibed=true, reviewed=false. */ (path) => access(path, constants.R_OK | constants.W_OK),
      readFile: /** Provenance: vibed=true, reviewed=false. */ async (path) => {
        const content = await readFile(path);
        oldContent = content.toString("utf8");
        return content;
      },
      writeFile: /** Provenance: vibed=true, reviewed=false. */ async (_path, content) => {
        newContent = content;
      },
    },
  });

  await previewTool.execute(toolCallId, input, ctx.signal, undefined, ctx);
  if (oldContent === undefined || newContent === undefined) {
    throw new Error("Pi edit preview did not produce file contents");
  }

  const filePath = absolutePath(ctx.cwd, input.path);
  const mutationPath = await canonicalMutationPath(filePath);
  const identity = await stat(mutationPath);
  return {
    toolCallId,
    toolName: "edit",
    cwd: ctx.cwd,
    inputPath: input.path,
    filePath,
    mutationPath,
    existed: true,
    device: identity.dev,
    inode: identity.ino,
    oldContent,
    newContent,
    justification: input.justification,
    unfoldedRanges: input.unfolded_ranges,
  };
}

/**
 * Build a full-content write proposal from Pi's validated input.
 * Provenance: vibed=true, reviewed=false.
 */
export async function buildWriteProposal(
  toolCallId: string,
  input: PreviewWriteInput,
  cwd: string,
): Promise<Proposal> {
  const filePath = absolutePath(cwd, input.path);
  let oldContent = "";
  let existed = true;
  try {
    oldContent = await readFile(filePath, "utf8");
  } catch (error) {
    if (!isMissingFile(error)) throw error;
    existed = false;
  }

  let mutationPath: string;
  let identity: Stats | undefined;
  let parentIdentity: Stats | undefined;
  if (existed) {
    mutationPath = await canonicalMutationPath(filePath);
    identity = await stat(mutationPath);
  } else {
    let canonicalParent: string;
    try {
      canonicalParent = await realpath(dirname(filePath));
    } catch (error) {
      if (isMissingFile(error)) {
        throw new Error(
          `Cannot propose ${input.path} because its parent directory does not exist yet. Create the directory after resolving the current proposal, then retry.`,
        );
      }
      throw error;
    }
    mutationPath = resolve(canonicalParent, basename(filePath));
    parentIdentity = await stat(canonicalParent);
  }
  return {
    toolCallId,
    toolName: "write",
    cwd,
    inputPath: input.path,
    filePath,
    mutationPath,
    existed,
    device: identity?.dev,
    inode: identity?.ino,
    parentDevice: parentIdentity?.dev,
    parentInode: parentIdentity?.ino,
    oldContent,
    newContent: input.content,
    justification: input.justification,
    unfoldedRanges: input.unfolded_ranges,
  };
}

/**
 * Apply exactly the reviewed snapshot, failing if the target changed meanwhile.
 * Provenance: vibed=true, reviewed=false.
 */
export async function applyProposal(proposal: Proposal): Promise<void> {
  await withFileMutationQueue(proposal.mutationPath, /** Provenance: vibed=true, reviewed=false. */ async () => {
    const currentTarget = await canonicalMutationPath(proposal.filePath);
    if (currentTarget !== proposal.mutationPath) {
      throw new Error(
        `Cannot accept the proposal because ${proposal.inputPath} now resolves to a different file. Ask the model to revise it against the current file.`,
      );
    }

    if (!proposal.existed) {
      let parentHandle: FileHandle | undefined;
      let handle: FileHandle | undefined;
      try {
        parentHandle = await open(
          dirname(proposal.mutationPath),
          constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
        );
        const parentIdentity = await parentHandle.stat();
        if (
          parentIdentity.dev !== proposal.parentDevice ||
          parentIdentity.ino !== proposal.parentInode
        ) {
          throw new Error("parent identity changed");
        }
        handle = await open(
          proposal.mutationPath,
          constants.O_CREAT |
            constants.O_EXCL |
            constants.O_WRONLY |
            constants.O_NOFOLLOW,
          0o666,
        );
        await handle.writeFile(proposal.newContent, "utf8");
        await handle.sync();
      } catch (error) {
        throw new Error(
          `Cannot accept the proposal because ${proposal.inputPath} changed after it was proposed. Ask the model to revise it against the current file.`,
          { cause: error },
        );
      } finally {
        await handle?.close();
        await parentHandle?.close();
      }
      return;
    }

    const handle = await open(
      proposal.mutationPath,
      constants.O_RDWR | constants.O_NOFOLLOW,
    );
    try {
      const identity = await handle.stat();
      const currentContent = await handle.readFile("utf8");
      if (
        identity.dev !== proposal.device ||
        identity.ino !== proposal.inode ||
        currentContent !== proposal.oldContent
      ) {
        throw new Error(
          `Cannot accept the proposal because ${proposal.inputPath} changed after it was proposed. Ask the model to revise it against the current file.`,
        );
      }
      await handle.truncate(0);
      if (proposal.newContent.length > 0) {
        await handle.write(proposal.newContent, 0, "utf8");
      }
      await handle.sync();
    } finally {
      await handle.close();
    }
  });
}
