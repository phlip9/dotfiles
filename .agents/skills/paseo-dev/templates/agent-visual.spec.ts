// Agent visual check (scaffolded by `paseo-dev visual`). Git-excluded, never
// exported. Run: paseo-dev e2e e2e/browser/agent-<slug>.spec.ts
//
// Seeds a real repo + workspace on an isolated e2e daemon, drives the UI,
// and writes screenshots to $SHOTS_DIR (dotfiles tmp/paseo-shots) for the
// agent to Read. Assert the behavior too, so the run fails loudly.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { Locator, Page } from "@playwright/test";
import { test, expect } from "../support/fixtures";
import { openChangesTreePanel } from "../support/helpers/workspace-tabs";

const SLUG = path.basename(__filename).replace(/^agent-|\.spec\.ts$/g, "");
const SHOTS = process.env.SHOTS_DIR ?? "/tmp/paseo-shots";

// Desktop: the sidebar/workspace navigation in the e2e helpers needs it.
// Phone: phlip9 mostly uses paseo in a phone browser; compact layout is < md.
const DESKTOP = { width: 1400, height: 900 };
const PHONE = { width: 390, height: 844 };

async function shoot(page: Page, name: string): Promise<void> {
  await page.waitForTimeout(500); // let canvas/layout settle
  await page.screenshot({ path: `${SHOTS}/${SLUG}-${name}.png` });
}

// Element-level shot for alignment/detail checks. Zoom further w/:
// nix shell -f . pkgs.imagemagick --command magick in.png -filter point -resize 300% out.png
async function shootElement(locator: Locator, name: string): Promise<void> {
  await locator.screenshot({ path: `${SHOTS}/${SLUG}-${name}.png` });
}

// Commit on a feature branch so the Changes panel + commit list have content.
function seedRepo(repoPath: string, files: Record<string, string>, message: string): void {
  execFileSync("git", ["checkout", "-b", "feature"], { cwd: repoPath, stdio: "ignore" });
  for (const [file, content] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(repoPath, file)), { recursive: true });
    writeFileSync(path.join(repoPath, file), content);
  }
  execFileSync("git", ["add", "-A"], { cwd: repoPath, stdio: "ignore" });
  execFileSync("git", ["commit", "-m", message], { cwd: repoPath, stdio: "ignore" });
}

for (const [layout, viewport] of [
  ["desktop", DESKTOP],
  ["phone", PHONE],
] as const) {
  test(`${SLUG} ${layout}`, async ({ page, withWorkspace }) => {
    const workspace = await withWorkspace({ prefix: `agent-${SLUG}-${layout}-` });
    const body = Array.from({ length: 300 }, (_, index) => `line ${index}`).join("\n");
    seedRepo(workspace.repoPath, { "feature.txt": `${body}\n` }, "Add feature\n\nBody text.");

    await page.setViewportSize(DESKTOP);
    await workspace.navigateTo();

    // TODO: drive the UI to the feature under test. Find testIDs w/
    // `rg testID packages/app/src/<area>` and reuse helpers from
    // e2e/support/helpers (see existing specs in e2e/browser for flows).
    await openChangesTreePanel(page);

    await page.setViewportSize(viewport);
    await shoot(page, `${layout}-initial`);

    // TODO: assert the feature, e.g.
    // await expect(page.getByTestId("my-feature")).toBeInViewport();
    // Scroll a canvas diff: page.getByTestId("git-diff-scroll") and set
    // element.scrollTop via locator.evaluate.
    await expect(page.locator("body")).toBeVisible();
  });
}
