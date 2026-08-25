/**
 * Project Aur Bhai — Anonymous Wish Ingest Serverless Worker (Cloudflare Worker / Edge)
 * Zero-cost, zero-PII ingest endpoint for user feature wishes and feedback.
 *
 * Deployment (Cloudflare Workers / Vercel Edge):
 * wrangler deploy
 */

export default {
  async fetch(request, env, ctx) {
    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, X-Aur-Version",
        },
      });
    }

    if (request.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: { "Content-Type": "application/json" },
      });
    }

    try {
      const body = await request.json();
      const wishes = Array.isArray(body) ? body : (body.wishes || [body]);

      const sanitizedBatch = [];
      const now = Date.now();

      for (const item of wishes) {
        const text = String(item.text || item.wish || "").trim();
        if (!text || text.length < 3) continue;

        sanitizedBatch.push({
          id: item.id || `wish_${now.toString(36)}_${Math.random().toString(36).substring(2, 6)}`,
          text: text.substring(0, 500), // Cap length
          category: String(item.category || "general").substring(0, 30),
          tags: Array.isArray(item.tags) ? item.tags.slice(0, 5) : [],
          app_version: String(item.app_version || "3.12").substring(0, 20),
          received_at: new Date().toISOString(),
        });
      }

      if (sanitizedBatch.length === 0) {
        return new Response(JSON.stringify({ success: false, message: "No valid wishes provided" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        });
      }

      // If KV or D1 database is bound (env.WISH_STORE):
      if (env && env.WISH_STORE) {
        const batchKey = `wishes:${new Date().toISOString().substring(0, 10)}`;
        const existing = (await env.WISH_STORE.get(batchKey, { type: "json" })) || [];
        existing.push(...sanitizedBatch);
        await env.WISH_STORE.put(batchKey, JSON.stringify(existing));
      }

      return new Response(
        JSON.stringify({
          success: true,
          count: sanitizedBatch.length,
          message: "Wishes queued for weekly product triage.",
        }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
          },
        }
      );
    } catch (e) {
      return new Response(JSON.stringify({ success: false, error: e.message }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
  },
};
