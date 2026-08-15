import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "../..");

test("repository contains the production documentation contract", () => {
    assert.equal(existsSync(resolve(root, "README.md")), true);
    assert.equal(existsSync(resolve(root, "SECURITY.md")), true);
    assert.equal(existsSync(resolve(root, "assets/banner.png")), true);
    assert.deepEqual(readdirSync(resolve(root, "docs")).sort(), [
        "architecture.md",
        "economic-model.md",
        "governance.md",
        "operations.md",
        "portfolio-risk.md",
        "runbooks.md",
        "sdk.md",
    ]);
});

test("release version is synchronized across metadata", () => {
    const packageJson = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"));
    assert.equal(packageJson.version, "1.0.0");
    assert.match(readFileSync(resolve(root, "README.md"), "utf8"), /Production 1\.0\.0/);
    assert.equal(existsSync(resolve(root, ".github/workflows/release-integrity.yml")), true);
});

test("repository verifier accepts the public tree", () => {
    const result = spawnSync(process.execPath, ["scripts/verify-repository.mjs"], {
        cwd: root,
        encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /Repository contract verified/);
});
