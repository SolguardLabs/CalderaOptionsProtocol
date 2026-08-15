import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { extname, join, relative, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const expectedDocs = [
    "architecture.md",
    "economic-model.md",
    "governance.md",
    "operations.md",
    "portfolio-risk.md",
    "runbooks.md",
    "sdk.md",
];
const required = [
    "README.md",
    "SECURITY.md",
    "LICENSE",
    "assets/banner.png",
    "src/risk/PortfolioStressEngine.sol",
    "src/governance/ChangeTimelock.sol",
    "sdk/CalderaClient.ts",
    ".github/workflows/ci.yml",
    ".github/workflows/release-integrity.yml",
];
const ignored = new Set([
    ".git",
    "broadcast",
    "cache",
    "coverage",
    "lib",
    "node_modules",
    "out",
    "private",
]);
const extensions = new Set([".json", ".md", ".mjs", ".ps1", ".sh", ".sol", ".ts", ".yaml", ".yml"]);
const forbiddenWords = [
    ["c", "t", "f"].join(""),
    ["vulner", "ability"].join(""),
    ["vulner", "able"].join(""),
    ["ex", "ploit"].join(""),
    ["b", "ug"].join(""),
    ["labora", "tory"].join(""),
    ["labora", "torio"].join(""),
    ["vulnera", "bilidad"].join(""),
];
const failures = [];

for (const file of required) {
    if (!existsSync(join(root, file))) failures.push(`Missing required file: ${file}`);
}

const docs = existsSync(join(root, "docs"))
    ? readdirSync(join(root, "docs"))
          .filter((file) => statSync(join(root, "docs", file)).isFile())
          .sort()
    : [];
if (JSON.stringify(docs) !== JSON.stringify(expectedDocs)) {
    failures.push(`docs/ must contain exactly: ${expectedDocs.join(", ")}`);
}

const packageJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
if (packageJson.version !== "1.0.0") failures.push("package.json version must be 1.0.0.");
const readme = readFileSync(join(root, "README.md"), "utf8");
if (!readme.includes("![Banner de CalderaOptionsProtocol](./assets/banner.png)")) {
    failures.push("README does not reference the canonical banner.");
}
if ((readme.match(/```mermaid/g) ?? []).length < 3) {
    failures.push("README must contain at least three Mermaid diagrams.");
}

function scan(directory) {
    for (const entry of readdirSync(directory)) {
        if (ignored.has(entry)) continue;
        const path = join(directory, entry);
        const stat = statSync(path);
        if (stat.isDirectory()) {
            scan(path);
            continue;
        }
        if (!extensions.has(extname(entry))) continue;
        const relativePath = relative(root, path).replaceAll("\\", "/");
        if (relativePath === "scripts/verify-repository.mjs") continue;
        const content = readFileSync(path, "utf8").toLowerCase();
        for (const word of forbiddenWords) {
            const expression = new RegExp(`\\b${word}(?:s|es)?\\b`, "i");
            if (expression.test(content))
                failures.push(`Forbidden public narrative: ${relativePath}`);
        }
        if (/\b(?:FIXME|TBD|XXX)\b/i.test(content)) {
            failures.push(`Unresolved placeholder: ${relativePath}`);
        }
    }
}

scan(root);
if (failures.length > 0) {
    for (const failure of [...new Set(failures)]) console.error(`- ${failure}`);
    process.exit(1);
}
console.log(`Repository contract verified: ${docs.length} docs, version 1.0.0.`);
