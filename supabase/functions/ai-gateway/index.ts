import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "jsr:@supabase/server@^1";

const assemblyAIBaseURL = "https://api.assemblyai.com";
const anthropicBaseURL = "https://api.anthropic.com";
// Large meetings commonly exceed the original 50 MB guard. Keep a defensive
// ceiling while allowing multi-hour AAC recordings to stream through the proxy.
const maxAudioBytes = 500 * 1024 * 1024;
const dailyQuotaUnits = 25;

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};

export default {
  fetch: withSupabase({ auth: "user" }, async (request, context) => {
    const url = new URL(request.url);
    const operation = url.searchParams.get("operation");

    try {
      if (operation !== "assemblyai.poll" && operation !== "assemblyai.delete") {
        const userID = context.userClaims?.id;
        if (!userID) throw new Error("Authenticated user is required");
        const { data: accepted, error } = await context.supabaseAdmin.rpc("consume_ai_quota", {
          p_user_id: userID,
          p_units: 1,
          p_daily_limit: dailyQuotaUnits,
        });
        if (error) throw error;
        if (accepted !== true) {
          return jsonError("Daily cloud AI limit reached", 429);
        }
      }

      switch (operation) {
        case "assemblyai.upload":
          return await assemblyAIUpload(request);
        case "assemblyai.create":
          return await proxyJSON(request, `${assemblyAIBaseURL}/v2/transcript`, assemblyAIHeaders());
        case "assemblyai.poll":
          return await assemblyAIPoll(url);
        case "assemblyai.delete":
          return await assemblyAIDelete(url);
        case "assemblyai.lemur":
          return await proxyJSON(request, `${assemblyAIBaseURL}/lemur/v3/generate/task`, assemblyAIHeaders());
        case "anthropic.messages":
          return await proxyJSON(request, `${anthropicBaseURL}/v1/messages`, anthropicHeaders());
        default:
          return jsonError("Unsupported operation", 400);
      }
    } catch (error) {
      console.error("ai-gateway request failed", error instanceof Error ? error.message : error);
      return jsonError("Momentus cloud service is temporarily unavailable", 502);
    }
  }),
};

async function assemblyAIUpload(request: Request): Promise<Response> {
  requireSecret("ASSEMBLYAI_API_KEY");
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > maxAudioBytes) return jsonError("Recording is larger than 500 MB", 413);
  if (!request.body) return jsonError("Recording data is required", 400);

  const response = await fetch(`${assemblyAIBaseURL}/v2/upload`, {
    method: "POST",
    headers: {
      Authorization: Deno.env.get("ASSEMBLYAI_API_KEY")!,
      "content-type": "application/octet-stream",
    },
    body: request.body,
  });
  return providerResponse(response);
}

async function assemblyAIPoll(url: URL): Promise<Response> {
  const id = url.searchParams.get("id") ?? "";
  if (!/^[a-zA-Z0-9_-]{8,100}$/.test(id)) return jsonError("Invalid transcript ID", 400);

  const response = await fetch(`${assemblyAIBaseURL}/v2/transcript/${encodeURIComponent(id)}`, {
    headers: assemblyAIHeaders(),
  });
  return providerResponse(response);
}

async function assemblyAIDelete(url: URL): Promise<Response> {
  const id = url.searchParams.get("id") ?? "";
  if (!/^[a-zA-Z0-9_-]{8,100}$/.test(id)) return jsonError("Invalid transcript ID", 400);

  const response = await fetch(`${assemblyAIBaseURL}/v2/transcript/${encodeURIComponent(id)}`, {
    method: "DELETE",
    headers: assemblyAIHeaders(),
  });
  return providerResponse(response);
}

async function proxyJSON(
  request: Request,
  providerURL: string,
  headers: Record<string, string>,
): Promise<Response> {
  const body = await request.text();
  if (!body) return jsonError("JSON body is required", 400);
  if (body.length > 2_000_000) return jsonError("Request is too large", 413);

  const response = await fetch(providerURL, {
    method: "POST",
    headers: { ...headers, "content-type": "application/json" },
    body,
  });
  return providerResponse(response);
}

function assemblyAIHeaders(): Record<string, string> {
  return { Authorization: requireSecret("ASSEMBLYAI_API_KEY") };
}

function anthropicHeaders(): Record<string, string> {
  return {
    "x-api-key": requireSecret("ANTHROPIC_API_KEY"),
    "anthropic-version": "2023-06-01",
  };
}

function requireSecret(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(name + " is not configured");
  return value;
}

async function providerResponse(response: Response): Promise<Response> {
  const headers = new Headers(corsHeaders);
  headers.set("content-type", response.headers.get("content-type") ?? "application/json");
  headers.set("cache-control", "no-store");
  return new Response(response.body, { status: response.status, headers });
}

function jsonError(error: string, status: number): Response {
  return Response.json({ error }, { status, headers: corsHeaders });
}
