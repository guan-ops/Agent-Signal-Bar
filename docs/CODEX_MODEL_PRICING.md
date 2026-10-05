# Codex model usage and estimated prices

Verified against [OpenAI API pricing](https://developers.openai.com/api/docs/pricing) on 2026-09-23.
These are USD estimates from local session input, cached input, and output tokens.
They are not a Codex subscription bill or Codex credit consumption. Cached input is
part of input and is charged once, at the cached-input rate.

| Model | Input / 1M | Cached input / 1M | Output / 1M | Chart color |
| --- | ---: | ---: | ---: | --- |
| GPT-6 Astra | $10 | $1 | $50 | Nebula violet `#6F52F0` |
| GPT-6.1 Sol | $2 | $0.10 | $10 | Amber orange `#EE7430` |
| GPT-6 Sol | $2 | $0.20 | $10 | Flame orange-red `#E85028` |
| GPT-6 Luna | $0.10 | $0.01 | $0.50 | Moon yellow `#F8D068` |
| GPT-5.6 Sol | $4 | $0.40 | $20 | Pink `#D56F9B` |
| GPT-5.6 Terra | $2 | $0.20 | $12 | Green `#6BAB73` |
| GPT-5.6 Luna | $0.20 | $0.02 | $1.20 | Teal `#4CB8B0` |
| GPT-5.5 | $5 | $0.50 | $30 | Slate `#919BB0` |

For GPT-6 and GPT-5.6, a request exceeding 272,000 input tokens uses 2× input/cache
rates and 1.5× output rates for the entire request. Fast uses 2× the applicable
Standard rates. Both `priority` and `fast` trace values identify Fast usage.
Thresholds apply to individual requests, not daily totals. GPT-5.5 retains its
separate existing Fast pricing and long-context support boundary. When its Fast
rate is unknown, the cost stays unknown rather than using the Standard price;
other confirmed costs remain available.

The seven verified GPT-6/GPT-5.6 entries take precedence over models.dev so an older
catalog cannot override their rates or omit long-context pricing. A pricing
fingerprint change rebuilds historical costs from requests, including paginated
session ledgers. Historical displays are estimates at the configured rates, not
a reconstruction of historical invoices. The current GPT-5.6 Sol rate is a
promotional rate; OpenAI currently commits to it through at least 2026-11-21.

For other known Codex models, a models.dev entry without any long-context block
uses the bundled long-context rates and threshold while retaining the catalog's
Standard rates below that threshold. Explicit catalog context blocks retain their
rates, including fallback to catalog Standard rates for omitted fields. The
2026-10-03 policy update invalidates previous cost caches so unchanged session
logs are repriced on the next scan, even within the normal refresh interval.

GPT-6 colors follow the user-provided Astra/Sol/Luna character artwork reference
(`IMG_9641.HEIC`): nebula violet, flame orange-red, and moon yellow. The flat chart
colors interpret that artwork; they are not published official hex specifications.
Names accompany colors;
provider-prefixed and dated aliases share the same presentation. Older GPT-5.x
variants retain a color per model family. Unknown models use a neutral color.

Implementation: `CostUsagePricing.swift`, `CostUsageScanner+CodexPriority.swift`,
and `CodexModelPresentation.swift`. Focused regression coverage is in
`CodexCurrentModelPricingTests.swift`, `CodexCatalogLongContextPricingTests.swift`,
and `CodexModelPresentationTests.swift`.

## GPT-6.1 Sol and future model compatibility (2026-10-03)

GPT-6.1 Sol rates were rechecked on 2026-10-05 against the [official model page](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
and [pricing table](https://developers.openai.com/api/docs/pricing). It has its own
price entry: cached input is $0.10 per million, not GPT-6 Sol's $0.20. Prompts
above 272,000 input tokens use 2x input/cache and 1.5x output rates; Fast is 2x
Standard. Existing pricing fingerprints invalidate historical cost caches when
this entry is added. These estimates cover session input, cached input and output;
they do not infer separate cache-write charges, regional premiums or subscription credits.

New models will be adapted manually: verify the official rates, add explicit
pricing and presentation entries, and run focused regression tests. Supported
models accept provider prefixes and dated aliases. Unfamiliar models retain their
raw names and neutral colors rather than inheriting a future family presentation.

The existing models.dev pipeline remains available as a pricing fallback, but
production has no caller for its 24-hour cache refresh. No automatic refresh is
planned. Until a model's rates are available, keep counting its tokens and leave
its price unknown. Pricing changes use the existing fingerprint to reprice history.
