// Copied into packages/<pkg>/ by paseo-dev (git-excluded); see
// .agents/skills/paseo-dev/templates/. Skips upstream tests that conflict w/
// our patches, listed in dotfiles pkgs/paseo/tests/ignored.json. Fails any
// test file w/ an entry that matches no test (stale after an upgrade) or
// more than one (ambiguous), so an entry never silently skips the wrong test.
import path from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, beforeEach } from "vitest";
import ignored from "./vitest.paseo.ignored.json";

interface IgnoredTest {
  patch: string;
  // Relative to the package dir.
  file: string;
  // Full name: describe titles + test title, joined w/ " > ".
  test: string;
  reason: string;
}

interface TaskTree {
  type: string;
  name: string;
  tasks?: TaskTree[];
  suite?: TaskTree;
  // Only on the file suite, which is also `type: "suite"` in Vitest 4.
  filepath?: string;
}

const SEPARATOR = " > ";
const packageDir = path.dirname(fileURLToPath(import.meta.url));
let fileIgnores: IgnoredTest[] = [];

function isFileSuite(task: TaskTree): boolean {
  return task.filepath !== undefined;
}

// Full names of every test under a suite. The file suite's own name (its
// path) is not part of the name.
function testNames(task: TaskTree, prefix: string[] = []): string[] {
  if (task.type === "test") {
    return [[...prefix, task.name].join(SEPARATOR)];
  }
  const nested = isFileSuite(task) ? prefix : [...prefix, task.name];
  return (task.tasks ?? []).flatMap((child) => testNames(child, nested));
}

// Full name of a running test: walk up through enclosing describe suites,
// stopping at the file suite.
function fullName(task: TaskTree): string {
  const names = [task.name];
  for (let suite = task.suite; suite && !isFileSuite(suite); suite = suite.suite) {
    names.unshift(suite.name);
  }
  return names.join(SEPARATOR);
}

// Vitest 4 passes the file suite as the 2nd arg. It holds every collected
// test, incl. ones filtered out by `-t`, so these checks are reliable.
beforeAll(({}, suite) => {
  const file = suite as unknown as TaskTree & { filepath: string };
  const relative = path.relative(packageDir, file.filepath);
  fileIgnores = (ignored as IgnoredTest[]).filter((entry) => entry.file === relative);
  const names = testNames(file);
  const problems = fileIgnores.flatMap((entry) => {
    const matches = names.filter((name) => name === entry.test).length;
    if (matches === 1) {
      return [];
    }
    const kind = matches === 0 ? "stale (no such test)" : `ambiguous (${matches} tests)`;
    return [`"${entry.test}" (${entry.patch}): ${kind}`];
  });
  if (problems.length > 0) {
    throw new Error(
      `bad pkgs/paseo/tests/ignored.json entries in ${relative}: ${problems.join(", ")}`,
    );
  }
});

beforeEach((context) => {
  const name = fullName(context.task as unknown as TaskTree);
  const entry = fileIgnores.find((candidate) => candidate.test === name);
  if (entry) {
    context.skip(`${entry.patch}: ${entry.reason}`);
  }
});
