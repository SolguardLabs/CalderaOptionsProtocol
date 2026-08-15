import { createHash } from "node:crypto";

const ATOMIC = /^(0|[1-9][0-9]*)$/;
const IDENTIFIER = /^[a-zA-Z0-9][a-zA-Z0-9:_-]{1,95}$/;
const WAD = 10n ** 18n;
const BPS = 10_000n;

export type AtomicAmount = string;
export type OptionType = "call" | "put";

export interface HealthResponse {
    readonly status: "ok" | "degraded" | "halted";
    readonly version: string;
    readonly chainId: string;
    readonly stateDigest: string;
}

export interface SeriesResponse {
    readonly seriesId: string;
    readonly optionType: OptionType;
    readonly collateralAsset: string;
    readonly strikePriceX18: AtomicAmount;
    readonly capPriceX18: AtomicAmount;
    readonly collateralPerContract: AtomicAmount;
    readonly writtenContracts: AtomicAmount;
    readonly soldContracts: AtomicAmount;
    readonly expiry: string;
    readonly phase: "scheduled" | "funding" | "exercise" | "expired";
}

export interface QuoteResponse {
    readonly seriesId: string;
    readonly contracts: AtomicAmount;
    readonly premiumPerContract: AtomicAmount;
    readonly totalPremium: AtomicAmount;
    readonly feeAmount: AtomicAmount;
    readonly expiresAt: string;
    readonly stateDigest: string;
}

export interface TransactionIntent {
    readonly account: string;
    readonly seriesId: string;
    readonly contracts: AtomicAmount;
    readonly recipient: string;
}

export interface WriteIntent extends TransactionIntent {
    readonly maximumCollateral: AtomicAmount;
}

export interface BuyIntent extends TransactionIntent {
    readonly maximumPremium: AtomicAmount;
}

export interface ExerciseIntent extends TransactionIntent {
    readonly minimumPayout: AtomicAmount;
}

export interface OperationResponse {
    readonly operationId: string;
    readonly status: "accepted" | "queued" | "confirmed";
    readonly transactionHash?: string;
    readonly amount?: AtomicAmount;
    readonly stateDigest: string;
}

export interface TransportRequest {
    readonly method: "GET" | "POST";
    readonly path: string;
    readonly body?: unknown;
    readonly idempotencyKey?: string;
}

export interface CalderaTransport {
    execute<T>(request: TransportRequest): Promise<T>;
}

export interface HttpTransportOptions {
    readonly baseUrl: string;
    readonly apiKey?: string;
    readonly timeoutMs?: number;
    readonly fetch?: typeof globalThis.fetch;
}

export class CalderaClientError extends Error {
    constructor(
        readonly code: string,
        message: string,
        readonly status?: number,
        readonly detail?: unknown,
    ) {
        super(message);
        this.name = "CalderaClientError";
    }
}

export class HttpCalderaTransport implements CalderaTransport {
    readonly #baseUrl: URL;
    readonly #apiKey: string | undefined;
    readonly #timeoutMs: number;
    readonly #fetch: typeof globalThis.fetch;

