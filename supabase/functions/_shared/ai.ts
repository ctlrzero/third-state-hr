// Shared AI call for the assistant Edge Functions (cover-assistant, roster-assistant, payroll-explainer).
//
// Provider is a setting, not code:
//   AI_PROVIDER = 'anthropic' (default) | 'openai'
//   ANTHROPIC_API_KEY / OPENAI_API_KEY — the key for that provider
//   AI_MODEL — model for every assistant (optional)
//   <FUNCTION>_MODEL (e.g. COVER_ASSISTANT_MODEL) — per-assistant override (optional)
// Anthropic defaults to claude-sonnet-5-5. OpenAI has no default: set AI_MODEL (or OPENAI_MODEL) to the model
// you want, otherwise the assistants use their rule-based fallback.
//
// Returns the model's text, or null when AI isn't configured or the call fails — callers always have a
// rule-based fallback, so an AI problem never blocks the manager. Keys are never logged.

export interface AiConfig {
  provider: 'anthropic' | 'openai'
  model: string
  apiKey: string
}

export function aiConfig(modelEnv: string): AiConfig | null {
  const provider = (Deno.env.get('AI_PROVIDER') ?? 'anthropic').toLowerCase() === 'openai' ? 'openai' : 'anthropic'
  if (provider === 'openai') {
    const apiKey = Deno.env.get('OPENAI_API_KEY')
    const model = Deno.env.get(modelEnv) ?? Deno.env.get('AI_MODEL') ?? Deno.env.get('OPENAI_MODEL')
    if (!apiKey || !model) {
      console.error(`AI not configured: set OPENAI_API_KEY and AI_MODEL for the OpenAI provider`)
      return null
    }
    return { provider, model, apiKey }
  }
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY')
  if (!apiKey) return null
  return { provider, model: Deno.env.get(modelEnv) ?? Deno.env.get('AI_MODEL') ?? 'claude-sonnet-5-5', apiKey }
}

export async function aiText(cfg: AiConfig, system: string, user: string, maxTokens: number): Promise<string | null> {
  try {
    if (cfg.provider === 'openai') {
      const res = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: { Authorization: `Bearer ${cfg.apiKey}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          model: cfg.model,
          max_completion_tokens: maxTokens,
          messages: [
            { role: 'system', content: system },
            { role: 'user', content: user },
          ],
        }),
      })
      if (!res.ok) {
        console.error('openai error', res.status, (await res.text()).slice(0, 300))
        return null
      }
      const body = (await res.json()) as { choices?: { message?: { content?: string | null } }[] }
      return body.choices?.[0]?.message?.content ?? null
    }
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': cfg.apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: cfg.model, max_tokens: maxTokens, system, messages: [{ role: 'user', content: user }] }),
    })
    if (!res.ok) {
      console.error('anthropic error', res.status, (await res.text()).slice(0, 300))
      return null
    }
    const body = (await res.json()) as { content?: { type: string; text?: string }[] }
    return (body.content ?? []).filter((c) => c.type === 'text').map((c) => c.text ?? '').join('')
  } catch (e) {
    console.error(`${cfg.provider} call failed`, (e as Error).message)
    return null
  }
}

/** First {...} block in the model's reply, parsed; null if there isn't a valid one. */
export function firstJson<T>(text: string | null): T | null {
  const match = text?.match(/\{[\s\S]*\}/)
  if (!match) return null
  try {
    return JSON.parse(match[0]) as T
  } catch {
    return null
  }
}
