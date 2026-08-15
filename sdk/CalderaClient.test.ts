import assert from "node:assert/strict";
import test from "node:test";

import {
    CalderaClient,
    CalderaClientError,
    atomic,
    coverageBps,
    deriveIdempotencyKey,
    maximumCollateral,
    optionPayout,
    type CalderaTransport,
    type TransportRequest,
} from "./CalderaClient.js";

const DIGEST = "a".repeat(64);
const WAD = 10n ** 18n;

class StubTransport implements CalderaTransport {
    readonly requests: TransportRequest[] = [];

    constructor(private readonly responses: unknown[]) {}

    async execute<T>(request: TransportRequest): Promise<T> {
        this.requests.push(request);
        const response = this.responses.shift();
        if (response === undefined) throw new Error("No stub response configured.");
        return response as T;
    }
}

test("client validates health before returning state", async () => {
    const transport = new StubTransport([
        { status: "ok", version: "1.0.0", chainId: "31337", stateDigest: DIGEST },
    ]);
    const health = await new CalderaClient(transport).requireHealthy();

    assert.equal(health.version, "1.0.0");
    assert.deepEqual(transport.requests[0], { method: "GET", path: "/v1/health" });
});

test("series endpoint encodes identifiers and validates financial fields", async () => {
    const transport = new StubTransport([
        {
            seriesId: "series:eth-call",
            optionType: "call",
            collateralAsset: "0x0000000000000000000000000000000000000001",
            strikePriceX18: atomic(2_000n * WAD),
            capPriceX18: atomic(3_000n * WAD),
            collateralPerContract: atomic(1_000_000_000n),
            writtenContracts: "10",
            soldContracts: "7",
            expiry: "1800604800",
            phase: "funding",
        },
    ]);
    const series = await new CalderaClient(transport).series("series:eth-call");

    assert.equal(series.soldContracts, "7");
    assert.equal(transport.requests[0]?.path, "/v1/series/series%3Aeth-call");
});

test("write operation carries a stable idempotency key", async () => {
    const transport = new StubTransport([
        { operationId: "op:writer-1", status: "accepted", stateDigest: DIGEST, amount: "1000" },
    ]);
    const client = new CalderaClient(transport);
    const intent = {
        account: "account:writer",
        seriesId: "series:eth-call",
        contracts: "2",
        recipient: "account:writer",
        maximumCollateral: "2000000000",
    } as const;
    const key = deriveIdempotencyKey("write:2026-08-15", intent);
    const result = await client.write(intent, key);

    assert.equal(result.amount, "1000");
    assert.equal(transport.requests[0]?.idempotencyKey, key);
    assert.equal(transport.requests[0]?.path, "/v1/writer-positions");
});

test("client fails closed on malformed operation response", async () => {
    const transport = new StubTransport([
        { operationId: "op:1", status: "unknown", stateDigest: DIGEST },
    ]);
    const client = new CalderaClient(transport);

    await assert.rejects(
        client.processExercise("account:keeper", "request:1", "process:1234567890"),
        (error: unknown) =>
            error instanceof CalderaClientError && error.code === "INVALID_RESPONSE",
    );
});

test("call payout is capped and preserves atomic precision", () => {
    const payout = optionPayout(
        "call",
        atomic(3_500n * WAD),
        atomic(2_000n * WAD),
        atomic(3_000n * WAD),
        atomic(WAD),
        "2",
        6,
    );

    assert.equal(payout, "2000000000");
});

test("put payout floors at zero and scales collateral decimals", () => {
    assert.equal(
        optionPayout("put", atomic(2_500n * WAD), atomic(2_000n * WAD), "0", atomic(WAD), "3", 6),
        "0",
    );
    assert.equal(
        optionPayout("put", atomic(1_500n * WAD), atomic(2_000n * WAD), "0", atomic(WAD), "3", 6),
        "1500000000",
    );
});

test("maximum collateral rounds upward before multiplying contracts", () => {
    const collateral = maximumCollateral(
        "call",
        "2000000000000000000001",
        "3000000000000000000000",
        atomic(WAD),
        "2",
        6,
    );

    assert.equal(collateral, "2000000000");
});

test("atomic rejects unsafe numbers", () => {
    assert.throws(
        () => atomic(Number.MAX_SAFE_INTEGER + 1),
        (error: unknown) => error instanceof CalderaClientError && error.code === "INVALID_AMOUNT",
    );
});

test("coverage uses deterministic integer basis points", () => {
    assert.equal(coverageBps("1124000", "1020000"), "11019");
    assert.equal(coverageBps("0", "0"), "20000");
});