    constructor(options: HttpTransportOptions) {
        try {
            this.#baseUrl = new URL(options.baseUrl);
        } catch {
            throw new CalderaClientError("INVALID_BASE_URL", "The base URL is invalid.");
        }
        if (!["https:", "http:"].includes(this.#baseUrl.protocol)) {
            throw new CalderaClientError(
                "INVALID_BASE_URL",
                "The base URL must use HTTP or HTTPS.",
            );
        }
        this.#apiKey = options.apiKey;
        this.#timeoutMs = options.timeoutMs ?? 10_000;
        this.#fetch = options.fetch ?? globalThis.fetch;
        if (!Number.isInteger(this.#timeoutMs) || this.#timeoutMs <= 0) {
            throw new CalderaClientError("INVALID_TIMEOUT", "The timeout must be positive.");
        }
    }

    async execute<T>(request: TransportRequest): Promise<T> {
        const url = new URL(request.path.replace(/^\/+/, ""), this.#baseUrl);
        const headers = new Headers({ accept: "application/json" });
        if (request.body !== undefined) headers.set("content-type", "application/json");
        if (this.#apiKey !== undefined) headers.set("authorization", `Bearer ${this.#apiKey}`);
        if (request.idempotencyKey !== undefined) {
            headers.set("idempotency-key", request.idempotencyKey);
        }
        let response: Response;
        try {
            response = await this.#fetch(url, {
                method: request.method,
                headers,
                signal: AbortSignal.timeout(this.#timeoutMs),
                ...(request.body === undefined ? {} : { body: JSON.stringify(request.body) }),
            });
        } catch (error) {
            throw new CalderaClientError(
                "TRANSPORT_ERROR",
                "The request could not be completed.",
                undefined,
                error,
            );
        }
        const text = await response.text();
        const body = text.length === 0 ? undefined : parseJson(text);
        if (!response.ok) {
            throw new CalderaClientError(
                "REQUEST_REJECTED",
                `Caldera returned HTTP ${response.status}.`,
                response.status,
                body,
            );
        }
        return body as T;
    }
}

export class CalderaClient {
    constructor(private readonly transport: CalderaTransport) {}

    async health(): Promise<HealthResponse> {
        const response = await this.transport.execute<unknown>({
            method: "GET",
            path: "/v1/health",
        });
        assertHealth(response);
        return response;
    }

    async requireHealthy(): Promise<HealthResponse> {
        const health = await this.health();
        if (health.status !== "ok") {
            throw new CalderaClientError(
                "PROTOCOL_NOT_HEALTHY",
                `Protocol status is ${health.status}.`,
            );
        }
        return health;
    }

    async series(seriesId: string): Promise<SeriesResponse> {
        validateIdentifier(seriesId, "seriesId");
        const response = await this.transport.execute<unknown>({
            method: "GET",
            path: `/v1/series/${encodeURIComponent(seriesId)}`,
        });
        assertSeries(response);
        return response;
    }

    async quote(seriesId: string, contracts: AtomicAmount): Promise<QuoteResponse> {
        validateIdentifier(seriesId, "seriesId");
        validateAmount(contracts, "contracts", false);
        const response = await this.transport.execute<unknown>({
            method: "POST",
            path: `/v1/series/${encodeURIComponent(seriesId)}/quotes`,
            body: { contracts },
        });
        assertQuote(response);
        return response;
    }

    async write(intent: WriteIntent, idempotencyKey: string): Promise<OperationResponse> {
        validateIntent(intent);
        validateAmount(intent.maximumCollateral, "maximumCollateral", false);
        return this.operation("/v1/writer-positions", intent, idempotencyKey);
    }

    async buy(intent: BuyIntent, idempotencyKey: string): Promise<OperationResponse> {
        validateIntent(intent);
        validateAmount(intent.maximumPremium, "maximumPremium", false);
        return this.operation("/v1/long-positions", intent, idempotencyKey);
    }

    async requestExercise(
        intent: ExerciseIntent,
        idempotencyKey: string,
    ): Promise<OperationResponse> {
        validateIntent(intent);
        validateAmount(intent.minimumPayout, "minimumPayout", true);
        return this.operation("/v1/exercise-requests", intent, idempotencyKey);
    }

    async processExercise(
        account: string,
        requestId: string,
        idempotencyKey: string,
    ): Promise<OperationResponse> {
        validateIdentifier(account, "account");
        validateIdentifier(requestId, "requestId");
        return this.operation(
            `/v1/exercise-requests/${encodeURIComponent(requestId)}/processing`,
            { account, requestId },
            idempotencyKey,
        );
    }

    async settleWriter(
        account: string,
        positionId: string,
        recipient: string,
        idempotencyKey: string,
    ): Promise<OperationResponse> {
        validateIdentifier(account, "account");
        validateIdentifier(positionId, "positionId");
        validateIdentifier(recipient, "recipient");
        return this.operation(
            `/v1/writer-positions/${encodeURIComponent(positionId)}/settlements`,
            { account, positionId, recipient },
            idempotencyKey,
        );
    }

    private async operation(
        path: string,
        body: unknown,
        idempotencyKey: string,
    ): Promise<OperationResponse> {
        validateIdempotencyKey(idempotencyKey);
        const response = await this.transport.execute<unknown>({
            method: "POST",
            path,
            body,
            idempotencyKey,
        });
        assertOperation(response);
        return response;
    }
}

export function atomic(value: bigint | number | string): AtomicAmount {
    const normalized = value.toString();
    if (typeof value === "number" && !Number.isSafeInteger(value)) {
        throw new CalderaClientError("INVALID_AMOUNT", "Numeric amounts must be safe integers.");
    }
    validateAmount(normalized, "amount", true);
    return normalized;
}

export function optionPayout(
    optionType: OptionType,
    spotPriceX18: AtomicAmount,
    strikePriceX18: AtomicAmount,
    capPriceX18: AtomicAmount,
    contractSizeX18: AtomicAmount,
    contracts: AtomicAmount,
    collateralDecimals: number,
): AtomicAmount {
    const spot = positive(spotPriceX18, "spotPriceX18");
    const strike = positive(strikePriceX18, "strikePriceX18");
    const cap = toBigInt(capPriceX18, "capPriceX18");
    const size = positive(contractSizeX18, "contractSizeX18");
    const quantity = positive(contracts, "contracts");
    validateDecimals(collateralDecimals);
    if (optionType === "call" && cap <= strike) {
        throw new CalderaClientError("INVALID_CAP", "Call cap must exceed strike.");
    }
    const intrinsic =
        optionType === "call"
            ? (spot < cap ? spot : cap) > strike
                ? (spot < cap ? spot : cap) - strike
                : 0n
            : strike > spot
              ? strike - spot
              : 0n;
    const quoteX18 = (intrinsic * size) / WAD;
    return atomic((quoteX18 / 10n ** BigInt(18 - collateralDecimals)) * quantity);
}

export function maximumCollateral(
    optionType: OptionType,
    strikePriceX18: AtomicAmount,
    capPriceX18: AtomicAmount,
    contractSizeX18: AtomicAmount,
    contracts: AtomicAmount,
    collateralDecimals: number,
): AtomicAmount {
    const strike = positive(strikePriceX18, "strikePriceX18");
    const cap = toBigInt(capPriceX18, "capPriceX18");
    const size = positive(contractSizeX18, "contractSizeX18");
    const quantity = positive(contracts, "contracts");
    validateDecimals(collateralDecimals);
    if (optionType === "call" && cap <= strike) {
        throw new CalderaClientError("INVALID_CAP", "Call cap must exceed strike.");
    }
    const maximumPrice = optionType === "call" ? cap - strike : strike;
    const quoteX18 = ceilDiv(maximumPrice * size, WAD);
    const perContract = ceilDiv(quoteX18, 10n ** BigInt(18 - collateralDecimals));
    return atomic(perContract * quantity);
}

export function deriveIdempotencyKey(scope: string, intent: unknown): string {
    validateIdentifier(scope, "scope");
    return `${scope}:${createHash("sha256").update(JSON.stringify(intent)).digest("hex")}`;
}

export function coverageBps(
    effectiveLiquidity: AtomicAmount,
    stressedOutflow: AtomicAmount,
): string {
    const liquidity = toBigInt(effectiveLiquidity, "effectiveLiquidity");
    const outflow = toBigInt(stressedOutflow, "stressedOutflow");
    return (outflow === 0n ? 2n * BPS : (liquidity * BPS) / outflow).toString();
}

function validateIntent(intent: TransactionIntent): void {
    validateIdentifier(intent.account, "account");
    validateIdentifier(intent.seriesId, "seriesId");
    validateIdentifier(intent.recipient, "recipient");
    validateAmount(intent.contracts, "contracts", false);
}

function ceilDiv(value: bigint, denominator: bigint): bigint {
    return value === 0n ? 0n : (value - 1n) / denominator + 1n;
}

function positive(value: AtomicAmount, field: string): bigint {
    const result = toBigInt(value, field);
    if (result === 0n) throw new CalderaClientError("INVALID_AMOUNT", `${field} must be positive.`);
    return result;
}

function toBigInt(value: AtomicAmount, field: string): bigint {
    validateAmount(value, field, true);
    return BigInt(value);
}

function validateDecimals(value: number): void {
    if (!Number.isInteger(value) || value < 0 || value > 18) {
        throw new CalderaClientError("INVALID_DECIMALS", "Collateral decimals are outside range.");
    }
}

function validateAmount(value: string, field: string, allowZero: boolean): void {
    if (!ATOMIC.test(value) || (!allowZero && value === "0")) {
        throw new CalderaClientError("INVALID_AMOUNT", `${field} is not a valid atomic amount.`);
    }
}

function validateIdentifier(value: string, field: string): void {
    if (!IDENTIFIER.test(value)) {
        throw new CalderaClientError("INVALID_IDENTIFIER", `${field} is invalid.`);
    }
}

function validateIdempotencyKey(value: string): void {
    if (value.length < 16 || value.length > 160 || !/^[a-zA-Z0-9:_-]+$/.test(value)) {
        throw new CalderaClientError("INVALID_IDEMPOTENCY_KEY", "The idempotency key is invalid.");
    }
}

function parseJson(value: string): unknown {
    try {
        return JSON.parse(value) as unknown;
    } catch {
        throw new CalderaClientError("INVALID_JSON", "Caldera returned malformed JSON.");
    }
}

function record(value: unknown): Record<string, unknown> {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        throw new CalderaClientError("INVALID_RESPONSE", "Caldera returned an invalid response.");
    }
    return value as Record<string, unknown>;
}

function string(value: unknown, field: string): string {
    if (typeof value !== "string" || value.length === 0) {
        throw new CalderaClientError("INVALID_RESPONSE", `Response field ${field} is invalid.`);
    }
    return value;
}

function amountField(value: unknown, field: string): AtomicAmount {
    const result = string(value, field);
    validateAmount(result, field, true);
    return result;
}

function digest(value: unknown, field: string): string {
    const result = string(value, field);
    if (!/^[a-f0-9]{64}$/.test(result)) {
        throw new CalderaClientError("INVALID_RESPONSE", `${field} is invalid.`);
    }
    return result;
}

function assertHealth(value: unknown): asserts value is HealthResponse {
    const item = record(value);
    if (!["ok", "degraded", "halted"].includes(String(item.status))) {
        throw new CalderaClientError("INVALID_RESPONSE", "Health status is invalid.");
    }
    string(item.version, "version");
    string(item.chainId, "chainId");
    digest(item.stateDigest, "stateDigest");
}

function assertSeries(value: unknown): asserts value is SeriesResponse {
    const item = record(value);
    validateIdentifier(string(item.seriesId, "seriesId"), "seriesId");
    if (item.optionType !== "call" && item.optionType !== "put") {
        throw new CalderaClientError("INVALID_RESPONSE", "Option type is invalid.");
    }
    string(item.collateralAsset, "collateralAsset");
    for (const field of [
        "strikePriceX18",
        "capPriceX18",
        "collateralPerContract",
        "writtenContracts",
        "soldContracts",
    ] as const) {
        amountField(item[field], field);
    }
    string(item.expiry, "expiry");
    if (!["scheduled", "funding", "exercise", "expired"].includes(String(item.phase))) {
        throw new CalderaClientError("INVALID_RESPONSE", "Series phase is invalid.");
    }
}

function assertQuote(value: unknown): asserts value is QuoteResponse {
    const item = record(value);
    validateIdentifier(string(item.seriesId, "seriesId"), "seriesId");
    for (const field of ["contracts", "premiumPerContract", "totalPremium", "feeAmount"] as const) {
        amountField(item[field], field);
    }
    string(item.expiresAt, "expiresAt");
    digest(item.stateDigest, "stateDigest");
}

function assertOperation(value: unknown): asserts value is OperationResponse {
    const item = record(value);
    validateIdentifier(string(item.operationId, "operationId"), "operationId");
    if (!["accepted", "queued", "confirmed"].includes(String(item.status))) {
        throw new CalderaClientError("INVALID_RESPONSE", "Operation status is invalid.");
    }
    if (item.transactionHash !== undefined) string(item.transactionHash, "transactionHash");
    if (item.amount !== undefined) amountField(item.amount, "amount");
    digest(item.stateDigest, "stateDigest");
}
