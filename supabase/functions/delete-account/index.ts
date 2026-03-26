import { createClient } from "jsr:@supabase/supabase-js@2";

const jsonHeaders = {
  "Content-Type": "application/json",
};

function tokenPrefix(authorization: string | null): string {
  if (!authorization) return "none";
  const bearerPrefix = "Bearer ";
  if (!authorization.startsWith(bearerPrefix)) return "invalid-format";
  const token = authorization.slice(bearerPrefix.length).trim();
  if (!token) return "empty";
  return token.slice(0, 12);
}

Deno.serve(async (request) => {
  const requestID = crypto.randomUUID().slice(0, 8);
  console.log(`[delete-account:${requestID}] request method=${request.method}`);

  if (request.method !== "POST") {
    console.error(`[delete-account:${requestID}] rejected method=${request.method}`);
    return new Response(
      JSON.stringify({ error: "Method not allowed." }),
      { status: 405, headers: jsonHeaders },
    );
  }

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = request.headers.get("Authorization");
  const hasAuthorization = Boolean(authorization);
  console.log(
    `[delete-account:${requestID}] authHeaderPresent=${hasAuthorization} tokenPrefix=${tokenPrefix(authorization)}`,
  );

  if (!supabaseURL || !serviceRoleKey) {
    console.error(`[delete-account:${requestID}] missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY`);
    return new Response(
      JSON.stringify({ error: "Supabase function secrets are not configured." }),
      { status: 500, headers: jsonHeaders },
    );
  }

  if (!authorization) {
    console.error(`[delete-account:${requestID}] missing Authorization header`);
    return new Response(
      JSON.stringify({ error: "Missing Authorization header." }),
      { status: 401, headers: jsonHeaders },
    );
  }

  if (!authorization.startsWith("Bearer ")) {
    console.error(`[delete-account:${requestID}] malformed Authorization header`);
    return new Response(
      JSON.stringify({ error: "Authorization header must use Bearer token." }),
      { status: 401, headers: jsonHeaders },
    );
  }

  const userClient = createClient(supabaseURL, serviceRoleKey, {
    global: {
      headers: {
        Authorization: authorization,
      },
    },
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  const {
    data: { user },
    error: userError,
  } = await userClient.auth.getUser();

  if (userError || !user) {
    console.error(
      `[delete-account:${requestID}] auth.getUser failed hasUser=${Boolean(user)} error=${userError?.message ?? "unknown"}`,
    );
    return new Response(
      JSON.stringify({ error: "Authenticated user session is required." }),
      { status: 401, headers: jsonHeaders },
    );
  }

  console.log(`[delete-account:${requestID}] resolved user id=${user.id}`);

  const adminClient = createClient(supabaseURL, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  const { error: deleteError } = await adminClient.auth.admin.deleteUser(user.id);

  if (deleteError) {
    console.error(`[delete-account:${requestID}] auth.admin.deleteUser failed error=${deleteError.message}`);
    return new Response(
      JSON.stringify({ error: deleteError.message }),
      { status: 500, headers: jsonHeaders },
    );
  }

  console.log(`[delete-account:${requestID}] account deleted user id=${user.id}`);
  return new Response(
    JSON.stringify({ success: true }),
    { status: 200, headers: jsonHeaders },
  );
});
