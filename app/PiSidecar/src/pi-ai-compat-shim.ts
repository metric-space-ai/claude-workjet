// pi-agent-core 0.80.2 imports three helpers from the broad pi-ai compatibility
// entrypoint. Workjet always injects its own stream function, so bundling the
// compatibility provider registry would add every provider for an unused
// fallback. This narrow build-time adapter preserves the helpers exercised by
// runAgentLoop and makes an accidental fallback fail closed.
import { Value } from "typebox/value";

export class EventStream<Event, Result> {
  readonly queue: Event[] = [];
  readonly waiting: Array<(value: IteratorResult<Event>) => void> = [];
  done = false;
  readonly finalResult: Promise<Result>;
  private resolveResult!: (result: Result) => void;

  constructor(
    private readonly isComplete: (event: Event) => boolean,
    private readonly extractResult: (event: Event) => Result,
  ) {
    this.finalResult = new Promise((resolve) => {
      this.resolveResult = resolve;
    });
  }

  push(event: Event): void {
    if (this.done) return;
    if (this.isComplete(event)) {
      this.done = true;
      this.resolveResult(this.extractResult(event));
    }
    const waiter = this.waiting.shift();
    if (waiter) waiter({ value: event, done: false });
    else this.queue.push(event);
  }

  end(result?: Result): void {
    this.done = true;
    if (result !== undefined) this.resolveResult(result);
    for (const waiter of this.waiting.splice(0)) waiter({ value: undefined, done: true });
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<Event> {
    while (true) {
      const queued = this.queue.shift();
      if (queued !== undefined) yield queued;
      else if (this.done) return;
      else {
        const next = await new Promise<IteratorResult<Event>>((resolve) => this.waiting.push(resolve));
        if (next.done) return;
        yield next.value;
      }
    }
  }

  result(): Promise<Result> {
    return this.finalResult;
  }
}

export function validateToolArguments(tool: { name: string; parameters: object }, toolCall: { arguments: unknown }): unknown {
  const converted = Value.Convert(tool.parameters, structuredClone(toolCall.arguments));
  if (Value.Check(tool.parameters, converted)) return converted;
  const errors = [...Value.Errors(tool.parameters, converted)].map((error) => error.message).join("; ");
  throw new Error(`Validation failed for tool "${tool.name}": ${errors || "unknown validation error"}`);
}

export function streamSimple(): never {
  throw new Error("pi-ai compatibility provider fallback is disabled; Workjet must inject the loopback gateway stream");
}
